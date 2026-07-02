# PolarGrid SRE — Multi-Location Deployment Automation

A local simulation of a distributed AI inference deployment environment. Deploys a mock inference service across 5 simulated geographic locations with deployment automation, performance monitoring, safe rollout workflows, and failure detection.

## Prerequisites

- Docker & Docker Compose v2+
- bash, curl, make (standard on macOS/Linux; Git Bash on Windows)
- ~2 GB free disk space

## Quick Start

```bash
# 1. Build images
./deploy.sh setup

# 2. Deploy all locations + monitoring
./deploy.sh up

# 3. Check everything is healthy
./deploy.sh health

# 4. Open the monitoring dashboard
#    CLI:     ./monitor.sh
#    Grafana: http://localhost:3000 (anonymous access enabled)
#    Prometheus: http://localhost:9090
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Operator CLI                          │
│              deploy.sh / monitor.sh                      │
└────────────┬────────────────────────────────────────────┘
             │
     ┌───────┴───────────────────────────────────┐
     │          Docker Compose Network            │
     │                                            │
     │  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
     │  │vancouver │  │ toronto  │  │  london  │ │
     │  │ :8001    │  │ :8002    │  │ :8003    │ │
     │  └──────────┘  └──────────┘  └──────────┘ │
     │  ┌──────────┐  ┌──────────┐               │
     │  │frankfurt │  │singapore │               │
     │  │ :8004    │  │ :8005    │               │
     │  └──────────┘  └──────────┘               │
     │                                            │
     │  ┌──────────────┐  ┌──────────────┐       │
     │  │  Prometheus  │  │   Grafana    │       │
     │  │  :9090       │  │   :3000      │       │
     │  └──────────────┘  └──────────────┘       │
     └────────────────────────────────────────────┘
```

Each location runs an independent container with its own:
- Configuration (latency, error rate, GPU metrics)
- Health state
- Version tag
- Performance profile

## Service Endpoints

Each location exposes these endpoints (substitute port for location):

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check — returns 200 (healthy) or 503 (degraded) |
| `/ready` | GET | Readiness probe — returns 200 when service is ready |
| `/metrics` | GET | Prometheus-format metrics |
| `/v1/inference` | POST | Inference endpoint — accepts `{"prompt": "..."}` |
| `/v1/inference/stream` | POST | Streaming inference (SSE) |
| `/info` | GET | Service configuration and version info |

### Location Ports

| Location | Port |
|----------|------|
| vancouver | 8001 |
| toronto | 8002 |
| london | 8003 |
| frankfurt | 8004 |
| singapore | 8005 |

## Operator Guide

### Deployment Operations

```bash
# Full setup (build + pull images)
./deploy.sh setup

# Deploy all locations
./deploy.sh up

# Deploy a single location
./deploy.sh up vancouver

# Stop a single location
./deploy.sh down toronto

# Restart a location
./deploy.sh restart london

# Full teardown (removes containers, networks, volumes)
./deploy.sh teardown
```

### Monitoring & Observability

```bash
# CLI dashboard (refreshes every 3s)
./monitor.sh

# Quick health check
./deploy.sh health

# Deployment status table
./deploy.sh status

# Version inventory
./deploy.sh version
```

**Grafana Dashboard**: http://localhost:3000
- No login required (anonymous viewer enabled)
- Pre-configured dashboard: "PolarGrid Inference — Multi-Location Overview"
- Shows: request rate, P50/P99 latency, error rate, GPU utilization, temperature, memory, health status

**Prometheus**: http://localhost:9090
- Direct PromQL queries
- 5s scrape interval
- 7 pre-configured alerting rules (see `monitoring/alerts.yml`)

### Inspect a Location

```bash
# Health check
curl http://localhost:8001/health

# Service info
curl http://localhost:8001/info

# Run inference
curl -X POST http://localhost:8001/v1/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "hello from the operator"}'

# Raw Prometheus metrics
curl http://localhost:8001/metrics
```

### Version Management

```bash
# Check all versions
./deploy.sh version

# Update one location
./deploy.sh set-version vancouver 2.0.0
```

### Safe Rollout

The rollout command deploys a new version incrementally with health validation:

