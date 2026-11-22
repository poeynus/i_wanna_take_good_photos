CREATE SCHEMA IF NOT EXISTS camera;

CREATE TABLE camera.devices (
    id uuid PRIMARY KEY,
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);

CREATE TABLE camera.presets (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES camera.devices(id),
    payload jsonb NOT NULL,
    public boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX presets_owner_recent ON camera.presets(owner_id, updated_at DESC, id);
CREATE INDEX presets_public_recent ON camera.presets(updated_at DESC, id) WHERE public;
