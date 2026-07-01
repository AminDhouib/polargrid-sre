import asyncio
import os
import random
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse

LOCATION = os.getenv("LOCATION", "unknown")
VERSION = os.getenv("SERVICE_VERSION", "1.0.0")
BASE_LATENCY_MS = int(os.getenv("BASE_LATENCY_MS", "50"))
TAIL_LATENCY_MS = int(os.getenv("TAIL_LATENCY_MS", "200"))
TAIL_LATENCY_PCTILE = float(os.getenv("TAIL_LATENCY_PCTILE", "0.05"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.02"))
DEGRADED = os.getenv("DEGRADED", "false").lower() == "true"

startup_time = time.time()
ready = False

app = FastAPI(title=f"PolarGrid Inference — {LOCATION}")


@app.on_event("startup")
async def on_startup():
    global ready
    await asyncio.sleep(1)
    ready = True


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
        return JSONResponse(
            status_code=500,
            content={
                "error": "inference_failed",
                "location": LOCATION,
                "version": VERSION,
                "message": "Simulated inference error",
            },
        )

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
