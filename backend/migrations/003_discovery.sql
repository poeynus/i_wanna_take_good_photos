CREATE TABLE camera.discovery_registrations (
    device_id uuid PRIMARY KEY REFERENCES camera.devices(id),
    token_hash bytea NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL
);
CREATE INDEX discovery_expiry ON camera.discovery_registrations(expires_at);

ALTER TABLE camera.shoot_sessions
    ADD COLUMN nearby boolean NOT NULL DEFAULT false;
ALTER TABLE camera.shoot_sessions
    ADD CHECK (NOT nearby OR viewer_id IS NOT NULL);
CREATE INDEX shoot_sessions_viewer ON camera.shoot_sessions(viewer_id, expires_at)
    WHERE nearby AND state = 'pending';
