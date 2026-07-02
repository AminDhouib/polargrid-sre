#!/usr/bin/env bash
set -euo pipefail

# Full walkthrough demonstrating all operational workflows.
# Run after: ./deploy.sh setup && ./deploy.sh up

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

step=0
pause() {
    step=$((step+1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Step $step: $1 ━━━${NC}"
    echo -e "${DIM}Press Enter to continue...${NC}"
    read -r
}

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     PolarGrid SRE — Operational Demo Walkthrough        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "This demo walks through every operational workflow:"
    echo -e "  1. Health verification"
    echo -e "  2. Deployment status"
    echo -e "  3. Inference testing"
    echo -e "  4. Load generation"
    echo -e "  5. Safe rollout (canary → rolling)"
    echo -e "  6. Failure simulation"
    echo -e "  7. Failure detection"
    echo -e "  8. Recovery"
    echo -e "  9. Rollback"
    echo ""
    echo -e "${DIM}Press Enter to begin...${NC}"
    read -r
}

banner

# ─── 1. Health ───
pause "Verify all locations are healthy"
bash deploy.sh health

# ─── 2. Status ───
pause "Check deployment status across all locations"
bash deploy.sh status

# ─── 3. Version ───
pause "Check deployed versions"
bash deploy.sh version

# ─── 4. Inference ───
pause "Test inference endpoint (vancouver)"
echo -e "${DIM}curl -X POST http://localhost:8001/v1/inference -d '{\"prompt\":\"the quick brown fox\"}'${NC}"
echo ""
curl -s -X POST http://localhost:8001/v1/inference \
    -H "Content-Type: application/json" \
    -d '{"prompt":"the quick brown fox"}' | python3 -m json.tool 2>/dev/null || \
curl -s -X POST http://localhost:8001/v1/inference \
    -H "Content-Type: application/json" \
    -d '{"prompt":"the quick brown fox"}'

# ─── 5. Load ───
pause "Generate load across all locations (50 requests each)"
echo -e "${DIM}Sending 250 total requests...${NC}"
for port in 8001 8002 8003 8004 8005; do
    for i in $(seq 1 50); do
        curl -s -X POST "http://localhost:$port/v1/inference" \
            -H "Content-Type: application/json" \
            -d "{\"prompt\":\"load test request $i\"}" > /dev/null 2>&1 &
    done
done
wait
echo -e "${GREEN}Done — 250 requests sent${NC}"
echo ""
echo "Check Grafana at http://localhost:3000 to see the traffic spike."

# ─── 6. Rollout ───
pause "Safe rollout: deploy v2.0.0 (canary → rolling)"
bash deploy.sh rollout 2.0.0

# ─── 7. Degrade ───
pause "Simulate failure: degrade singapore"
bash deploy.sh degrade singapore

# ─── 8. Detect ───
pause "Detect the failure via health checks and status"
bash deploy.sh health
echo ""
bash deploy.sh status

# ─── 9. More load ───
pause "Generate load to show degradation impact in metrics"
echo -e "${DIM}Sending 100 requests to singapore + 100 to vancouver for comparison...${NC}"
for i in $(seq 1 100); do
    curl -s -X POST "http://localhost:8005/v1/inference" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\":\"degradation test $i\"}" > /dev/null 2>&1 &
    curl -s -X POST "http://localhost:8001/v1/inference" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\":\"baseline test $i\"}" > /dev/null 2>&1 &
done
wait
echo -e "${GREEN}Done — check Grafana to compare singapore vs vancouver${NC}"

# ─── 10. Recover ───
pause "Recover singapore"
bash deploy.sh recover singapore
bash deploy.sh health

# ─── 11. Rollback ───
pause "Rollback singapore to v1.0.0"
bash deploy.sh rollback singapore
bash deploy.sh version

# ─── Done ───
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                    Demo Complete                         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Summary of what was demonstrated:"
echo "  ✓ Multi-location health verification"
echo "  ✓ Deployment status and version tracking"
echo "  ✓ Inference endpoint testing"
echo "  ✓ Load generation and metric population"
echo "  ✓ Safe canary → rolling rollout"
echo "  ✓ Failure simulation (degraded location)"
echo "  ✓ Failure detection via health checks"
echo "  ✓ Recovery and rollback"
echo ""
echo "Monitoring:"
echo "  Grafana:    http://localhost:3000"
echo "  Prometheus: http://localhost:9090"
echo ""
echo "Teardown: ./deploy.sh teardown"
