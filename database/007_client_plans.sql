-- 007 (v0.7.0): subscription plans per client.
--   basic = 1 month, pro = 3 months. access_until is when the client's access ends.
--   After that the client cannot log in or sync; their ledger data is kept and returns when the Admin extends.
BEGIN;

ALTER TABLE clients ADD COLUMN plan TEXT CHECK (plan IN ('basic', 'pro'));
ALTER TABLE clients ADD COLUMN access_until TIMESTAMPTZ;

-- Clients that existed before plans get one month from now, so nobody is locked out by the upgrade.
UPDATE clients SET plan = 'basic', access_until = now() + interval '1 month' WHERE access_until IS NULL;

COMMIT;
