#!/usr/bin/env bash
set -euo pipefail

# Compare latency and error rates across all locations.
# Usage: ./compare.sh [requests_per_location]

N="${1:-20}"
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}PolarGrid — Cross-Location Performance Comparison${NC}"
echo -e "Sending $N requests per location..."
echo ""

printf "${BOLD}%-12s │ %8s │ %8s │ %6s │ %8s${NC}\n" \
    "LOCATION" "AVG" "MIN" "ERRORS" "VERSION"
echo "─────────────┼──────────┼──────────┼────────┼──────────"

locs="vancouver:8001 toronto:8002 london:8003 frankfurt:8004 singapore:8005"

for entry in $locs; do
    loc="${entry%%:*}"
    port="${entry##*:}"

    # quick reachability check
    pre_check=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$port/health" 2>/dev/null || echo "000")
    if [ "$pre_check" = "000" ]; then
        printf "%-12s │ %8s │ %8s │ ${RED}%6s${NC} │ %8s\n" \
            "$loc" "—" "—" "DOWN" "—"
        continue
    fi

    total_lat=0
    min_lat=99999
    count=0
    errors=0

    for j in $(seq 1 "$N"); do
        resp=$(curl -s -X POST "http://localhost:$port/v1/inference" \
            -H "Content-Type: application/json" \
            -d "{\"prompt\":\"perf test $j\"}" 2>/dev/null)

        if echo "$resp" | grep -q '"error"'; then
            errors=$((errors+1))
            continue
        fi

        lat=$(echo "$resp" | grep -o '"latency_ms":[0-9.]*' | cut -d: -f2)
        if [ -n "$lat" ]; then
            total_lat=$(awk "BEGIN {printf \"%.1f\", $total_lat + $lat}")
            is_min=$(awk "BEGIN {print ($lat < $min_lat)}")
            [ "$is_min" = "1" ] && min_lat="$lat"
            count=$((count+1))
        fi
    done

    version=$(curl -s "http://localhost:$port/info" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)

    if [ $count -gt 0 ]; then
        avg=$(awk "BEGIN {printf \"%.1f\", $total_lat / $count}")
    else
        avg="-"
        min_lat="-"
    fi

    err_color="$GREEN"
    [ "$errors" -gt 0 ] 2>/dev/null && err_color="$YELLOW"
    [ "$errors" -gt 3 ] 2>/dev/null && err_color="$RED"

    lat_color="$NC"
    if [ "$avg" != "-" ]; then
        avg_int=${avg%.*}
        [ "$avg_int" -gt 200 ] 2>/dev/null && lat_color="$RED"
        [ "$avg_int" -gt 100 ] 2>/dev/null && [ "$avg_int" -le 200 ] 2>/dev/null && lat_color="$YELLOW"
    fi

    printf "%-12s │ ${lat_color}%7sms${NC} │ ${lat_color}%7sms${NC} │ ${err_color}%6s${NC} │ %8s\n" \
        "$loc" "$avg" "$min_lat" "$errors" "${version:-?}"
done

echo ""
