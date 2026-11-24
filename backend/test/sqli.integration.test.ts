// SQL-injection tests for login and admin lookups. Confirms the parameterized queries treat
// attacker input as literal data: no auth bypass, no error, no change to the database.
// Skipped unless TEST_DATABASE_URL points at a THROWAWAY database (see ledger.integration.test.ts).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID as uid } from 'node:crypto';

const URL = process.env.TEST_DATABASE_URL;
const skip = URL ? false : 'TEST_DATABASE_URL is not set';

let pool: typeof import('../src/db.js').pool;
let hashPassword: typeof import('../src/auth/password.js').hashPassword;
let verifyPassword: typeof import('../src/auth/password.js').verifyPassword;
let normalizePhone: typeof import('../src/util/phone.js').normalizePhone;
let normalizeEmail: typeof import('../src/util/phone.js').normalizeEmail;

before(async () => {
  if (!URL) return;
  process.env.DATABASE_URL = URL;
  process.env.JWT_SECRET ??= 'integration-test-secret-integration-test-secret';
  ({ pool } = await import('../src/db.js'));
  ({ hashPassword, verifyPassword } = await import('../src/auth/password.js'));
  ({ normalizePhone, normalizeEmail } = await import('../src/util/phone.js'));
});
after(async () => { if (URL) await pool.end(); });

// Classic injection payloads an attacker would try in a login or search box.
const PAYLOADS = [
  "' OR '1'='1",
  "' OR 1=1 --",
  "admin' --",
  "'; DROP TABLE admin_accounts; --",
  "' UNION SELECT id, display_name, password_hash, is_active, true FROM admin_accounts --",
  "\\'; DELETE FROM clients; --",
  "' OR ''='",
  "1); DROP TABLE clients; --",
  "' OR SLEEP(5)--",
  "%' OR '1'='1",
  "x'||(SELECT password_hash FROM admin_accounts LIMIT 1)||'"
];

// Exactly the admin-login lookup (routes/auth.ts). Parameterized: the payload can only ever be a phone value.
async function adminLookup(phone: string) {
  const { rows } = await pool.query(
    `SELECT id, display_name, password_hash, is_active,
            (locked_until IS NOT NULL AND locked_until > now()) AS locked
       FROM admin_accounts WHERE phone_e164 = $1`,
    [phone]
  );
  return rows[0];
}

test('admin login cannot be bypassed by SQL injection', { skip }, async () => {
  const phone = '+959' + Math.floor(100000000 + Math.random() * 899999999);
  const password = 'Correct-Horse-Battery-' + uid().slice(0, 8);
  const hash = await hashPassword(password);
  await pool.query('INSERT INTO admin_accounts (display_name, phone_e164, password_hash) VALUES ($1, $2, $3) ON CONFLICT (singleton_key) DO UPDATE SET phone_e164 = $2, password_hash = $3', ['SQLi Admin', phone, hash]);
  const before = (await pool.query('SELECT count(*)::int AS n FROM admin_accounts')).rows[0].n;

  for (const p of PAYLOADS) {
    // Login normalizes the phone first: an injection string is not a phone, so the lookup never runs.
    assert.equal(normalizePhone(p), null, `payload should not be a valid phone: ${p}`);

    // Even if it reached the query directly, it is bound as a literal value: no row, no error.
    const row = await adminLookup(p);
    assert.equal(row, undefined, `injection returned a row: ${p}`);

    // The real password must still be the only thing that verifies.
    const target = await adminLookup(phone);
    assert.ok(target, 'the genuine admin still exists');
    assert.equal(await verifyPassword(target!.password_hash, p), false, `payload verified as password: ${p}`);
  }

  // The real credentials still work, and nothing was dropped or deleted.
  const target = await adminLookup(phone);
  assert.equal(await verifyPassword(target!.password_hash, password), true);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM admin_accounts')).rows[0].n, before, 'admin table untouched');
  assert.ok((await pool.query('SELECT to_regclass($1) AS t', ['public.clients'])).rows[0].t, 'clients table still exists');
});

test('client login (email + code) is injection-proof', { skip }, async () => {
  const email = `sqli-${uid().slice(0, 8)}@test.local`;
  const { rows } = await pool.query('INSERT INTO clients (display_name, email) VALUES ($1, $2) RETURNING id', ['SQLi Client', email]);
  const clientId = rows[0].id;

  for (const p of PAYLOADS) {
    assert.equal(normalizeEmail(p), null, `payload should not be a valid email: ${p}`);
    // The email lookup binds the payload as a value.
    const found = await pool.query('SELECT id FROM clients WHERE email = $1', [p]);
    assert.equal(found.rowCount, 0, `injection matched a client: ${p}`);
    // The one-time code is compared as a literal, never concatenated into SQL.
    const codeHit = await pool.query(
      `SELECT id FROM client_login_codes WHERE client_id = $1 AND code_hash = $2 AND used_at IS NULL`,
      [clientId, p]
    );
    assert.equal(codeHit.rowCount, 0, `injection matched a login code: ${p}`);
  }
  assert.ok((await pool.query('SELECT to_regclass($1) AS t', ['public.client_login_codes'])).rows[0].t);
});

test('admin client search treats injection and LIKE wildcards as literal text', { skip }, async () => {
  const marker = uid().slice(0, 8);
  await pool.query('INSERT INTO clients (display_name, email) VALUES ($1, $2)', [`Keep ${marker}`, `keep-${marker}@test.local`]);
  const before = (await pool.query('SELECT count(*)::int AS n FROM clients')).rows[0].n;

  // Same escaping the route uses before the parameterized LIKE.
  const search = (q: string) => pool.query(
    `SELECT id FROM clients WHERE (display_name ILIKE $1 OR email ILIKE $1)`,
    ['%' + q.replace(/[\\%_]/g, '\\$&') + '%']
  );

  for (const p of [...PAYLOADS, '%', '_', '100%', 'a_b', '\\']) {
    const res = await search(p);
    // A wildcard typed by the user must match literally, so it never returns every client.
    assert.ok(res.rowCount! < before, `search "${p}" returned everything (${res.rowCount}/${before})`);
  }
  // A normal search still finds the row.
  assert.equal((await search(marker)).rowCount, 1);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM clients')).rows[0].n, before, 'search changed no data');
});
