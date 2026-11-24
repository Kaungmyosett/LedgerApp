-- 005: ledger sync support
--   * cover_vouchers.seq: strict creation order ("latest cover voucher" must never tie on timestamp).
--   * sync_receipts (from 001) is used for idempotency: every operation has a client-generated id,
--     so a batch that is re-sent after a network failure is never applied twice.
BEGIN;

ALTER TABLE cover_vouchers ADD COLUMN seq BIGINT GENERATED ALWAYS AS IDENTITY;
CREATE INDEX cover_vouchers_client_seq_idx ON cover_vouchers(client_id, seq) WHERE deleted_at IS NULL;

CREATE INDEX ledger_entries_active_idx ON ledger_entries(client_id, entry_date)
  WHERE deleted_at IS NULL AND finalized_at IS NULL;

COMMIT;
