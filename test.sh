#!/usr/bin/env bash
set -euo pipefail

# Automated smoke tests — validates all service endpoints and operational workflows.
# Requires: all locations deployed (./deploy.sh up)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
failed=0

assert() {
    local name="$1" condition="$2"
    if eval "$condition" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $name"
        passed=$((passed+1))
    else
        echo -e "  ${RED}✗${NC} $name"
        failed=$((failed+1))
    fi
}

echo "Running smoke tests..."
echo ""

# ─── Health endpoints ───
echo "Health endpoints:"
for port in 8001 8002 8003 8004 8005; do
    loc=$(curl -s http://localhost:$port/health 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
    assert "$loc health returns 200" \
        "[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$port/health) = '200' ]"
done
echo ""

# ─── Readiness endpoints ───
echo "Readiness endpoints:"
for port in 8001 8002 8003 8004 8005; do
    loc=$(curl -s http://localhost:$port/health 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
    assert "$loc readiness returns 200" \
        "[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$port/ready) = '200' ]"
done
echo ""

# ─── Metrics endpoints ───
echo "Metrics endpoints:"
for port in 8001 8002 8003 8004 8005; do
    loc=$(curl -s http://localhost:$port/health 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
    assert "$loc metrics returns prometheus format" \
        "curl -s http://localhost:$port/metrics | grep -q 'inference_requests_total'"
done
echo ""

# ─── Inference endpoint ───
echo "Inference endpoint:"
resp=$(curl -s -X POST http://localhost:8001/v1/inference \
    -H "Content-Type: application/json" \
    -d '{"prompt":"smoke test"}' 2>/dev/null)
assert "inference returns completion" \
    "echo '$resp' | grep -q 'completion'"
assert "inference returns location" \
    "echo '$resp' | grep -q 'location'"
assert "inference returns latency_ms" \
    "echo '$resp' | grep -q 'latency_ms'"
assert "inference returns version" \
    "echo '$resp' | grep -q 'version'"
echo ""

# ─── Streaming endpoint ───
echo "Streaming endpoint:"
stream_resp=$(curl -s -X POST http://localhost:8001/v1/inference/stream \
    -H "Content-Type: application/json" \
    -d '{"prompt":"stream test"}' 2>/dev/null)
assert "stream returns SSE data" \
    "echo '$stream_resp' | grep -q 'data:'"
assert "stream ends with [DONE]" \
    "echo '$stream_resp' | grep -q 'DONE'"
echo ""

# ─── Info endpoint ───
echo "Info endpoint:"
info=$(curl -s http://localhost:8001/info 2>/dev/null)
assert "info returns location" \
    "echo '$info' | grep -q 'location'"
assert "info returns config" \
    "echo '$info' | grep -q 'base_latency_ms'"
echo ""

# ─── GPU metrics ───
echo "GPU metrics:"
metrics=$(curl -s http://localhost:8001/metrics 2>/dev/null)
assert "gpu_utilization_percent present" \
    "echo '$metrics' | grep -q 'gpu_utilization_percent'"
assert "gpu_memory_used_gb present" \
    "echo '$metrics' | grep -q 'gpu_memory_used_gb'"
assert "gpu_temperature_celsius present" \
    "echo '$metrics' | grep -q 'gpu_temperature_celsius'"
echo ""

# ─── Monitoring stack ───
echo "Monitoring stack:"
assert "Prometheus is healthy" \
    "[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9090/-/healthy) = '200' ]"
assert "Grafana is healthy" \
    "[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health) = '200' ]"
echo ""

# ─── Cross-location independence ───
echo "Location independence:"
v1=$(curl -s http://localhost:8001/health 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
v2=$(curl -s http://localhost:8002/health 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
assert "locations have distinct identities" \
    "[ '$v1' != '$v2' ]"
echo ""

# ─── Queue and active request metrics ───
echo "Queue metrics:"
metrics_van=$(curl -s http://localhost:8001/metrics 2>/dev/null)
assert "active requests metric exists" \
    "echo '$metrics_van' | grep -q 'inference_active_requests'"
assert "queue depth metric exists" \
    "echo '$metrics_van' | grep -q 'inference_queue_depth'"
echo ""

# ─── Prometheus alerting rules ───
echo "Alerting:"
rules_resp=$(curl -s http://localhost:9090/api/v1/rules 2>/dev/null)
assert "alerting rules loaded" \
    "echo '$rules_resp' | grep -q 'LocationUnhealthy'"
assert "alert rules are healthy" \
    "echo '$rules_resp' | grep -q '\"health\":\"ok\"'"
echo ""

# ─── Readiness probe ───
echo "Readiness:"
for port in 8001 8002 8003 8004 8005; do
    loc_name=$(curl -s "http://localhost:$port/info" 2>/dev/null | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
    assert "$loc_name readiness probe" \
        "[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$port/ready) = '200' ]"
done
echo ""

# ─── Results ───
total=$((passed+failed))
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All $total tests passed${NC}"
else
    echo -e "${RED}$failed/$total tests failed${NC}"
    exit 1
fi
