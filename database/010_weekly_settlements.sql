BEGIN;

ALTER TABLE ledger_users
  ADD COLUMN settlement_schedule TEXT NOT NULL DEFAULT 'daily'
  CHECK (settlement_schedule IN ('daily', 'weekly'));

ALTER TABLE finalized_records
  ADD COLUMN posts_to_debt BOOLEAN NOT NULL DEFAULT false;

CREATE VIEW ledger_debt_journal AS
  SELECT id, client_id, ledger_user_id, user_name, entry_date, kind, amount,
         created_at, NULL::text AS session
    FROM ledger_debt_entries
  UNION ALL
  SELECT id, client_id, ledger_user_id, user_name, draw_date, 'settlement', net,
         created_at, session
    FROM finalized_records
    WHERE posts_to_debt AND deleted_at IS NULL;

COMMIT;
