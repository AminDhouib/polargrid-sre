import asyncio
import os
import random
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response, StreamingResponse
from prometheus_client import Counter, Histogram, Gauge, CollectorRegistry, generate_latest

LOCATION = os.getenv("LOCATION", "unknown")
VERSION = os.getenv("SERVICE_VERSION", "1.0.0")
BASE_LATENCY_MS = int(os.getenv("BASE_LATENCY_MS", "50"))
TAIL_LATENCY_MS = int(os.getenv("TAIL_LATENCY_MS", "200"))
TAIL_LATENCY_PCTILE = float(os.getenv("TAIL_LATENCY_PCTILE", "0.05"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.02"))
DEGRADED = os.getenv("DEGRADED", "false").lower() == "true"
GPU_UTIL_BASE = float(os.getenv("GPU_UTIL_BASE", "65"))
GPU_MEM_BASE = float(os.getenv("GPU_MEM_BASE", "14"))
GPU_TEMP_BASE = float(os.getenv("GPU_TEMP_BASE", "62"))

registry = CollectorRegistry()
REQUEST_COUNT = Counter(
    "inference_requests_total", "Total inference requests",
    ["location", "version", "status"], registry=registry,
)
REQUEST_LATENCY = Histogram(
    "inference_request_duration_seconds", "Inference latency",
    ["location", "version"], registry=registry,
)
HEALTH_STATUS = Gauge(
    "service_healthy", "1 if healthy, 0 if not",
    ["location", "version"], registry=registry,
)
READY_STATUS = Gauge(
    "service_ready", "1 if ready, 0 if not",
    ["location", "version"], registry=registry,
)
GPU_UTILIZATION = Gauge(
    "gpu_utilization_percent", "Simulated GPU utilization",
    ["location"], registry=registry,
)
GPU_MEMORY = Gauge(
    "gpu_memory_used_gb", "Simulated GPU VRAM usage",
    ["location"], registry=registry,
)
GPU_TEMPERATURE = Gauge(
    "gpu_temperature_celsius", "Simulated GPU temperature",
    ["location"], registry=registry,
)

startup_time = time.time()
ready = False

app = FastAPI(title=f"PolarGrid Inference — {LOCATION}")


@app.on_event("startup")
async def on_startup():
    global ready
    HEALTH_STATUS.labels(location=LOCATION, version=VERSION).set(0 if DEGRADED else 1)
    await asyncio.sleep(1)
    ready = True
    READY_STATUS.labels(location=LOCATION, version=VERSION).set(1)


def simulate_gpu_metrics():
    jitter = random.uniform(-5, 5)
    util = GPU_UTIL_BASE + jitter
    if DEGRADED:
        util = min(99, util + random.uniform(15, 30))
    GPU_UTILIZATION.labels(location=LOCATION).set(round(util, 1))

    mem = GPU_MEM_BASE + random.uniform(-1, 1)
    if DEGRADED:
        mem = min(23.5, mem + random.uniform(3, 6))
    GPU_MEMORY.labels(location=LOCATION).set(round(mem, 1))

    temp = GPU_TEMP_BASE + random.uniform(-3, 3)
    if DEGRADED:
        temp += random.uniform(10, 20)
    GPU_TEMPERATURE.labels(location=LOCATION).set(round(temp, 1))


def compute_latency():
    base = BASE_LATENCY_MS / 1000
    if DEGRADED:
        base *= random.uniform(2.0, 4.0)
    if random.random() < TAIL_LATENCY_PCTILE:
        base += TAIL_LATENCY_MS / 1000
    return base + random.uniform(0, 0.02)


def should_error():
    rate = ERROR_RATE
    if DEGRADED:
        rate = max(rate, 0.15)
    return random.random() < rate


@app.get("/health")
async def health():
    status = "degraded" if DEGRADED else "healthy"
    code = 503 if DEGRADED else 200
    return JSONResponse(
        status_code=code,
        content={
            "status": status,
            "location": LOCATION,
            "version": VERSION,
            "degraded": DEGRADED,
            "uptime_seconds": round(time.time() - startup_time, 1),
        },
    )


@app.get("/metrics")
async def metrics():
    simulate_gpu_metrics()
    return Response(content=generate_latest(registry), media_type="text/plain")


@app.get("/ready")
async def readiness():
    if not ready:
        return JSONResponse(status_code=503, content={"ready": False})
    return {"ready": True, "location": LOCATION}


@app.post("/v1/inference")
async def inference(request: dict = None):
    request = request or {}
    prompt = request.get("prompt", "Hello, world!")

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

    async def generate():
        words = f"{prompt} [from {LOCATION} v{VERSION}]".split()
        for word in words:
            await asyncio.sleep(random.uniform(0.05, 0.15))
            yield f"data: {word}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/info")
async def info():
    return {
        "location": LOCATION,
        "version": VERSION,
        "config": {
            "base_latency_ms": BASE_LATENCY_MS,
            "tail_latency_ms": TAIL_LATENCY_MS,
            "error_rate": ERROR_RATE,
        },
    }
