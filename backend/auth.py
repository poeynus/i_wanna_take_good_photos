from collections import defaultdict, deque
from hashlib import sha256
from ipaddress import ip_address
from threading import Lock
from time import monotonic
from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

bearer = HTTPBearer(auto_error=False)
credentials_type = Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]
REGISTRATION_LIMIT = 10
REGISTRATION_WINDOW = 60
MAX_REGISTRATION_CLIENTS = 4096


class RegistrationLimit:
    def __init__(self):
        self.clients = defaultdict(deque)
        self.lock = Lock()

    def check(self, request: Request):
        client = request.client.host if request.client else "unknown"
        try:
            client = str(ip_address(client))
        except ValueError:
            pass
        now = monotonic()
        cutoff = now - REGISTRATION_WINDOW
        with self.lock:
            hits = self.clients.get(client)
            if hits is None and len(self.clients) >= MAX_REGISTRATION_CLIENTS:
                expired = [key for key, times in self.clients.items() if times[-1] <= cutoff]
                for key in expired:
                    del self.clients[key]
                if len(self.clients) >= MAX_REGISTRATION_CLIENTS:
                    raise HTTPException(429, "Registration rate limited")
            hits = self.clients[client]
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= REGISTRATION_LIMIT:
                raise HTTPException(429, "Registration rate limited")
            hits.append(now)


def database(request: Request):
    return request.app.state.pool


def current_device(request: Request, credentials: credentials_type) -> UUID:
    if credentials is not None and len(credentials.credentials) == 43:
        digest = sha256(credentials.credentials.encode()).digest()
        with database(request).connection() as conn:
            row = conn.execute(
                "SELECT id FROM camera.devices WHERE token_hash = %s AND revoked_at IS NULL",
                (digest,),
            ).fetchone()
        if row is not None:
            return row["id"]
    raise HTTPException(401, "Device authentication required", {"WWW-Authenticate": "Bearer"})


device_type = Annotated[UUID, Depends(current_device)]
