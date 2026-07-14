-- Documentation copy of the schema created by
-- `dh_server/accounts.ensure_schema` at server startup. This file is not
-- executed by anything; it exists so the schema is visible without reading
-- Gleam source. Keep it in sync with `server/src/dh_server/accounts.gleam`.

CREATE TABLE IF NOT EXISTS accounts (
  id BIGSERIAL PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  salt TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
