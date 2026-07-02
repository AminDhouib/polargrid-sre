#!/usr/bin/env bash
set -euo pipefail

LOCATIONS="vancouver toronto london frankfurt singapore"
COMPOSE="docker compose"
PROJECT="polargrid-sre"
DEPLOY_LOG=".deploy_history"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[deploy]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $*"; }
err()  { echo -e "${RED}[error ]${NC} $*"; }

record_event() {
    local action="$1" target="$2" detail="${3:-}"
    echo "$(date '+%Y-%m-%d %H:%M:%S')|$action|$target|$detail" >> "$DEPLOY_LOG"
}

usage() {
    cat <<EOF
PolarGrid Deployment Tool

Usage: ./deploy.sh <command> [options]

Commands:
  setup                Build images and prepare environment
  up [location]        Deploy all locations, or a single location
  down [location]      Tear down all locations, or a single location
  restart [location]   Restart all or one location
  status               Show deployment status
  health               Run health checks across all locations
  logs [location]      Tail logs for a location (default: all)
  version              Show deployed versions
  set-version <loc> <ver>  Update version for a location
  degrade <location>   Simulate degraded mode for a location
  recover <location>   Recover a degraded location
  validate             Pre-rollout health/readiness check
  rollout <version>    Safe incremental rollout to all locations
  rollback <location>  Rollback a location to previous version
  teardown             Full teardown and cleanup
  load [location]      Generate test load against location(s)
  history              Show recent deployment history

Examples:
  ./deploy.sh setup
  ./deploy.sh up
  ./deploy.sh up vancouver
  ./deploy.sh degrade singapore
  ./deploy.sh rollout 2.0.0
  ./deploy.sh rollback singapore
  ./deploy.sh teardown
EOF
}

get_port() {
    case "$1" in
        vancouver)  echo 8001 ;;
        toronto)    echo 8002 ;;
        london)     echo 8003 ;;
        frankfurt)  echo 8004 ;;
        singapore)  echo 8005 ;;
        *) echo 0 ;;
    esac
}

cmd_setup() {
    log "Building service images..."
    $COMPOSE build
    log "Pulling monitoring images..."
    $COMPOSE pull prometheus grafana
    ok "Setup complete"
}

cmd_up() {
    local target="${1:-all}"
    if [ "$target" = "all" ]; then
        log "Deploying all locations + monitoring..."
        $COMPOSE up -d
        ok "All locations deployed"
        record_event "deploy" "all" "started all locations"
    else
        log "Deploying $target..."
        $COMPOSE up -d "$target"
        ok "$target deployed"
        record_event "deploy" "$target" "started"
    fi
    sleep 2
    cmd_health
}

cmd_down() {
    local target="${1:-all}"
    if [ "$target" = "all" ]; then
        log "Stopping all services..."
        $COMPOSE down
        ok "All stopped"
    else
        log "Stopping $target..."
        $COMPOSE stop "$target"
        $COMPOSE rm -f "$target"
        ok "$target stopped"
    fi
}

cmd_restart() {
    local target="${1:-all}"
    if [ "$target" = "all" ]; then
        log "Restarting all..."
        $COMPOSE restart
    else
        log "Restarting $target..."
        $COMPOSE restart "$target"
    fi
    ok "Restart complete"
}

