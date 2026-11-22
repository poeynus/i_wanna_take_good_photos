import asyncio
import json
from dataclasses import dataclass
from secrets import choice
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from fastapi.security import HTTPAuthorizationCredentials

from auth import current_device, database, device_type
from sessions import CODE_ALPHABET, CreateBody, JoinBody, code_hash, ice_servers, session_for_device, view

router = APIRouter()


@dataclass
class Connection:
    events: asyncio.Queue
    epoch: str


def get_session(pool, session_id, device):
    with pool.connection() as conn:
        return session_for_device(conn, session_id, device)


def update_session(pool, session_id, device, *, accept):
    with pool.connection() as conn:
        row = session_for_device(conn, session_id, device)
        approval_device = row["viewer_id"] if row["nearby"] else row["host_id"]
        if accept and approval_device != device:
            raise HTTPException(403, "Session approval required")
        if accept and row["viewer_id"] is None:
            raise HTTPException(409, "Viewer required")
        if accept:
            updated = conn.execute(
                """UPDATE camera.shoot_sessions SET state = 'accepted'
                   WHERE id = %s AND state IN ('pending', 'accepted')
                   AND expires_at > now() AND viewer_id IS NOT NULL RETURNING id""",
                (session_id,),
            ).fetchone()
            if updated is None:
                raise HTTPException(409, "Session ended")
        else:
            conn.execute("UPDATE camera.shoot_sessions SET state = 'ended' WHERE id = %s",
                         (session_id,))
        return session_for_device(conn, session_id, device)


@router.post("/v1/sessions", status_code=201)
def create_session(request: Request, device: device_type, body: CreateBody | None = None):
    request.app.state.session_limit.check(request)
    ttl = request.app.state.settings.session_ttl_seconds
    session_id = uuid4()
    code = "".join(choice(CODE_ALPHABET) for _ in range(8))
    with database(request).connection() as conn:
        conn.execute("DELETE FROM camera.shoot_sessions WHERE expires_at <= now()")
        viewer = None
        if body is not None:
            recipient = conn.execute(
                """SELECT d.device_id
                   FROM camera.discovery_registrations d
                   JOIN camera.devices v ON v.id = d.device_id
                   WHERE d.token_hash = %s AND d.expires_at > now()
                   AND d.device_id <> %s AND v.revoked_at IS NULL FOR UPDATE OF d""",
                (code_hash(body.token), device),
            ).fetchone()
            if recipient is None:
                raise HTTPException(404, "Nearby device unavailable")
            viewer = recipient["device_id"]
            pending = conn.execute(
                """SELECT id, host_id FROM camera.shoot_sessions
                   WHERE viewer_id = %s AND nearby AND state = 'pending'
                   AND expires_at > now() LIMIT 1""",
                (viewer,),
            ).fetchone()
            if pending is not None:
                if pending["host_id"] == device:
                    return view(session_for_device(conn, pending["id"], device), device)
                raise HTTPException(409, "Nearby device busy")
        conn.execute(
            """INSERT INTO camera.shoot_sessions
               (id, host_id, viewer_id, nearby, code_hash, state, expires_at)
               VALUES (%s, %s, %s, %s, %s, 'pending', now() + %s * interval '1 second')""",
            (session_id, device, viewer, viewer is not None, code_hash(code), ttl),
        )
        row = session_for_device(conn, session_id, device)
    return {**view(row, device), **({"code": code} if viewer is None else {})}


