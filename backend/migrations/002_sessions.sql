CREATE TABLE camera.shoot_sessions (
    id uuid PRIMARY KEY,
    host_id uuid NOT NULL REFERENCES camera.devices(id),
    viewer_id uuid REFERENCES camera.devices(id),
    code_hash bytea NOT NULL UNIQUE,
    state text NOT NULL CHECK (state IN ('pending', 'accepted', 'ended')),
    expires_at timestamptz NOT NULL,
    CHECK (viewer_id IS NULL OR host_id <> viewer_id)
);

CREATE INDEX shoot_sessions_expiry ON camera.shoot_sessions(expires_at);
CREATE INDEX shoot_sessions_host ON camera.shoot_sessions(host_id, expires_at);
