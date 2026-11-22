from secrets import token_hex

from fastapi import APIRouter, Request

from auth import database, device_type
from sessions import code_hash, view

router = APIRouter()


@router.post("/v1/discovery", status_code=201)
def register_discovery(request: Request, device: device_type):
    request.app.state.session_limit.check(request)
    ttl = request.app.state.settings.discovery_ttl_seconds
    token = token_hex(16)
    with database(request).connection() as conn:
        conn.execute("DELETE FROM camera.discovery_registrations WHERE expires_at <= now()")
        found = conn.execute(
            """INSERT INTO camera.discovery_registrations(device_id, token_hash, expires_at)
               VALUES (%s, %s, now() + %s * interval '1 second')
               ON CONFLICT (device_id) DO UPDATE SET token_hash = EXCLUDED.token_hash,
               expires_at = EXCLUDED.expires_at RETURNING expires_at""",
            (device, code_hash(token), ttl),
        ).fetchone()
    return {"token": token, "expiresAt": found["expires_at"].isoformat()}


@router.get("/v1/discovery")
def pending_invitation(request: Request, device: device_type):
    with database(request).connection() as conn:
        row = conn.execute(
            """SELECT s.id, s.host_id, s.viewer_id, s.nearby, s.state, s.expires_at
               FROM camera.shoot_sessions s
               JOIN camera.discovery_registrations d ON d.device_id = s.viewer_id
               WHERE s.viewer_id = %s AND s.nearby AND s.state = 'pending'
               AND s.expires_at > now() AND d.expires_at > now()
               ORDER BY s.expires_at DESC LIMIT 1""",
            (device,),
        ).fetchone()
    return view(row, device) if row else {}


@router.delete("/v1/discovery", status_code=204)
def revoke_discovery(request: Request, device: device_type):
    with database(request).connection() as conn:
        conn.execute("DELETE FROM camera.discovery_registrations WHERE device_id = %s",
                     (device,))
