import logging
import pathlib

import psycopg

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import activation, api_admin, api_coins, api_core, api_insights, db, seed

logging.basicConfig(level=logging.INFO)
app = FastAPI(title="Roommate Coins API", version="1.0.0")
STATIC = pathlib.Path(__file__).parent / "static"


@app.on_event("startup")
def startup():
    db.init_pool()
    db.migrate()
    seed.ensure_base()


@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    first = exc.errors()[0] if exc.errors() else {}
    field = ".".join(str(x) for x in first.get("loc", [])[1:])
    return JSONResponse(status_code=422, content={"detail": f"{field}: {first.get('msg', 'invalid')}".strip(": ")})


@app.exception_handler(psycopg.Error)
async def db_error_handler(request: Request, exc: psycopg.Error):
    """Reward-module failures surface as a neutral 503 the client shows as "Coins unavailable right now" (FR-14)."""
    logging.getLogger("api").exception("db error on %s", request.url.path)
    if "/coins/" in request.url.path or request.url.path.endswith("/household"):
        return JSONResponse(status_code=503, content={"detail": "Coins unavailable right now"})
    return JSONResponse(status_code=500, content={"detail": "Something went wrong. Try again."})


app.include_router(api_core.router)
app.include_router(api_coins.router)
app.include_router(api_coins.landing)
app.include_router(api_admin.router)
app.include_router(activation.router)
app.include_router(api_insights.router)
app.mount("/ops/static", StaticFiles(directory=STATIC), name="ops-static")


@app.get("/ops")
def ops_console():
    return FileResponse(STATIC / "ops.html")


@app.get("/health")
def health():
    with db.tx() as conn:
        lag = conn.execute("SELECT count(*) c, min(occurred_at) t FROM outbox_events WHERE processed_at IS NULL").fetchone()
    return {"ok": True, "outbox_pending": lag["c"], "oldest_pending": lag["t"].isoformat() if lag["t"] else None}
