-- 003: correct the data model.
--   * A "client" is a dealer account created by the Admin. Clients log in ONLY with a
--     one-time login code issued by the Admin (no password, no email).
--   * Each client owns a private ledger (the one in ledger_v30.html): its own commission
--     users, vouchers (entries), blocked numbers, draw results, cover vouchers and
--     finalized records. commission % / odd / payment belong to the ledger's commission
--     users, NOT to the client account.
-- The old ledger tables from 001 were never written to by the API, so they are replaced.
BEGIN;

DROP TABLE IF EXISTS settlements, payments, cover_allocations, cover_vouchers,
  draw_results, ledger_lines, ledger_entries, blocked_numbers CASCADE;

-- Clients: phone is the identity; the secret is an Admin-issued code.
ALTER TABLE clients
  DROP COLUMN password_hash,
  DROP COLUMN email,
  DROP COLUMN commission_percent,
  DROP COLUMN odd,
  DROP COLUMN payment_balance;
-- NOT VALID: new/updated rows must have a phone; rows from the earlier test build are not re-checked.
ALTER TABLE clients ADD CONSTRAINT clients_phone_required CHECK (phone_e164 IS NOT NULL) NOT VALID;

-- Sessions created by the old password login are no longer meaningful.
UPDATE refresh_tokens SET revoked_at = now() WHERE account_type = 'client' AND revoked_at IS NULL;

-- Admin-issued login codes. Only a keyed hash is stored; the code is shown to the Admin once.
CREATE TABLE client_login_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  code_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_by_admin_id UUID NOT NULL REFERENCES admin_accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- At most one usable code per client at a time.
CREATE UNIQUE INDEX client_login_codes_one_active
  ON client_login_codes(client_id) WHERE used_at IS NULL AND revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- Ledger (everything below is private to one client; every row carries client_id)
-- client_local_id = id generated on the phone, so an offline draft that is synced twice
-- cannot create two rows.
-- ---------------------------------------------------------------------------

-- "Commission Users" in the HTML.
CREATE TABLE ledger_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  client_local_id UUID NOT NULL,
  name TEXT NOT NULL,
  username TEXT NOT NULL,
  commission_percent NUMERIC(7,4) NOT NULL DEFAULT 10
    CHECK (commission_percent >= 0 AND commission_percent <= 100),
  odd NUMERIC(12,4) NOT NULL DEFAULT 80 CHECK (odd >= 0),
  payment NUMERIC(18,2) CHECK (payment IS NULL OR payment >= 0),
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (client_id, client_local_id)
);
CREATE UNIQUE INDEX ledger_users_username_idx ON ledger_users(client_id, username) WHERE deleted_at IS NULL;

-- Numbers that cannot be bet on, shared by all commission users of that client.
CREATE TABLE blocked_numbers (
  client_id UUID NOT NULL REFERENCES clients(id),
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, number)
);

-- A voucher (ဘောင်ချာ). Never hard-deleted: deleted_at hides it, finalized_at archives it.
CREATE TABLE ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  client_local_id UUID NOT NULL,
  ledger_user_id UUID NOT NULL REFERENCES ledger_users(id),
  voucher_code TEXT NOT NULL,
  entry_mode TEXT NOT NULL CHECK (entry_mode IN ('format','manual')),
  entry_date DATE NOT NULL,
  device_created_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ,
  finalized_at TIMESTAMPTZ,
  UNIQUE (client_id, client_local_id),
  UNIQUE (client_id, voucher_code)
);
CREATE INDEX ledger_entries_client_date_idx ON ledger_entries(client_id, entry_date DESC, created_at DESC);

CREATE TABLE ledger_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id UUID NOT NULL REFERENCES ledger_entries(id) ON DELETE RESTRICT,
  line_no INTEGER NOT NULL CHECK (line_no > 0),
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  UNIQUE (entry_id, line_no)
);
CREATE INDEX ledger_lines_number_idx ON ledger_lines(number);

-- One draw result per date per client (HTML behaviour: saving again for a date overwrites it).
CREATE TABLE draw_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  draw_date DATE NOT NULL,
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  session TEXT NOT NULL CHECK (session IN ('morning','evening')),
  entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (client_id, draw_date)
);

-- Cover vouchers (ကာဘောင်ချာ). allocations = "eaten" per number, remaining = the cover list.
CREATE TABLE cover_vouchers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  client_local_id UUID NOT NULL,
  voucher_code TEXT NOT NULL,
  requested_amount NUMERIC(18,2) NOT NULL CHECK (requested_amount > 0),
  cover_list_total NUMERIC(18,2) NOT NULL CHECK (cover_list_total >= 0),
  voucher_date DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ,
  UNIQUE (client_id, client_local_id),
  UNIQUE (client_id, voucher_code)
);

CREATE TABLE cover_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cover_voucher_id UUID NOT NULL REFERENCES cover_vouchers(id) ON DELETE RESTRICT,
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
  kind TEXT NOT NULL CHECK (kind IN ('eaten','remaining'))
);
CREATE INDEX cover_allocations_voucher_idx ON cover_allocations(cover_voucher_id);

-- Finalized settlement snapshot per commission user (အပြီးစာရင်းချုပ်). Immutable.
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
  UNIQUE (client_id, draw_date, winning_number, ledger_user_id)
);

-- Keep updated_at honest.
CREATE TRIGGER ledger_users_set_updated_at BEFORE UPDATE ON ledger_users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER ledger_entries_set_updated_at BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER draw_results_set_updated_at BEFORE UPDATE ON draw_results
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Finalized records can never be changed or removed.
CREATE FUNCTION finalized_records_block_changes() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'finalized_records is append-only (% not allowed)', TG_OP;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER finalized_records_no_update_delete BEFORE UPDATE OR DELETE ON finalized_records
  FOR EACH ROW EXECUTE FUNCTION finalized_records_block_changes();
CREATE TRIGGER finalized_records_no_truncate BEFORE TRUNCATE ON finalized_records
  FOR EACH STATEMENT EXECUTE FUNCTION finalized_records_block_changes();

-- Once a voucher is finalized its lines are frozen and it cannot be un-finalized.
CREATE FUNCTION ledger_lines_block_if_finalized() RETURNS trigger AS $$
DECLARE
  eid UUID;
  fin TIMESTAMPTZ;
BEGIN
  eid := COALESCE(NEW.entry_id, OLD.entry_id);
  SELECT finalized_at INTO fin FROM ledger_entries WHERE id = eid;
  IF fin IS NOT NULL THEN
    RAISE EXCEPTION 'voucher % is finalized and its lines cannot be changed', eid;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER ledger_lines_frozen_after_finalize BEFORE INSERT OR UPDATE OR DELETE ON ledger_lines
  FOR EACH ROW EXECUTE FUNCTION ledger_lines_block_if_finalized();

CREATE FUNCTION ledger_entries_keep_finalized() RETURNS trigger AS $$
BEGIN
  IF OLD.finalized_at IS NOT NULL AND
     (NEW.finalized_at IS DISTINCT FROM OLD.finalized_at OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at) THEN
    RAISE EXCEPTION 'voucher % is finalized and cannot be changed or deleted', OLD.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER ledger_entries_finalized_guard BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION ledger_entries_keep_finalized();

COMMIT;