@router.post("/v1/sessions/join")
def join_session(body: JoinBody, request: Request, device: device_type):
    request.app.state.session_limit.check(request)
    with database(request).connection() as conn:
        row = conn.execute(
            """UPDATE camera.shoot_sessions SET viewer_id = %s
               WHERE code_hash = %s AND host_id <> %s AND state = 'pending' AND NOT nearby
               AND expires_at > now() AND (viewer_id IS NULL OR viewer_id = %s)
               RETURNING id, host_id, viewer_id, state, expires_at, nearby""",
            (device, code_hash(body.code), device, device),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Session not available")
    return view(row, device)


@router.get("/v1/sessions/{session_id}")
def read_session(session_id: UUID, request: Request, device: device_type):
    return view(get_session(database(request), session_id, device), device)


@router.get("/v1/sessions/{session_id}/ice-config")
def get_ice(session_id: UUID, request: Request, device: device_type):
    row = get_session(database(request), session_id, device)
    if row["state"] != "accepted":
        raise HTTPException(409, "Session not accepted")
    return {"iceServers": ice_servers(request.app.state.settings, device)}


@router.post("/v1/sessions/{session_id}/accept")
def accept(session_id: UUID, request: Request, device: device_type):
    return view(update_session(database(request), session_id, device, accept=True), device)


@router.delete("/v1/sessions/{session_id}", status_code=204)
def end(session_id: UUID, request: Request, device: device_type):
    update_session(database(request), session_id, device, accept=False)


async def send_event(queue, event):
    await asyncio.wait_for(queue.put(event), timeout=2)


async def relay(websocket, session_id, device, role, peer_queue, message):
    if not isinstance(message, dict) or set(message) - {"type", "sdp", "candidate"}:
        raise ValueError("Invalid signaling message")
    kind = message.get("type")
    if kind == "offer" and role != "host" or kind == "answer" and role != "viewer":
        raise ValueError("Invalid signaling role")
    if kind in ("offer", "answer"):
        data = message.get("sdp")
        if not isinstance(data, str) or not data or len(data) > 24000:
            raise ValueError("Invalid description")
    elif kind == "ice":
        data = message.get("candidate")
        if not isinstance(data, dict) or len(json.dumps(data)) > 4096:
            raise ValueError("Invalid ICE candidate")
    else:
        raise ValueError("Invalid signaling type")
    row = await run_in_threadpool(get_session, database(websocket), session_id, device)
    if row["state"] != "accepted" or peer_queue is None:
        raise ValueError("Session not ready")
    await send_event(peer_queue, message)


@router.websocket("/v1/signaling/{session_id}")
async def signaling(websocket: WebSocket, session_id: UUID):
    authorization = websocket.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer":
        await websocket.close(code=1008)
        return
    try:
        credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)
        device = await run_in_threadpool(current_device, websocket, credentials)
        row = await run_in_threadpool(get_session, database(websocket), session_id, device)
        if row["state"] == "ended":
            raise HTTPException(409, "Session ended")
    except HTTPException:
        await websocket.close(code=1008)
        return

    channels = websocket.app.state.channels
    role = view(row, device)["role"]
    peer = "viewer" if role == "host" else "host"
    key = (session_id, role)
    peer_key = (session_id, peer)
    if key in channels or len(channels) >= 256:
        await websocket.close(code=1013)
        return
    queue = asyncio.Queue(maxsize=64)
    channels[key] = Connection(queue, uuid4().hex)
    incoming = None
    outgoing = None
    try:
        await websocket.accept()
        incoming = asyncio.create_task(websocket.receive_text())
        outgoing = asyncio.create_task(queue.get())
        last_state = None
        while True:
            row = await run_in_threadpool(get_session, database(websocket), session_id, device)
            other = channels.get(peer_key)
            state = {**view(row, device), "peerOnline": other is not None,
                     "peerEpoch": other.epoch if other else None}
            if state != last_state:
                await websocket.send_json({"type": "state", **state})
                last_state = state
            if row["state"] == "ended":
                await websocket.close(code=1000)
                break
            finished, _ = await asyncio.wait(
                (incoming, outgoing), timeout=1, return_when=asyncio.FIRST_COMPLETED
            )
            if incoming in finished:
                text = incoming.result()
                if len(text) > 32000:
                    raise ValueError("Message too large")
                other = channels.get(peer_key)
                await relay(websocket, session_id, device, role, other.events if other else None,
                            json.loads(text))
                incoming = asyncio.create_task(websocket.receive_text())
            if outgoing in finished:
                await websocket.send_json(outgoing.result())
                outgoing = asyncio.create_task(queue.get())
    except WebSocketDisconnect:
        pass
    except (ValueError, HTTPException, TimeoutError):
        await websocket.close(code=1008)
    finally:
        channels.pop(key, None)
        tasks = [task for task in (incoming, outgoing) if task is not None]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
