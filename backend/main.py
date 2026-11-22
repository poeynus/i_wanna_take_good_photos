from contextlib import asynccontextmanager
from hashlib import sha256
from secrets import token_urlsafe
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool, PoolTimeout

from auth import RegistrationLimit, database, device_type
from discovery import router as discovery_router
from signaling import router as signaling_router
from models import PresetWrite
from settings import Settings

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings()
    pool = ConnectionPool(
        settings.database_url.get_secret_value(),
        min_size=1,
        max_size=settings.db_pool_size,
        timeout=settings.request_timeout_seconds,
        kwargs={"row_factory": dict_row, "connect_timeout": settings.request_timeout_seconds,
                "options": f"-c statement_timeout={settings.request_timeout_seconds * 1000}"},
        open=False,
    )
    app.state.pool = pool
    app.state.registration = RegistrationLimit()
    app.state.session_limit = RegistrationLimit()
    app.state.settings = settings
    app.state.channels = {}
    try:
        pool.open(wait=True, timeout=settings.request_timeout_seconds)
        yield
    finally:
        pool.close()


app = FastAPI(title="Camera", lifespan=lifespan)
app.include_router(signaling_router)
app.include_router(discovery_router)


@app.exception_handler(RequestValidationError)
async def invalid_request(_request: Request, _error: RequestValidationError):
    return JSONResponse({"detail": "Invalid request"}, status_code=422)


@app.exception_handler(PoolTimeout)
async def unavailable(_request: Request, _error: PoolTimeout):
    return JSONResponse({"detail": "Database unavailable"}, status_code=503)


preset_fields = "id, payload AS preset, public, updated_at"


@app.get("/health/live")
def live():
    return {"status": "ok"}


@app.get("/health/ready")
def ready(request: Request):
    with database(request).connection() as conn:
        conn.execute("SELECT id FROM camera.devices LIMIT 0")
    return {"status": "ok"}


@app.post("/v1/devices", status_code=201)
def register_device(request: Request, response: Response):
    request.app.state.registration.check(request)
    device_id = uuid4()
    token = token_urlsafe(32)
    with database(request).connection() as conn:
        conn.execute("INSERT INTO camera.devices(id, token_hash) VALUES (%s, %s)",
                     (device_id, sha256(token.encode()).digest()))
    response.headers["Cache-Control"] = "no-store"
    return {"deviceId": device_id, "token": token}


@app.get("/v1/presets")
def list_presets(
    request: Request, device: device_type,
    q: Annotated[str, Query(max_length=60)] = "",
    mine: bool = False,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
    offset: Annotated[int, Query(ge=0, le=10000)] = 0,
):
    with database(request).connection() as conn:
        return conn.execute(
            f"""SELECT {preset_fields} FROM camera.presets
                WHERE (owner_id = %s OR (public AND NOT %s))
                AND strpos(lower(payload->>'name'), lower(%s)) > 0
                ORDER BY updated_at DESC, id LIMIT %s OFFSET %s""",
            (device, mine, q, limit, offset),
        ).fetchall()


@app.post("/v1/presets", status_code=status.HTTP_201_CREATED)
def create_preset(body: PresetWrite, request: Request, device: device_type):
    with database(request).connection() as conn:
        return conn.execute(
            f"""INSERT INTO camera.presets(id, owner_id, payload, public)
                VALUES (%s, %s, %s, %s) RETURNING {preset_fields}""",
            (uuid4(), device, Jsonb(body.preset.model_dump()), body.public),
        ).fetchone()


@app.get("/v1/presets/{preset_id}")
def get_preset(preset_id: UUID, request: Request, device: device_type):
    with database(request).connection() as conn:
        row = conn.execute(
            f"SELECT {preset_fields} FROM camera.presets WHERE id = %s AND (public OR owner_id = %s)",
            (preset_id, device),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Preset not found")
    return row


@app.put("/v1/presets/{preset_id}")
def replace_preset(preset_id: UUID, body: PresetWrite, request: Request, device: device_type):
    with database(request).connection() as conn:
        row = conn.execute(
            f"""UPDATE camera.presets SET payload = %s, public = %s, updated_at = now()
                WHERE id = %s AND owner_id = %s RETURNING {preset_fields}""",
            (Jsonb(body.preset.model_dump()), body.public, preset_id, device),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Preset not found")
    return row


@app.delete("/v1/presets/{preset_id}", status_code=204)
def delete_preset(preset_id: UUID, request: Request, device: device_type):
    with database(request).connection() as conn:
        deleted = conn.execute("DELETE FROM camera.presets WHERE id = %s AND owner_id = %s",
                               (preset_id, device)).rowcount
    if deleted == 0:
        raise HTTPException(404, "Preset not found")
