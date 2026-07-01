#!/usr/bin/env bash
set -euo pipefail

LOCATIONS="vancouver toronto london frankfurt singapore"
COMPOSE="docker compose"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[deploy]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $*"; }
err()  { echo -e "${RED}[error ]${NC} $*"; }

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
  teardown             Full teardown and cleanup

Examples:
  ./deploy.sh setup
  ./deploy.sh up
  ./deploy.sh up vancouver
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
        ok "All services deployed"
    else
        log "Deploying $target..."
        $COMPOSE up -d "$target"
        ok "$target deployed"
    fi
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
    printf "${CYAN}%-12s %-10s %-10s %-8s${NC}\n" \
        "LOCATION" "STATUS" "VERSION" "PORT"
    echo "----------------------------------------------"

    for loc in $LOCATIONS; do
        local port
        port=$(get_port "$loc")
        local container_status
        container_status=$($COMPOSE ps --format '{{.State}}' "$loc" 2>/dev/null || echo "stopped")

        if [ "$container_status" = "running" ]; then
            local info
            info=$(curl -s --max-time 2 "http://localhost:$port/health" 2>/dev/null || echo '{}')
            local version
            version=$(echo "$info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
            printf "%-12s ${GREEN}%-10s${NC} %-10s %-8s\n" "$loc" "running" "${version:-?}" "$port"
        else
            printf "%-12s ${RED}%-10s${NC} %-10s %-8s\n" "$loc" "stopped" "-" "$port"
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

cmd_teardown() {
    log "Tearing down entire deployment..."
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
    teardown)  cmd_teardown ;;
    logs)      cmd_logs "${2:-}" ;;
    help|*)    usage ;;
esac
