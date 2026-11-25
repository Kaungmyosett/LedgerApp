BEGIN;

CREATE TABLE ledger_debt_entries (
  id UUID PRIMARY KEY,
  client_id UUID NOT NULL REFERENCES clients(id),
  ledger_user_id UUID NOT NULL REFERENCES ledger_users(id),
  user_name TEXT NOT NULL,
  entry_date DATE NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('debt', 'repayment')),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ledger_debt_entries_account_idx
  ON ledger_debt_entries (client_id, ledger_user_id, entry_date);
CREATE INDEX ledger_entries_finalized_report_idx
  ON ledger_entries (client_id, finalized_at, entry_date, ledger_user_id)
  WHERE finalized_at IS NOT NULL;
CREATE INDEX cover_vouchers_finalized_report_idx
  ON cover_vouchers (client_id, finalized_at)
  WHERE finalized_at IS NOT NULL;

COMMIT;
