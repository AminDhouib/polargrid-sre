import os
import time

from fastapi import FastAPI

LOCATION = os.getenv("LOCATION", "unknown")
VERSION = os.getenv("SERVICE_VERSION", "1.0.0")
BASE_LATENCY_MS = int(os.getenv("BASE_LATENCY_MS", "50"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.0"))

startup_time = time.time()

app = FastAPI(title=f"PolarGrid Inference — {LOCATION}")


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "location": LOCATION,
        "version": VERSION,
        "uptime_seconds": round(time.time() - startup_time, 1),
    }


@app.get("/info")
async def info():
    return {
        "location": LOCATION,
        "version": VERSION,
        "config": {
            "base_latency_ms": BASE_LATENCY_MS,
            "error_rate": ERROR_RATE,
        },
    }
