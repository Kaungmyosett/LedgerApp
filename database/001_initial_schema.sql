-- 2D Ledger initial PostgreSQL schema
-- Single owner-operated business, multiple client accounts.
-- 2D numbers are stored as CHAR(2), preserving leading zeroes (e.g. '07').

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE admin_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton_key BOOLEAN NOT NULL DEFAULT TRUE UNIQUE CHECK (singleton_key = TRUE),
  display_name TEXT NOT NULL,
  phone_e164 TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE clients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name TEXT NOT NULL,
  phone_e164 TEXT UNIQUE,
  email CITEXT UNIQUE,
  password_hash TEXT NOT NULL,
  commission_percent NUMERIC(7,4) NOT NULL DEFAULT 10
    CHECK (commission_percent >= 0 AND commission_percent <= 100),
  odd NUMERIC(12,4) NOT NULL DEFAULT 80 CHECK (odd >= 0),
  payment_balance NUMERIC(18,2),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_by_admin_id UUID REFERENCES admin_accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (phone_e164 IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE blocked_numbers (
  number CHAR(2) PRIMARY KEY CHECK (number ~ '^[0-9]{2}$'),
  created_by_admin_id UUID REFERENCES admin_accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  client_local_id UUID NOT NULL,
  entry_date DATE NOT NULL,
  entry_mode TEXT NOT NULL CHECK (entry_mode IN ('manual','format')),
  status TEXT NOT NULL DEFAULT 'posted'
    CHECK (status IN ('draft','posted','voided')),
  voucher_code TEXT,
  device_created_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  voided_at TIMESTAMPTZ,
  void_reason TEXT,
  UNIQUE (client_id, client_local_id),
  CHECK ((status <> 'voided') OR voided_at IS NOT NULL)
);

CREATE INDEX ledger_entries_client_date_idx
  ON ledger_entries(client_id, entry_date DESC, created_at DESC);

CREATE TABLE ledger_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id UUID NOT NULL REFERENCES ledger_entries(id) ON DELETE RESTRICT,
  line_no INTEGER NOT NULL CHECK (line_no > 0),
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  UNIQUE (entry_id, line_no)
);

CREATE INDEX ledger_lines_number_idx ON ledger_lines(number);

CREATE TABLE draw_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_date DATE NOT NULL,
  session TEXT NOT NULL CHECK (session IN ('morning','evening')),
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  entered_by_admin_id UUID NOT NULL REFERENCES admin_accounts(id),
  entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (draw_date, session)
);

CREATE TABLE cover_vouchers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_code TEXT NOT NULL UNIQUE,
  created_by_admin_id UUID NOT NULL REFERENCES admin_accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note TEXT
);

CREATE TABLE cover_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cover_voucher_id UUID NOT NULL REFERENCES cover_vouchers(id) ON DELETE RESTRICT,
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
  allocation_type TEXT NOT NULL CHECK (allocation_type IN ('eaten','remaining'))
);

CREATE INDEX cover_allocations_voucher_idx ON cover_allocations(cover_voucher_id);

-- Settlement records are immutable snapshots; corrections should be compensating records.
CREATE TABLE settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_result_id UUID NOT NULL REFERENCES draw_results(id),
  client_id UUID NOT NULL REFERENCES clients(id),
  total_stake NUMERIC(18,2) NOT NULL,
  winning_stake NUMERIC(18,2) NOT NULL,
  odd NUMERIC(12,4) NOT NULL,
  payout NUMERIC(18,2) NOT NULL,
  commission_percent NUMERIC(7,4) NOT NULL,
  commission_amount NUMERIC(18,2) NOT NULL,
  payment_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
  net_amount NUMERIC(18,2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (draw_result_id, client_id)
);

CREATE TABLE payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  payment_date DATE NOT NULL,
  note TEXT,
  recorded_by_admin_id UUID NOT NULL REFERENCES admin_accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sync_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id),
  idempotency_key UUID NOT NULL,
  operation TEXT NOT NULL,
  response JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (client_id, idempotency_key)
);

CREATE TABLE audit_logs (
  id BIGSERIAL PRIMARY KEY,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('admin','client','system')),
  actor_id UUID,
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  before_data JSONB,
  after_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_entity_idx ON audit_logs(entity_type, entity_id, created_at DESC);
CREATE INDEX sync_receipts_client_idx ON sync_receipts(client_id, created_at DESC);

-- Email case-insensitive uniqueness requires citext.
COMMIT;
