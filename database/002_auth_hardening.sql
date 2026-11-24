-- 002: authentication support + integrity hardening
BEGIN;

-- Login lockout / session bookkeeping
ALTER TABLE admin_accounts
  ADD COLUMN failed_login_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN locked_until TIMESTAMPTZ,
  ADD COLUMN last_login_at TIMESTAMPTZ,
  ADD COLUMN password_changed_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE clients
  ADD COLUMN failed_login_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN locked_until TIMESTAMPTZ,
  ADD COLUMN last_login_at TIMESTAMPTZ,
  ADD COLUMN password_changed_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Phone numbers must already be normalized to E.164 by the API
ALTER TABLE admin_accounts
  ADD CONSTRAINT admin_phone_e164_format CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$');
ALTER TABLE clients
  ADD CONSTRAINT clients_phone_e164_format CHECK (phone_e164 IS NULL OR phone_e164 ~ '^\+[1-9][0-9]{7,14}$');

-- Refresh tokens: only a SHA-256 hash is stored, never the token itself.
CREATE TABLE refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_type TEXT NOT NULL CHECK (account_type IN ('admin','client')),
  account_id UUID NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ
);
CREATE INDEX refresh_tokens_account_idx ON refresh_tokens(account_type, account_id) WHERE revoked_at IS NULL;

-- Keep updated_at honest
CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER clients_set_updated_at BEFORE UPDATE ON clients
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER admin_accounts_set_updated_at BEFORE UPDATE ON admin_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Audit log is append-only: block UPDATE / DELETE / TRUNCATE.
CREATE FUNCTION audit_logs_block_changes() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_logs is append-only (% not allowed)', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_logs_no_update_delete BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION audit_logs_block_changes();
CREATE TRIGGER audit_logs_no_truncate BEFORE TRUNCATE ON audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION audit_logs_block_changes();

COMMIT;
