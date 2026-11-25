// Runs the real SQL against a real PostgreSQL. Skipped unless TEST_DATABASE_URL is set.
// Use a THROWAWAY database (it leaves test clients behind):
//   docker compose exec db createdb -U ledger ledger_test
//   DATABASE_URL=postgres://ledger:change_me@localhost:5432/ledger_test npm run migrate
//   TEST_DATABASE_URL=postgres://ledger:change_me@localhost:5432/ledger_test npm run test:db
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID as uid } from 'node:crypto';

const URL = process.env.TEST_DATABASE_URL;
const skip = URL ? false : 'TEST_DATABASE_URL is not set';

let pool: typeof import('../src/db.js').pool;
let applyBatch: typeof import('../src/ledger/ops.js').applyBatch;
let loadSnapshot: typeof import('../src/ledger/snapshot.js').loadSnapshot;

before(async () => {
  if (!URL) return;
  process.env.DATABASE_URL = URL;
  process.env.JWT_SECRET ??= 'integration-test-secret-integration-test-secret';
  ({ pool } = await import('../src/db.js'));
  ({ applyBatch } = await import('../src/ledger/ops.js'));
  ({ loadSnapshot } = await import('../src/ledger/snapshot.js'));
});
after(async () => { if (URL) await pool.end(); });

async function newClient(): Promise<string> {
  const { rows } = await pool.query("INSERT INTO clients (display_name, email) VALUES ('IT client', $1) RETURNING id", [`it-${uid()}@test.local`]);
  return rows[0].id;
}
const D = '2026-11-18';
const op = (type: string, rest: Record<string, unknown> = {}) => ({ opId: uid(), type, ...rest });

test('full ledger flow, idempotency and client isolation', { skip }, async () => {
  const A = await newClient();
  const B = await newClient();
  const u1 = uid(), u2 = uid(), e1 = uid(), e2 = uid(), c1 = uid();
  const user = (id: string, name: string, username: string) => op('user.create', { id, name, username, commissionPercent: 10, odd: 80, payment: 5000 });

  // users
  let r = await applyBatch(A, [user(u1, 'Aung', 'aung'), user(u2, 'May', 'may'), user(uid(), 'Dup', 'aung')]);
  assert.deepEqual(r.map((x) => x.status), ['ok', 'ok', 'error']);
  assert.equal(r[2]!.code, 'USERNAME_TAKEN');

  // blocked numbers + vouchers
  const batch = [
    op('blocked.set', { numbers: ['13'] }),
    op('entry.create', { id: uid(), userId: u1, mode: 'manual', date: D, lines: [{ num: '13', amount: 100 }] }),
    op('entry.create', { id: e1, userId: u1, code: 'V00000001', mode: 'format', date: D, lines: [{ num: '05', amount: 1000 }, { num: '12', amount: 500 }] }),
    op('entry.create', { id: e2, userId: u2, code: 'V00000001', mode: 'manual', date: D, lines: [{ num: '05', amount: 200 }] })
  ];
  r = await applyBatch(A, batch);
  assert.equal(r[1]!.code, 'BLOCKED_NUMBER');
  assert.equal(r[2]!.status, 'ok');
  assert.equal(r[2]!.data!.code, 'V00000001');
  assert.equal(r[3]!.status, 'ok');
  assert.notEqual(r[3]!.data!.code, 'V00000001', 'duplicate voucher code must be replaced');

  // idempotency: the same batch again changes nothing and returns the same answers
  const before = await loadSnapshot(pool, A);
  const again = await applyBatch(A, batch);
  assert.deepEqual(again, r);
  assert.deepEqual((await loadSnapshot(pool, A)).entries.length, before.entries.length);
  assert.equal(before.entries.length, 2);

  // update + delete
  r = await applyBatch(A, [op('entry.update', { id: e2, lines: [{ num: '05', amount: 300 }, { num: '77', amount: 10 }] })]);
  assert.equal(r[0]!.status, 'ok');
  assert.deepEqual((await loadSnapshot(pool, A)).entries.find((e) => e.id === e2)!.lines, [{ num: '05', amount: 300 }, { num: '77', amount: 10 }]);

  // cover: eat 300 per number (05=1300, 12=500, 77=10) -> eat 300/300/10, cover 05=1000, 12=200
  r = await applyBatch(A, [op('cover.create', { id: c1, requestedAmount: 300, date: D })]);
  assert.equal(r[0]!.status, 'ok');
  let snap = await loadSnapshot(pool, A);
  assert.deepEqual(snap.coverVouchers[0]!.allocations, [{ num: '05', amount: 300 }, { num: '12', amount: 300 }, { num: '77', amount: 10 }]);
  assert.deepEqual(snap.coverVouchers[0]!.remainingLines, [{ num: '05', amount: 1000 }, { num: '12', amount: 200 }]);
  r = await applyBatch(A, [op('cover.create', { id: uid(), requestedAmount: 100000, date: D }), op('cover.create', { id: uid(), requestedAmount: 300, date: D })]);
  assert.equal(r[0]!.code, 'EAT_LOCKED', 'eat per number is fixed by the first cover voucher');
  assert.equal(r[1]!.code, 'NO_COVER', 'nothing changed since the last voucher');
  // a new stake: only the change is covered
  r = await applyBatch(A, [op('entry.create', { id: uid(), userId: u1, mode: 'manual', date: D, lines: [{ num: '05', amount: 200 }, { num: '40', amount: 500 }] }),
    op('cover.create', { id: uid(), requestedAmount: 300, date: D })]);
  assert.equal(r[1]!.status, 'ok', JSON.stringify(r));
  snap = await loadSnapshot(pool, A);
  assert.deepEqual(snap.coverVouchers[1]!.allocations, [{ num: '40', amount: 300 }]);
  assert.deepEqual(snap.coverVouchers[1]!.remainingLines, [{ num: '05', amount: 200 }, { num: '40', amount: 200 }]);

  // draws
  r = await applyBatch(A, [op('draw.save', { date: D, session: 'morning', number: '05' }), op('draw.save', { date: D, session: 'evening', number: '12' }),
    op('draw.save', { date: D, session: 'evening', number: '21' }), op('draw.delete', { date: D, session: 'evening' })]);
  assert.ok(r.every((x) => x.status === 'ok'));
  snap = await loadSnapshot(pool, A);
  assert.deepEqual(snap.drawResults.map((d) => `${d.session}:${d.number}`), ['morning:05']);

  // finalize morning
  const recIds = { [u1]: uid(), [u2]: uid() };
  r = await applyBatch(A, [op('finalize', { date: D, session: 'morning', recordIds: recIds }), op('finalize', { date: D, session: 'morning' })]);
  assert.equal(r[0]!.status, 'ok');
  assert.equal(r[1]!.code, 'ALREADY_FINALIZED');
  snap = await loadSnapshot(pool, A);
  assert.equal(snap.entries.length, 0, 'finalized vouchers leave the active list');
  assert.equal(snap.coverVouchers.length, 0, 'finalize closes the cover period');
  assert.ok(snap.users.every((u) => u.payment === null), 'payments are reset');
  const rec = snap.finalizedRecords.find((x) => x.id === recIds[u1])!;
  assert.deepEqual({ total: rec.total, winAmount: rec.winAmount, payout: rec.payout, commission: rec.commission, payment: rec.payment, net: rec.net },
    { total: 2200, winAmount: 1200, payout: 96000, commission: 220, payment: 5000, net: 2200 - 96000 - 220 - 5000 });
  assert.deepEqual([rec.covered, rec.eaten], [1360, 840]);
  assert.deepEqual(snap.finalizedRecords.filter((x) => x.userId === u2).map((x) => [x.covered, x.eaten]), [[240, 70]]);
  r = await applyBatch(A, [op('entry.update', { id: e1, lines: [{ num: '01', amount: 1 }] }), op('entry.delete', { id: e1 })]);
  assert.deepEqual(r.map((x) => x.code), ['ENTRY_FINALIZED', 'ENTRY_FINALIZED']);

  // deleting history and draws is allowed and recorded
  r = await applyBatch(A, [op('finalized.delete', { id: recIds[u1]! }), op('draw.delete', { date: D, session: 'morning' }), op('cover.delete', { id: c1 }), op('user.delete', { id: u2 })]);
  assert.deepEqual(r.map((x) => x.code ?? 'ok'), ['ok', 'ok', 'ENTRY_FINALIZED', 'ok'], JSON.stringify(r));
  snap = await loadSnapshot(pool, A);
  assert.ok(!snap.finalizedRecords.some((x) => x.id === recIds[u1]));
  assert.deepEqual(snap.finalizedRecords.map((x) => [x.covered, x.eaten]), [[240, 70]]);

  assert.equal(snap.drawResults.length, 0);
  assert.equal(snap.coverVouchers.length, 0);
  assert.deepEqual(snap.users.map((u) => u.username), ['aung']);
  const audit = await pool.query("SELECT count(*)::int AS n FROM audit_logs WHERE actor_id = $1 AND action LIKE 'ledger.%'", [A]);
  assert.ok(audit.rows[0].n >= 15, 'every change is audited');

  // isolation: B sees nothing of A and cannot touch A's rows
  assert.equal((await loadSnapshot(pool, B)).users.length, 0);
  r = await applyBatch(B, [op('user.update', { id: u1, name: 'Hacked', username: 'x', commissionPercent: 0, odd: 0, payment: null }), op('entry.delete', { id: e2 })]);
  assert.deepEqual(r.map((x) => x.code), ['USER_NOT_FOUND', 'ENTRY_NOT_FOUND']);
});

