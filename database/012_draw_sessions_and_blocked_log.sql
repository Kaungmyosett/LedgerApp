BEGIN;

ALTER TABLE ledger_entries ADD COLUMN session TEXT;
ALTER TABLE cover_vouchers ADD COLUMN session TEXT;

-- Older frozen rows already belong to their existing immutable history.
UPDATE ledger_entries SET session = CASE
  WHEN EXTRACT(HOUR FROM COALESCE(device_created_at, created_at) AT TIME ZONE 'Asia/Yangon') < 13
    THEN 'morning' ELSE 'evening' END
  WHERE finalized_at IS NULL;
UPDATE cover_vouchers SET session = CASE
  WHEN EXTRACT(HOUR FROM COALESCE(device_created_at, created_at) AT TIME ZONE 'Asia/Yangon') < 13
    THEN 'morning' ELSE 'evening' END
  WHERE finalized_at IS NULL;

ALTER TABLE ledger_entries ADD CONSTRAINT ledger_entries_draw_session_check
  CHECK (session IN ('morning', 'evening') AND session IS NOT NULL OR session IS NULL AND finalized_at IS NOT NULL);
ALTER TABLE cover_vouchers ADD CONSTRAINT cover_vouchers_draw_session_check
  CHECK (session IN ('morning', 'evening') AND session IS NOT NULL OR session IS NULL AND finalized_at IS NOT NULL);

CREATE INDEX ledger_entries_open_draw_idx ON ledger_entries (client_id, entry_date, session)
  WHERE deleted_at IS NULL AND finalized_at IS NULL;
CREATE INDEX cover_vouchers_open_draw_idx ON cover_vouchers (client_id, voucher_date, session)
  WHERE deleted_at IS NULL AND finalized_at IS NULL;

CREATE TABLE ledger_blocked_number_log (
  client_id UUID NOT NULL REFERENCES clients(id),
  op_id UUID NOT NULL,
  ledger_user_id UUID NOT NULL REFERENCES ledger_users(id),
  user_name TEXT NOT NULL,
  number CHAR(2) NOT NULL CHECK (number ~ '^[0-9]{2}$'),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, op_id, number)
);
CREATE INDEX ledger_blocked_number_log_recent_idx ON ledger_blocked_number_log (client_id, created_at DESC);

COMMIT;
