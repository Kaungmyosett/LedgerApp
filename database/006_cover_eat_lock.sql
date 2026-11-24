-- 006 (v0.6.1): cover vouchers belong to a period that ends at finalize.
-- New cover rule (backend/src/ledger/logic.ts): the eat amount per number is fixed for the period,
-- and each voucher lists only the cover that changed since the previous vouchers.
BEGIN;

ALTER TABLE cover_vouchers ADD COLUMN finalized_at TIMESTAMPTZ;

DROP INDEX IF EXISTS cover_vouchers_client_seq_idx;
CREATE INDEX cover_vouchers_open_seq_idx ON cover_vouchers(client_id, seq)
  WHERE deleted_at IS NULL AND finalized_at IS NULL;

COMMIT;
