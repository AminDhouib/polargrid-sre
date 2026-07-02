#!/usr/bin/env bash
set -euo pipefail

LOCATIONS="vancouver toronto london frankfurt singapore"
PORTS=(8001 8002 8003 8004 8005)
REFRESH="${1:-3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

while true; do
    clear
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          PolarGrid Inference — Multi-Location Dashboard                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}  Refreshing every ${REFRESH}s — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    printf "${BOLD}%-12s │ %-8s │ %-8s │ %-10s │ %-7s │ %-7s │ %-6s │ %-6s │ %-5s${NC}\n" \
        "LOCATION" "STATUS" "VERSION" "LATENCY" "ERR%" "GPU%" "VRAM" "TEMP" "RPS"
    echo "─────────────┼──────────┼──────────┼────────────┼─────────┼─────────┼────────┼────────┼───────"

    i=0
    for loc in $LOCATIONS; do
        port=${PORTS[$i]}
        ((i++))

        health_resp=$(curl -s --max-time 2 "http://localhost:$port/health" 2>/dev/null || echo '{"status":"down"}')
        info_resp=$(curl -s --max-time 2 "http://localhost:$port/info" 2>/dev/null || echo '{}')
        metrics_resp=$(curl -s --max-time 2 "http://localhost:$port/metrics" 2>/dev/null || echo '')

        status=$(echo "$health_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        version=$(echo "$health_resp" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        degraded=$(echo "$health_resp" | grep -o '"degraded":[a-z]*' | cut -d: -f2)

        gpu_util=$(echo "$metrics_resp" | grep '^gpu_utilization_percent' | grep -v '^#' | head -1 | awk '{print $2}')
        gpu_mem=$(echo "$metrics_resp" | grep '^gpu_memory_used_gb' | grep -v '^#' | head -1 | awk '{print $2}')
        gpu_temp=$(echo "$metrics_resp" | grep '^gpu_temperature_celsius' | grep -v '^#' | head -1 | awk '{print $2}')

        total_req=$(echo "$metrics_resp" | grep '^inference_requests_total' | grep -v '^#' | awk '{sum+=$2} END {printf "%.0f", sum}')
        err_req=$(echo "$metrics_resp" | grep '^inference_requests_total.*status="error"' | grep -v '^#' | awk '{sum+=$2} END {printf "%.0f", sum}')

        err_pct="0.0"
        if [ -n "$total_req" ] && [ "$total_req" != "0" ] && [ "$total_req" != "" ]; then
            err_req="${err_req:-0}"
            err_pct=$(awk "BEGIN {printf \"%.1f\", ($err_req/$total_req)*100}")
        fi

        latency_sum=$(echo "$metrics_resp" | grep '^inference_request_duration_seconds_sum' | grep -v '^#' | awk '{sum+=$2} END {printf "%.3f", sum}')
        latency_count=$(echo "$metrics_resp" | grep '^inference_request_duration_seconds_count' | grep -v '^#' | awk '{sum+=$2} END {printf "%.0f", sum}')
        avg_latency="—"
        if [ -n "$latency_count" ] && [ "$latency_count" != "0" ]; then
            avg_latency=$(awk "BEGIN {printf \"%.0fms\", ($latency_sum/$latency_count)*1000}")
        fi

        status_color="$GREEN"
        if [ "$status" = "degraded" ] || [ "$degraded" = "true" ]; then
            status_color="$RED"
        elif [ "$status" = "down" ]; then
            status_color="$RED"
        fi

        gpu_color="$GREEN"
        if [ -n "$gpu_util" ]; then
            gpu_int=${gpu_util%.*}
            [ "$gpu_int" -gt 85 ] 2>/dev/null && gpu_color="$RED"
            [ "$gpu_int" -gt 70 ] 2>/dev/null && [ "$gpu_int" -le 85 ] 2>/dev/null && gpu_color="$YELLOW"
        fi

        err_color="$GREEN"
        err_int=${err_pct%.*}
        [ "$err_int" -gt 5 ] 2>/dev/null && err_color="$RED"
        [ "$err_int" -gt 1 ] 2>/dev/null && [ "$err_int" -le 5 ] 2>/dev/null && err_color="$YELLOW"

        printf "%-12s │ ${status_color}%-8s${NC} │ %-8s │ %-10s │ ${err_color}%-7s${NC} │ ${gpu_color}%-7s${NC} │ %-6s │ %-6s │ %-5s\n" \
            "$loc" \
            "${status:-down}" \
            "${version:--}" \
            "${avg_latency}" \
            "${err_pct}%" \
            "${gpu_util:-—}%" \
            "${gpu_mem:-—}G" \
            "${gpu_temp:-—}°" \
            "${total_req:-0}"
    done

    echo ""
    echo -e "${DIM}  Prometheus: http://localhost:9090  |  Grafana: http://localhost:3000 (admin/polargrid)${NC}"
    echo -e "${DIM}  Press Ctrl+C to exit${NC}"

    sleep "$REFRESH"
done
