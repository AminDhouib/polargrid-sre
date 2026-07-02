import asyncio
import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse, StreamingResponse
from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

LOCATION = os.getenv("LOCATION", "unknown")
VERSION = os.getenv("SERVICE_VERSION", "1.0.0")
BASE_LATENCY_MS = int(os.getenv("BASE_LATENCY_MS", "50"))
TAIL_LATENCY_MS = int(os.getenv("TAIL_LATENCY_MS", "200"))
TAIL_LATENCY_PCTILE = float(os.getenv("TAIL_LATENCY_PCTILE", "0.05"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.0"))
DEGRADED = os.getenv("DEGRADED", "false").lower() == "true"
GPU_UTIL_BASE = float(os.getenv("GPU_UTIL_BASE", "0.45"))
GPU_MEM_USED_GB = float(os.getenv("GPU_MEM_USED_GB", "12.0"))
GPU_MEM_TOTAL_GB = float(os.getenv("GPU_MEM_TOTAL_GB", "24.0"))
GPU_TEMP_BASE = float(os.getenv("GPU_TEMP_BASE", "62"))

registry = CollectorRegistry()

REQUEST_COUNT = Counter(
    "inference_requests_total",
    "Total inference requests",
    ["location", "version", "status"],
    registry=registry,
)
REQUEST_LATENCY = Histogram(
    "inference_request_duration_seconds",
    "Inference request latency",
    ["location", "version"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
    registry=registry,
)
GPU_UTILIZATION = Gauge(
    "gpu_utilization_percent",
    "Simulated GPU utilization",
    ["location"],
    registry=registry,
)
GPU_MEMORY = Gauge(
    "gpu_memory_used_gb",
    "Simulated GPU memory used",
    ["location"],
    registry=registry,
)
GPU_TEMPERATURE = Gauge(
    "gpu_temperature_celsius",
    "Simulated GPU temperature",
    ["location"],
    registry=registry,
)
HEALTH_STATUS = Gauge(
    "service_healthy",
    "1 if healthy, 0 if not",
    ["location", "version"],
    registry=registry,
)
READY_STATUS = Gauge(
    "service_ready",
    "1 if ready, 0 if not",
    ["location", "version"],
    registry=registry,
)
ACTIVE_REQUESTS = Gauge(
    "inference_active_requests",
    "Currently processing inference requests",
    ["location"],
    registry=registry,
)
QUEUE_DEPTH = Gauge(
    "inference_queue_depth",
    "Simulated request queue depth",
    ["location"],
    registry=registry,
)

startup_time = time.time()
ready = False
active_requests = 0


def simulate_gpu_metrics():
    jitter = random.uniform(-5, 5)
    util = GPU_UTIL_BASE * 100 + jitter
    if DEGRADED:
        util = min(99, util + random.uniform(20, 40))
    GPU_UTILIZATION.labels(location=LOCATION).set(round(util, 1))

    mem_jitter = random.uniform(-0.5, 0.5)
    mem = GPU_MEM_USED_GB + mem_jitter
    if DEGRADED:
        mem = min(GPU_MEM_TOTAL_GB - 0.5, mem + random.uniform(3, 6))
    GPU_MEMORY.labels(location=LOCATION).set(round(mem, 1))

    temp_jitter = random.uniform(-3, 3)
    temp = GPU_TEMP_BASE + temp_jitter
    if DEGRADED:
        temp += random.uniform(10, 25)
    GPU_TEMPERATURE.labels(location=LOCATION).set(round(temp, 1))


def compute_latency() -> float:
    if DEGRADED:
        base = BASE_LATENCY_MS * random.uniform(2.0, 4.0)
    else:
        base = BASE_LATENCY_MS * random.uniform(0.8, 1.2)

    if random.random() < TAIL_LATENCY_PCTILE:
        base = TAIL_LATENCY_MS * random.uniform(0.8, 1.5)
        if DEGRADED:
            base *= random.uniform(2.0, 5.0)

    return base / 1000.0


def should_error() -> bool:
    rate = ERROR_RATE
    if DEGRADED:
        rate = min(1.0, rate + random.uniform(0.1, 0.3))
    return random.random() < rate


@asynccontextmanager
async def lifespan(app: FastAPI):
    global ready
    await asyncio.sleep(1)
    ready = True
    HEALTH_STATUS.labels(location=LOCATION, version=VERSION).set(1)
    READY_STATUS.labels(location=LOCATION, version=VERSION).set(1)
    yield


app = FastAPI(title=f"PolarGrid Inference — {LOCATION}", lifespan=lifespan)


@app.get("/health")
async def health():
    healthy = not DEGRADED or random.random() > 0.3
    status = 200 if healthy else 503
    HEALTH_STATUS.labels(location=LOCATION, version=VERSION).set(1 if healthy else 0)
    return JSONResponse(
        status_code=status,
        content={
            "status": "healthy" if healthy else "degraded",
            "location": LOCATION,
            "version": VERSION,
            "uptime_seconds": round(time.time() - startup_time, 1),
            "degraded": DEGRADED,
        },
    )


@app.get("/ready")
async def readiness():
    is_ready = ready and (not DEGRADED or random.random() > 0.2)
    status = 200 if is_ready else 503
    READY_STATUS.labels(location=LOCATION, version=VERSION).set(1 if is_ready else 0)
    return JSONResponse(
        status_code=status,
        content={"ready": is_ready, "location": LOCATION, "version": VERSION},
    )


@app.get("/metrics")
async def metrics():
    simulate_gpu_metrics()
    return Response(
        content=generate_latest(registry),
        media_type="text/plain; version=0.0.4; charset=utf-8",
    )


@app.post("/v1/inference")
async def inference(request: dict = None):
    global active_requests
    request = request or {}
    prompt = request.get("prompt", "Hello, world!")

    active_requests += 1
    ACTIVE_REQUESTS.labels(location=LOCATION).set(active_requests)
    queue_sim = max(0, active_requests - 4) if DEGRADED else max(0, active_requests - 8)
    QUEUE_DEPTH.labels(location=LOCATION).set(queue_sim)

    try:
        latency = compute_latency()
        await asyncio.sleep(latency)

        if should_error():
            REQUEST_COUNT.labels(location=LOCATION, version=VERSION, status="error").inc()
            REQUEST_LATENCY.labels(location=LOCATION, version=VERSION).observe(latency)
            return JSONResponse(
                status_code=500,
                content={
                    "error": "inference_failed",
                    "location": LOCATION,
                    "version": VERSION,
                    "message": "Simulated inference error",
                },
            )

        REQUEST_COUNT.labels(location=LOCATION, version=VERSION, status="success").inc()
        REQUEST_LATENCY.labels(location=LOCATION, version=VERSION).observe(latency)
    finally:
        active_requests -= 1
        ACTIVE_REQUESTS.labels(location=LOCATION).set(active_requests)
        QUEUE_DEPTH.labels(location=LOCATION).set(max(0, active_requests - 8))

    tokens = prompt.split()
    completion = " ".join(reversed(tokens)) + f" [from {LOCATION} v{VERSION}]"

    return {
        "location": LOCATION,
        "version": VERSION,
        "model": "polargrid-mock-7b",
        "prompt": prompt,
        "completion": completion,
        "tokens_in": len(tokens),
        "tokens_out": len(tokens) + 3,
        "latency_ms": round(latency * 1000, 1),
    }


@app.post("/v1/inference/stream")
async def inference_stream(request: dict = None):
    request = request or {}
    prompt = request.get("prompt", "Hello, world!")

    if should_error():
        REQUEST_COUNT.labels(location=LOCATION, version=VERSION, status="error").inc()
        return JSONResponse(
            status_code=500, content={"error": "stream_failed", "location": LOCATION}
        )

    tokens = prompt.split()
    completion_tokens = list(reversed(tokens)) + [f"[{LOCATION}", f"v{VERSION}]"]

    async def generate():
        total_latency = 0.0
        for i, token in enumerate(completion_tokens):
            chunk_latency = compute_latency() / len(completion_tokens)
            await asyncio.sleep(chunk_latency)
            total_latency += chunk_latency
            yield f"data: {token}\n\n"
        REQUEST_COUNT.labels(
            location=LOCATION, version=VERSION, status="success"
        ).inc()
        REQUEST_LATENCY.labels(location=LOCATION, version=VERSION).observe(
            total_latency
        )
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/info")
async def info():
    return {
        "location": LOCATION,
        "version": VERSION,
        "degraded": DEGRADED,
        "config": {
            "base_latency_ms": BASE_LATENCY_MS,
            "tail_latency_ms": TAIL_LATENCY_MS,
            "error_rate": ERROR_RATE,
            "gpu_util_base": GPU_UTIL_BASE,
        },
    }
