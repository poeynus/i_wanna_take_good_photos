from base64 import b64encode
from hashlib import sha256
from hmac import digest
from time import time
from typing import Annotated
from uuid import UUID

from fastapi import HTTPException
from pydantic import BaseModel, StringConstraints

from settings import Settings

CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
Code = Annotated[str, StringConstraints(pattern=f"^[{CODE_ALPHABET}]{{8}}$")]


class JoinBody(BaseModel):
    code: Code


class CreateBody(BaseModel):
    token: Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{32}$")]


def ice_servers(settings: Settings, device: UUID) -> list[dict]:
    servers = [{"urls": settings.stun_urls}] if settings.stun_urls else []
    if settings.turn_urls and settings.turn_shared_secret:
        expires = int(time()) + settings.session_ttl_seconds + 120
        username = f"{expires}:{device}"
        key = settings.turn_shared_secret.get_secret_value().encode()
        credential = b64encode(digest(key, username.encode(), "sha1")).decode()
        servers.append({"urls": settings.turn_urls, "username": username, "credential": credential})
    return servers


def code_hash(code: str) -> bytes:
    return sha256(code.encode()).digest()


def session_row(conn, session_id: UUID):
    return conn.execute(
        """SELECT id, host_id, viewer_id, state, expires_at, nearby
           FROM camera.shoot_sessions WHERE id = %s AND expires_at > now()""",
        (session_id,),
    ).fetchone()


def session_for_device(conn, session_id: UUID, device: UUID):
    row = session_row(conn, session_id)
    if row is None or device not in (row["host_id"], row["viewer_id"]):
        raise HTTPException(404, "Session not found")
    return row


def view(row, device: UUID):
    return {
        "id": str(row["id"]),
        "role": "host" if row["host_id"] == device else "viewer",
        "state": row["state"],
        "viewerJoined": row["viewer_id"] is not None,
        "nearby": row["nearby"],
        "expiresAt": row["expires_at"].isoformat(),
    }