cmd_status() {
    echo ""
    printf "${CYAN}%-12s %-10s %-10s %-8s %-10s %-8s${NC}\n" \
        "LOCATION" "STATUS" "VERSION" "PORT" "HEALTH" "DEGRADED"
    echo "------------------------------------------------------------------------"

    for loc in $LOCATIONS; do
        local port
        port=$(get_port "$loc")
        local container_status
        container_status=$($COMPOSE ps --format '{{.State}}' "$loc" 2>/dev/null || echo "stopped")

        if [ "$container_status" = "running" ]; then
            local info
            info=$(curl -s --max-time 2 "http://localhost:$port/health" 2>/dev/null || echo '{}')
            local version health_status degraded
            version=$(echo "$info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
            health_status=$(echo "$info" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
            degraded=$(echo "$info" | grep -o '"degraded":[a-z]*' | cut -d: -f2)
            printf "%-12s ${GREEN}%-10s${NC} %-10s %-8s %-10s %-8s\n" \
                "$loc" "running" "${version:-?}" "$port" "${health_status:-?}" "${degraded:-false}"
        else
            printf "%-12s ${RED}%-10s${NC} %-10s %-8s %-10s %-8s\n" \
                "$loc" "stopped" "-" "$port" "-" "-"
        fi
    done
    echo ""
}

cmd_health() {
    echo ""
    log "Running health checks..."
    local all_healthy=true

    for loc in $LOCATIONS; do
        local port
        port=$(get_port "$loc")
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/health" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            ok "$loc — healthy (port $port)"
        elif [ "$http_code" = "503" ]; then
            warn "$loc — degraded (port $port)"
            all_healthy=false
        else
            err "$loc — unreachable (port $port, HTTP $http_code)"
            all_healthy=false
        fi
    done

    echo ""
    if $all_healthy; then
        ok "All locations healthy"
    else
        warn "Some locations are degraded or unreachable"
    fi
}

cmd_version() {
    echo ""
    log "Deployed versions:"
    for loc in $LOCATIONS; do
        local port
        port=$(get_port "$loc")
        local ver
        ver=$(curl -s --max-time 2 "http://localhost:$port/info" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        echo "  $loc: ${ver:-unreachable}"
    done
    echo ""
}

cmd_set_version() {
    local loc="$1" ver="$2"
    log "Setting $loc to version $ver..."
    sed -i 's/^SERVICE_VERSION=.*/SERVICE_VERSION='"$ver"'/' "configs/${loc}.env"
    $COMPOSE up -d --build "$loc"
    sleep 3
    local actual
    actual=$(curl -s --max-time 3 "http://localhost:$(get_port "$loc")/info" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    if [ "$actual" = "$ver" ]; then
        ok "$loc now running version $actual"
        record_event "version" "$loc" "updated to v$ver"
    else
        err "$loc version mismatch: expected $ver, got ${actual:-unreachable}"
        record_event "version_fail" "$loc" "expected v$ver, got ${actual:-unreachable}"
        return 1
    fi
}

cmd_degrade() {
    local loc="$1"
    log "Simulating degradation for $loc..."
    sed -i 's/^DEGRADED=.*/DEGRADED=true/' "configs/${loc}.env"
    sed -i 's/^ERROR_RATE=.*/ERROR_RATE=0.15/' "configs/${loc}.env"
    sed -i 's/^TAIL_LATENCY_PCTILE=.*/TAIL_LATENCY_PCTILE=0.30/' "configs/${loc}.env"
    $COMPOSE up -d --build "$loc"
    record_event "degrade" "$loc" "simulated failure"
    warn "$loc is now in DEGRADED mode"
}

cmd_recover() {
    local loc="$1"
    log "Recovering $loc..."
    sed -i 's/^DEGRADED=.*/DEGRADED=false/' "configs/${loc}.env"
    sed -i 's/^ERROR_RATE=.*/ERROR_RATE=0.02/' "configs/${loc}.env"
    sed -i 's/^TAIL_LATENCY_PCTILE=.*/TAIL_LATENCY_PCTILE=0.05/' "configs/${loc}.env"
    $COMPOSE up -d --build "$loc"
    ok "$loc recovered"
    record_event "recover" "$loc" "restored to healthy"
}

cmd_validate() {
    echo ""
    log "=== Pre-rollout Validation ==="
    local ok_count=0
    local fail_count=0
    local total=5

    for loc in $LOCATIONS; do
        local port
        port=$(get_port "$loc")
        local code
        code=$(curl -s --max-time 3 "http://localhost:$port/health" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
        code=$(echo "$code" | tail -c 4 | head -c 3)
        [ -z "$code" ] && code="000"
        local ready_code
        ready_code=$(curl -s --max-time 3 "http://localhost:$port/ready" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
        ready_code=$(echo "$ready_code" | tail -c 4 | head -c 3)
        [ -z "$ready_code" ] && ready_code="000"

        if [ "$code" = "200" ] && [ "$ready_code" = "200" ]; then
            ok "$loc — healthy and ready"
            ok_count=$((ok_count+1))
        else
            err "$loc — NOT ready (health=$code, ready=$ready_code)"
            fail_count=$((fail_count+1))
        fi
    done

    echo ""
    if [ "$fail_count" -eq 0 ]; then
        ok "All $total locations healthy and ready. Safe to rollout."
        return 0
    else
        err "$fail_count/$total locations not ready. Fix before rolling out."
        return 1
    fi
}

cmd_rollout() {
    local new_version="$1"
    local canary="vancouver"
    local remaining="toronto london frankfurt singapore"

    echo ""
    log "=== Safe Rollout: v$new_version ==="
    echo ""

    log "Running pre-rollout validation..."
    if ! cmd_validate; then
        err "Pre-rollout validation failed. Aborting."
        record_event "rollout_abort" "all" "pre-validation failed for v$new_version"
        return 1
    fi
    echo ""

    # Phase 1: Canary
    log "Phase 1: Canary deployment to $canary"
    cmd_set_version "$canary" "$new_version"

    log "Waiting 10s for canary stabilization..."
    sleep 10

    local port
    port=$(get_port "$canary")
    local canary_health
    canary_health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/health" 2>/dev/null || echo "000")

    if [ "$canary_health" != "200" ]; then
        err "Canary failed health check (HTTP $canary_health). Aborting rollout."
        record_event "rollout_abort" "canary:$canary" "v$new_version failed health check"
        err "Rolling back canary..."
        cmd_set_version "$canary" "1.0.0"
        err "Rollout ABORTED. Only canary was affected and has been rolled back."
        return 1
    fi
    ok "Canary healthy. Proceeding to Phase 2."
    echo ""

    # Phase 2: Rolling deployment
    log "Phase 2: Rolling deployment to remaining locations"
    for loc in $remaining; do
        log "Deploying to $loc..."
        cmd_set_version "$loc" "$new_version"

        log "Validating $loc..."
        sleep 5
        port=$(get_port "$loc")
        local loc_health
        loc_health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/health" 2>/dev/null || echo "000")

        if [ "$loc_health" != "200" ]; then
            err "$loc failed health check. Stopping rollout."
            err "Locations already updated: $canary + previous in this loop"
            err "Run: ./deploy.sh rollback $loc"
            return 1
        fi
        ok "$loc healthy at v$new_version"
    done

    echo ""
    ok "=== Rollout complete: all locations at v$new_version ==="
    record_event "rollout_complete" "all" "v$new_version"
    cmd_version
}

cmd_rollback() {
    local loc="$1"
    local previous_version="1.0.0"

    log "Rolling back $loc to v$previous_version..."
    cmd_set_version "$loc" "$previous_version"
    cmd_recover "$loc"
    record_event "rollback" "$loc" "reverted to v$previous_version"
    ok "$loc rolled back to v$previous_version"
}

cmd_history() {
    if [ ! -f "$DEPLOY_LOG" ]; then
        warn "No deployment history yet."
        return
    fi
    echo ""
    printf "${CYAN}%-20s │ %-18s │ %-12s │ %s${NC}\n" "TIMESTAMP" "ACTION" "TARGET" "DETAIL"
    echo "─────────────────────┼────────────────────┼──────────────┼─────────────────────────"
    tail -20 "$DEPLOY_LOG" | while IFS='|' read -r ts action target detail; do
        printf "%-20s │ %-18s │ %-12s │ %s\n" "$ts" "$action" "$target" "$detail"
    done
    echo ""
}

cmd_load() {
    local target="${1:-all}"
    local targets=""

    if [ "$target" = "all" ]; then
        targets="$LOCATIONS"
    else
        targets="$target"
    fi

    log "Generating load against: $targets (Ctrl+C to stop)"
    while true; do
        for loc in $targets; do
            local port
            port=$(get_port "$loc")
            curl -s -X POST "http://localhost:$port/v1/inference" \
                -H "Content-Type: application/json" \
                -d '{"prompt":"test inference request from load generator"}' \
                > /dev/null 2>&1 &
        done
        sleep 0.5
    done
}

cmd_teardown() {
    log "Tearing down entire deployment..."
    record_event "teardown" "all" "full environment teardown"
    $COMPOSE down -v --remove-orphans
    ok "All containers, networks, and volumes removed"
}

cmd_logs() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        $COMPOSE logs -f --tail=50
    else
        $COMPOSE logs -f --tail=50 "$target"
    fi
}

# Main dispatch
case "${1:-help}" in
    setup)     cmd_setup ;;
    up)        cmd_up "${2:-all}" ;;
    down)      cmd_down "${2:-all}" ;;
    restart)   cmd_restart "${2:-all}" ;;
    status)    cmd_status ;;
    health)    cmd_health ;;
    version)   cmd_version ;;
    set-version)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { err "Usage: deploy.sh set-version <location> <version>"; exit 1; }
        cmd_set_version "$2" "$3" ;;
    degrade)
        [ -z "${2:-}" ] && { err "Usage: deploy.sh degrade <location>"; exit 1; }
        cmd_degrade "$2" ;;
    recover)
        [ -z "${2:-}" ] && { err "Usage: deploy.sh recover <location>"; exit 1; }
        cmd_recover "$2" ;;
    validate)  cmd_validate ;;
    rollout)
        [ -z "${2:-}" ] && { err "Usage: deploy.sh rollout <version>"; exit 1; }
        cmd_rollout "$2" ;;
    rollback)
        [ -z "${2:-}" ] && { err "Usage: deploy.sh rollback <location>"; exit 1; }
        cmd_rollback "$2" ;;
    teardown)  cmd_teardown ;;
    logs)      cmd_logs "${2:-}" ;;
    load)      cmd_load "${2:-all}" ;;
    history)   cmd_history ;;
    help|*)    usage ;;
esac
