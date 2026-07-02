# Design Notes — PolarGrid SRE Multi-Location Deployment

## Architecture Decisions

### Why Docker Compose for Location Simulation

Each simulated location runs as an independent Docker container on a shared network. This mirrors production isolation — each location has its own process, config, health state, and lifecycle — while remaining runnable on a single laptop.

Alternatives considered:
- **Process-per-location (no Docker)**: Simpler but loses container isolation and makes cleanup harder. Docker gives us port mapping, resource visibility, and a closer analog to real deployment.
- **Kubernetes (kind/minikube)**: More realistic but adds significant setup complexity. For a local simulation, Docker Compose provides the right level of abstraction without requiring cluster tooling.

### Why FastAPI + Python

- Fastest path to a service with health, metrics, and inference endpoints
- Built-in async support for simulating latency without blocking
- prometheus-client library gives Prometheus-compatible metrics with zero config
- Single-file service (~200 lines) keeps the codebase auditable

### Why Prometheus + Grafana

Industry-standard observability stack. Prometheus scrapes each location's `/metrics` endpoint independently — exactly how production monitoring works. Grafana provides pre-built visualization without custom UI work.

The CLI dashboard (`monitor.sh`) supplements Grafana for operators who prefer terminal workflows or don't want to open a browser.

### Why Shell Scripts for Deployment Automation

- Universal availability (bash + curl + docker compose)
- No additional runtime dependencies
- Easy to read and audit
- Matches how many real SRE teams build internal tooling before graduating to more complex systems

### Rollout Strategy

The safe rollout uses a two-phase approach:

1. **Canary**: Deploy to one location (vancouver), wait for stabilization, validate health
2. **Rolling**: Deploy to remaining locations one at a time, health-checking after each

If any location fails its health check, the rollout stops immediately. The operator knows exactly which locations were updated and can make targeted rollback decisions.

This is a simplified version of what tools like Argo Rollouts or Spinnaker provide. Key safeguards:
- **Pre-rollout validation**: `./deploy.sh validate` checks health + readiness of all locations before starting
- **Automatic abort**: If canary fails, the rollout stops and rolls back immediately
- **Event logging**: Every rollout/rollback is recorded in `.deploy_history` for audit

In production, you'd additionally add:
- Automated metric-based canary analysis (error rate comparison over time)
- Traffic shifting (weighted routing, not just deploy-and-check)
- Integration with PagerDuty/OpsGenie for on-call notification

### Per-Location Configuration

Each location has its own `.env` file with tunable parameters:
- **Base latency / tail latency**: Simulates geographic distance and network variability
- **Error rate**: Simulates location-specific reliability
- **GPU metrics**: Simulates hardware utilization differences
- **Degraded flag**: Master switch for failure simulation

This makes it easy to model realistic scenarios (Singapore has higher latency than Vancouver, Frankfurt is under heavier load, etc.)

## Tradeoffs

### Optimized For

- **Operational clarity**: An operator can deploy, monitor, and troubleshoot without reading source code
- **Local runnability**: No cloud accounts, GPUs, or special hardware required
- **Documentation quality**: README covers every operation with copy-paste commands
- **Simplicity**: ~200-line service, single compose file, bash scripts

### Shortcuts Taken

- **No persistent state**: Restarting a container resets metrics. In production, you'd have durable metric storage
- **Simplified rollback**: Rollback resets to v1.0.0 hardcoded. Production would track previous version per location
- **No traffic routing**: Rollout deploys and checks health but doesn't shift traffic gradually. Real canary deployments would use weighted routing
- **Config via env files + sed**: Production would use a config management system or feature flags

### What Would Change in Production

| Area | This Exercise | Production |
|------|---------------|------------|
| Deployment | Docker Compose | Kubernetes + Helm/ArgoCD |
| Location isolation | Containers on one host | Separate clusters per region |
| Config management | .env files | ConfigMaps, Vault, feature flags |
| Rollout | Shell script with health checks | Argo Rollouts with automated canary analysis |
| Monitoring | Prometheus + Grafana + alerts | Same, plus SLO tracking, PagerDuty integration |
| Metrics storage | In-memory (container lifetime) | Thanos/Cortex for long-term storage |
| Service mesh | None | Istio/Linkerd for traffic shifting |
| CI/CD | Manual scripts | GitHub Actions → ArgoCD GitOps |
| Secrets | Plaintext env vars | HashiCorp Vault or cloud KMS |