test('invalid operations are reported without stopping the batch', { skip }, async () => {
  const A = await newClient();
  const r = await applyBatch(A, [{ opId: uid(), type: 'user.create', id: 'nope' }, { type: 'bogus' }, op('blocked.set', { numbers: ['07'] })]);
  assert.deepEqual(r.map((x) => x.status), ['error', 'error', 'ok']);
  assert.equal(r[0]!.code, 'INVALID_OPERATION');
});

test('debt entries sync once, preserve repayment chronology and stay client-scoped', { skip }, async () => {
  const client = await newClient();
  const other = await newClient();
  const userId = uid();
  const debt = (kind: string, date: string, amount: number) =>
    op('debt.record', { id: uid(), userId, date, kind, amount });
  const opening = debt('debt', D, 100.50);
  const later = debt('repayment', '2026-11-20', 60);
  const result = await applyBatch(client, [
    op('user.create', { id: userId, name: 'May', username: 'may', commissionPercent: 10, odd: 80, payment: null }),
    opening, opening, later, debt('repayment', '2026-11-19', 45),
    op('user.delete', { id: userId }),
    debt('repayment', '2026-11-25', 40.50),
  ]);
  assert.deepEqual(result.map((r) => r.code ?? r.status),
    ['ok', 'ok', 'ok', 'ok', 'REPAYMENT_EXCEEDS_DEBT', 'ok', 'ok']);
  assert.deepEqual((await loadSnapshot(pool, client)).debtEntries.map(({kind, amount}) => [kind, amount]),
    [['debt', 100.50], ['repayment', 60], ['repayment', 40.50]]);
  assert.deepEqual((await loadSnapshot(pool, other)).debtEntries, []);
  assert.equal((await applyBatch(other, [debt('repayment', D, 1)]))[0]!.code, 'USER_NOT_FOUND');
});