```bash
./deploy.sh rollout 2.0.0
```

**What it does:**

1. **Canary phase**: Deploys to `vancouver` first
2. **Stabilization**: Waits 10 seconds, runs health check
3. **Abort on failure**: If canary fails, automatically rolls back and stops
4. **Rolling phase**: Deploys to remaining locations one-by-one
5. **Per-location validation**: Health check after each location
6. **Stop on failure**: If any location fails, stops rollout and reports which locations were updated

### Rollback

```bash
# Rollback a specific location
./deploy.sh rollback singapore
```

Resets the location to v1.0.0 and clears any degraded state.

### Failure Simulation

```bash
# Degrade a location (elevated latency, error rate, GPU stress)
./deploy.sh degrade singapore

# Watch the impact in the dashboard
./monitor.sh

# Recover the location
./deploy.sh recover singapore
```

**What degradation does:**
- Sets `DEGRADED=true`
- Increases error rate to 15%
- Increases tail latency probability to 30%
- Service latency increases 2-4x
- GPU utilization spikes toward 99%
- GPU temperature rises
- Health endpoint returns 503 intermittently

### Deployment History

All deployment events (deploys, rollouts, degrades, recovers, rollbacks) are logged to `.deploy_history`.

```bash
# View recent deployment events
./deploy.sh history
```

Shows timestamped audit trail of who did what, when.

### Cross-Location Comparison

```bash
# Compare latency and error rates across all locations (20 requests each)
./compare.sh

# Custom request count
./compare.sh 50
```

### Generate Test Load

```bash
# Load against all locations
./deploy.sh load

# Load against one location
./deploy.sh load vancouver
```

Sends continuous inference requests (~2/sec per location). Ctrl+C to stop.

### Demo Walkthrough

Run the full interactive demo to see every workflow in action:

```bash
./demo.sh
```

Steps through: health checks → status → inference → load generation → safe rollout → failure simulation → detection → recovery → rollback. Pauses between steps for observation.

### Smoke Tests

```bash
./test.sh
```

Runs 29 automated assertions covering all endpoints, metrics, monitoring stack, and cross-location independence. Exits non-zero on failure.

### Teardown

```bash
./deploy.sh teardown
```

Removes all containers, networks, and volumes. Config files are preserved.

## Monitoring Signals

| Metric | Type | Description |
|--------|------|-------------|
| `inference_requests_total` | Counter | Total requests by location, version, status |
| `inference_request_duration_seconds` | Histogram | Request latency distribution |
| `gpu_utilization_percent` | Gauge | Simulated GPU utilization |
| `gpu_memory_used_gb` | Gauge | Simulated GPU VRAM usage |
| `gpu_temperature_celsius` | Gauge | Simulated GPU temperature |
| `inference_active_requests` | Gauge | Currently processing inference requests |
| `inference_queue_depth` | Gauge | Simulated request queue depth |
| `service_healthy` | Gauge | 1 = healthy, 0 = degraded |
| `service_ready` | Gauge | 1 = ready, 0 = not ready |

## File Structure

```
polargrid-sre/
├── README.md              ← You are here
├── DESIGN.md              ← Architecture decisions & tradeoffs
├── Dockerfile             ← Service container image
├── docker-compose.yml     ← Multi-location orchestration
├── Makefile               ← Make shortcuts
├── deploy.sh              ← Primary deployment tool (with history tracking)
├── monitor.sh             ← CLI monitoring dashboard
├── compare.sh             ← Cross-location performance comparison
├── demo.sh                ← Interactive operational walkthrough
├── test.sh                ← Automated smoke tests (29 assertions)
├── service/
│   ├── main.py            ← FastAPI inference service
│   └── requirements.txt
├── configs/
│   ├── vancouver.env      ← Per-location configuration
│   ├── toronto.env
│   ├── london.env
│   ├── frankfurt.env
│   └── singapore.env
└── monitoring/
    ├── prometheus.yml
    ├── alerts.yml             ← Prometheus alerting rules
    └── grafana/
        ├── provisioning/
        │   ├── datasources/datasource.yml
        │   └── dashboards/dashboard.yml
        └── dashboards/
            └── polargrid-overview.json
```
