BEGIN;

ALTER TABLE cover_vouchers ADD COLUMN device_created_at TIMESTAMPTZ;

COMMIT;
