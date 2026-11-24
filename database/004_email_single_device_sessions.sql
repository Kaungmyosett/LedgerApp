-- 004: decisions confirmed by the owner
--   * Clients are identified by EMAIL (not phone). Login = email + Admin-issued code.
--   * One phone per client: a new login signs the old phone out immediately (session_version).
--   * Two final settlements per day: morning and evening -> draws and finalized records are per session.
--   * Draw results and history (finalized) records can be deleted, but only as a recorded soft delete.
-- draw_results and finalized_records are rebuilt: no API has written to them yet.
BEGIN;

-- Clients: email replaces phone.
ALTER TABLE clients DROP COLUMN phone_e164;
ALTER TABLE clients ADD COLUMN email CITEXT UNIQUE;
-- NOT VALID: earlier test clients (created with a phone) are left alone but cannot log in; new rows need an email.
ALTER TABLE clients ADD CONSTRAINT clients_email_required CHECK (email IS NOT NULL) NOT VALID;

-- Every access token carries the session_version it was issued under. Bumping it signs the account out everywhere at once.
ALTER TABLE clients ADD COLUMN session_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE admin_accounts ADD COLUMN session_version INTEGER NOT NULL DEFAULT 0;

-- Draw results: one per date PER SESSION, soft-deletable.
DROP TABLE draw_results;
CREATE TABLE draw_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  draw_date DATE NOT NULL,
  session TEXT NOT NULL CHECK (session IN ('morning','evening')),
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX draw_results_active_idx ON draw_results(client_id, draw_date, session) WHERE deleted_at IS NULL;
CREATE TRIGGER draw_results_set_updated_at BEFORE UPDATE ON draw_results
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Finalized records: values are frozen forever; the only allowed change is setting deleted_at once.
DROP TABLE finalized_records;
DROP FUNCTION IF EXISTS finalized_records_block_changes();
CREATE TABLE finalized_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  ledger_user_id UUID NOT NULL REFERENCES ledger_users(id),
  user_name TEXT NOT NULL,
  draw_date DATE NOT NULL,
  session TEXT NOT NULL CHECK (session IN ('morning','evening')),
  winning_number CHAR(2) NOT NULL CHECK (winning_number ~ '^[0-9]{2}$'),
  total_stake NUMERIC(18,2) NOT NULL,
  win_stake NUMERIC(18,2) NOT NULL,
  odd NUMERIC(12,4) NOT NULL,
  payout NUMERIC(18,2) NOT NULL,
  commission_percent NUMERIC(7,4) NOT NULL,
  commission NUMERIC(18,2) NOT NULL,
  payment NUMERIC(18,2) NOT NULL DEFAULT 0,
  net NUMERIC(18,2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX finalized_records_active_idx
  ON finalized_records(client_id, draw_date, session, ledger_user_id) WHERE deleted_at IS NULL;
CREATE INDEX finalized_records_client_idx ON finalized_records(client_id, draw_date DESC);

CREATE FUNCTION finalized_records_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
    RAISE EXCEPTION 'finalized_records rows cannot be physically removed (set deleted_at instead)';
  END IF;
  IF OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'finalized record % is already deleted', OLD.id;
  END IF;
  IF (to_jsonb(NEW) - 'deleted_at') IS DISTINCT FROM (to_jsonb(OLD) - 'deleted_at') THEN
    RAISE EXCEPTION 'finalized record values are immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER finalized_records_guard_row BEFORE UPDATE OR DELETE ON finalized_records
  FOR EACH ROW EXECUTE FUNCTION finalized_records_guard();
CREATE TRIGGER finalized_records_guard_truncate BEFORE TRUNCATE ON finalized_records
  FOR EACH STATEMENT EXECUTE FUNCTION finalized_records_guard();

COMMIT;
