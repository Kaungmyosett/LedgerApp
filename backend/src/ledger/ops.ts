import type { PoolClient } from 'pg';
import { z } from 'zod';
import { isPgError, pool, withTransaction } from '../db.js';
import type { Db } from '../db.js';
import { writeAudit } from '../audit.js';
import { buildCoverPlan, lockedEat, makeCoverVoucher, numberBalances, round2, settleUser } from './logic.js';
import type { LCover, Line } from './logic.js';

/** A business-rule failure for one operation. The rest of the batch still runs. */
export class OpError extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
  }
}

// ------------------------------------------------------------------ input schemas
const uuid = z.string().uuid();
const num2 = z.string().regex(/^\d{2}$/, 'number must be 00-99');
const money = z
  .number()
  .finite()
  .positive()
  .max(1e12)
  .refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, 'at most 2 decimals');
const dateStr = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/)
  .refine((v) => !Number.isNaN(Date.parse(v + 'T00:00:00Z')) && new Date(v + 'T00:00:00Z').toISOString().startsWith(v), 'invalid date');
const session = z.enum(['morning', 'evening']);
const lines = z.array(z.object({ num: num2, amount: money }).strict()).min(1).max(1000);
const userFields = {
  name: z.string().trim().min(1).max(100),
  username: z.string().trim().min(1).max(50),
  commissionPercent: z.number().min(0).max(100),
  odd: z.number().min(0).max(100000),
  payment: z.number().min(0).max(1e12).nullable()
};
const opId = uuid;

export const opSchema = z.discriminatedUnion('type', [
  z.object({ opId, type: z.literal('user.create'), id: uuid, ...userFields }).strict(),
  z.object({ opId, type: z.literal('user.update'), id: uuid, ...userFields }).strict(),
  z.object({ opId, type: z.literal('user.delete'), id: uuid }).strict(),
  z.object({ opId, type: z.literal('entry.create'), id: uuid, userId: uuid, code: z.string().max(20).optional(), mode: z.enum(['format', 'manual']), date: dateStr, createdAt: z.string().max(40).optional(), lines }).strict(),
  z.object({ opId, type: z.literal('entry.update'), id: uuid, lines }).strict(),
  z.object({ opId, type: z.literal('entry.delete'), id: uuid }).strict(),
  z.object({ opId, type: z.literal('blocked.set'), numbers: z.array(num2).max(100) }).strict(),
  z.object({ opId, type: z.literal('draw.save'), date: dateStr, session, number: num2 }).strict(),
  z.object({ opId, type: z.literal('draw.delete'), date: dateStr, session }).strict(),
  z.object({ opId, type: z.literal('cover.create'), id: uuid, code: z.string().max(20).optional(), requestedAmount: z.number().int().positive().max(1e12), date: dateStr }).strict(),
  z.object({ opId, type: z.literal('cover.delete'), id: uuid }).strict(),
  z.object({ opId, type: z.literal('finalize'), date: dateStr, session, recordIds: z.record(uuid, uuid).default({}) }).strict(),
  z.object({ opId, type: z.literal('finalized.delete'), id: uuid }).strict()
]);
export type Op = z.infer<typeof opSchema>;
export const syncBodySchema = z.object({ ops: z.array(z.unknown()).max(200) }).strict();

export interface OpResult {
  opId: string;
  status: 'ok' | 'error';
  code?: string;
  message?: string;
  data?: Record<string, unknown>;
}

// ------------------------------------------------------------------ helpers
type Ctx = { db: PoolClient; clientId: string };
const num = (v: unknown): number => Number(v);

async function audit(c: Ctx, action: string, entityType: string, entityId: string | null, before?: unknown, after?: unknown) {
  await writeAudit(c.db, { actorType: 'client', actorId: c.clientId, action: 'ledger.' + action, entityType, entityId, before, after });
}

async function freshCode(c: Ctx, table: 'ledger_entries' | 'cover_vouchers', prefix: string, wanted?: string): Promise<string> {
  const taken = async (code: string) =>
    (await c.db.query(`SELECT 1 FROM ${table} WHERE client_id = $1 AND voucher_code = $2`, [c.clientId, code])).rowCount! > 0;
  if (wanted && new RegExp(`^${prefix}\\d{8}$`).test(wanted) && !(await taken(wanted))) return wanted;
  for (let i = 0; i < 50; i++) {
    const code = prefix + String(Math.floor(Math.random() * 1e8)).padStart(8, '0');
    if (!(await taken(code))) return code;
  }
  throw new OpError('CODE_GENERATION_FAILED', 'Could not generate a voucher code.');
}

async function loadActiveUser(c: Ctx, id: string, lock = false) {
  const { rows } = await c.db.query(
    `SELECT id, name, username, commission_percent, odd, payment FROM ledger_users
      WHERE client_id = $1 AND id = $2 AND deleted_at IS NULL${lock ? ' FOR UPDATE' : ''}`,
    [c.clientId, id]
  );
  return rows[0] as { id: string; name: string; username: string; commission_percent: string; odd: string; payment: string | null } | undefined;
}
const userDto = (r: { name: string; username: string; commission_percent: string; odd: string; payment: string | null }) => ({
  name: r.name, username: r.username, commissionPercent: num(r.commission_percent), odd: num(r.odd), payment: r.payment === null ? null : num(r.payment)
});

async function activeEntryLines(c: Ctx): Promise<{ id: string; userId: string; date: string; lines: Line[] }[]> {
  const { rows } = await c.db.query(
    `SELECT e.id, e.ledger_user_id, to_char(e.entry_date, 'YYYY-MM-DD') AS d, l.number, l.amount::float8 AS amount
       FROM ledger_entries e JOIN ledger_lines l ON l.entry_id = e.id
      WHERE e.client_id = $1 AND e.deleted_at IS NULL AND e.finalized_at IS NULL
      ORDER BY e.created_at, e.id, l.line_no`,
    [c.clientId]
  );
  const byId = new Map<string, { id: string; userId: string; date: string; lines: Line[] }>();
  for (const r of rows) {
    let e = byId.get(r.id);
    if (!e) byId.set(r.id, (e = { id: r.id, userId: r.ledger_user_id, date: r.d, lines: [] }));
    e.lines.push({ num: String(r.number).trim(), amount: num(r.amount) });
  }
  return [...byId.values()];
}

async function activeCovers(c: Ctx): Promise<LCover[]> {
  const { rows } = await c.db.query(
    `SELECT v.id, v.seq::text AS seq, v.requested_amount::float8 AS requested, a.number, a.amount::float8 AS amount, a.kind
       FROM cover_vouchers v LEFT JOIN cover_allocations a ON a.cover_voucher_id = v.id
      WHERE v.client_id = $1 AND v.deleted_at IS NULL AND v.finalized_at IS NULL ORDER BY v.seq`,
    [c.clientId]
  );
  const byId = new Map<string, LCover>();
  for (const r of rows) {
    let v = byId.get(r.id);
    if (!v) byId.set(r.id, (v = { id: r.id, seq: Number(r.seq), requestedAmount: num(r.requested), allocations: [], remainingLines: [] }));
    if (r.number !== null) (r.kind === 'eaten' ? v.allocations : v.remainingLines).push({ num: String(r.number).trim(), amount: num(r.amount) });
  }
  return [...byId.values()];
}

// ------------------------------------------------------------------ handlers
type Handler<T extends Op['type']> = (c: Ctx, op: Extract<Op, { type: T }>) => Promise<Record<string, unknown> | void>;

const handlers: { [K in Op['type']]: Handler<K> } = {
  async 'user.create'(c, op) {
    await c.db.query(
      `INSERT INTO ledger_users (id, client_id, client_local_id, name, username, commission_percent, odd, payment)
       VALUES ($1, $2, $1, $3, $4, $5, $6, $7)`,
      [op.id, c.clientId, op.name, op.username, op.commissionPercent, op.odd, op.payment]
    );
    await audit(c, 'user.create', 'ledger_user', op.id, undefined, { name: op.name, username: op.username, commissionPercent: op.commissionPercent, odd: op.odd, payment: op.payment });
  },

  async 'user.update'(c, op) {
    const before = await loadActiveUser(c, op.id, true);
    if (!before) throw new OpError('USER_NOT_FOUND', 'Commission user not found.');
    await c.db.query(
      `UPDATE ledger_users SET name = $3, username = $4, commission_percent = $5, odd = $6, payment = $7
        WHERE client_id = $1 AND id = $2`,
      [c.clientId, op.id, op.name, op.username, op.commissionPercent, op.odd, op.payment]
    );
    await audit(c, 'user.update', 'ledger_user', op.id, userDto(before), { name: op.name, username: op.username, commissionPercent: op.commissionPercent, odd: op.odd, payment: op.payment });
  },

  async 'user.delete'(c, op) {
    const before = await loadActiveUser(c, op.id, true);
    if (!before) {
      const gone = await c.db.query('SELECT 1 FROM ledger_users WHERE client_id = $1 AND id = $2', [c.clientId, op.id]);
      if (gone.rowCount) return; // already deleted
      throw new OpError('USER_NOT_FOUND', 'Commission user not found.');
    }
    // Old vouchers stay as records (same as the HTML): only the user is hidden.
    await c.db.query('UPDATE ledger_users SET deleted_at = now() WHERE client_id = $1 AND id = $2', [c.clientId, op.id]);
    await audit(c, 'user.delete', 'ledger_user', op.id, userDto(before));
  },

  async 'entry.create'(c, op) {
    if (!(await loadActiveUser(c, op.userId))) throw new OpError('USER_NOT_FOUND', 'Commission user not found.');
    const nums = [...new Set(op.lines.map((l) => l.num))];
    const blocked = await c.db.query('SELECT number FROM blocked_numbers WHERE client_id = $1 AND number::text = ANY($2::text[])', [c.clientId, nums]);
    if (blocked.rowCount) throw new OpError('BLOCKED_NUMBER', 'Blocked numbers: ' + blocked.rows.map((r) => String(r.number).trim()).join(', '));
    const code = await freshCode(c, 'ledger_entries', 'V', op.code);
    const createdAt = op.createdAt && !Number.isNaN(Date.parse(op.createdAt)) ? new Date(op.createdAt) : null;
    await c.db.query(
      `INSERT INTO ledger_entries (id, client_id, client_local_id, ledger_user_id, voucher_code, entry_mode, entry_date, device_created_at)
       VALUES ($1, $2, $1, $3, $4, $5, $6, $7)`,
      [op.id, c.clientId, op.userId, code, op.mode, op.date, createdAt]
    );
    await c.db.query(
      `INSERT INTO ledger_lines (entry_id, line_no, number, amount)
       SELECT $1::uuid, t.ord::int, t.num, t.amount FROM unnest($2::text[], $3::numeric[]) WITH ORDINALITY AS t(num, amount, ord)`,
      [op.id, op.lines.map((l) => l.num), op.lines.map((l) => l.amount)]
    );
    await audit(c, 'entry.create', 'ledger_entry', op.id, undefined, { code, userId: op.userId, mode: op.mode, date: op.date, lines: op.lines });
    return { code };
  },

  async 'entry.update'(c, op) {
    const { rows } = await c.db.query(
      'SELECT voucher_code, finalized_at FROM ledger_entries WHERE client_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE',
      [c.clientId, op.id]
    );
    if (!rows[0]) throw new OpError('ENTRY_NOT_FOUND', 'Voucher not found.');
    if (rows[0].finalized_at) throw new OpError('ENTRY_FINALIZED', 'This voucher is finalized and cannot be changed.');
    const old = await c.db.query('SELECT number, amount::float8 AS amount FROM ledger_lines WHERE entry_id = $1 ORDER BY line_no', [op.id]);
    await c.db.query('DELETE FROM ledger_lines WHERE entry_id = $1', [op.id]);
    await c.db.query(
      `INSERT INTO ledger_lines (entry_id, line_no, number, amount)
       SELECT $1::uuid, t.ord::int, t.num, t.amount FROM unnest($2::text[], $3::numeric[]) WITH ORDINALITY AS t(num, amount, ord)`,
      [op.id, op.lines.map((l) => l.num), op.lines.map((l) => l.amount)]
    );
    await c.db.query('UPDATE ledger_entries SET updated_at = now() WHERE id = $1', [op.id]);
    await audit(c, 'entry.update', 'ledger_entry', op.id,
      { code: rows[0].voucher_code, lines: old.rows.map((r) => ({ num: String(r.number).trim(), amount: num(r.amount) })) }, { lines: op.lines });
  },

  async 'entry.delete'(c, op) {
    const { rows } = await c.db.query(
      'SELECT voucher_code, deleted_at, finalized_at FROM ledger_entries WHERE client_id = $1 AND id = $2 FOR UPDATE',
      [c.clientId, op.id]
    );
    if (!rows[0]) throw new OpError('ENTRY_NOT_FOUND', 'Voucher not found.');
    if (rows[0].deleted_at) return;
    if (rows[0].finalized_at) throw new OpError('ENTRY_FINALIZED', 'This voucher is finalized and cannot be deleted.');
    const old = await c.db.query('SELECT number, amount::float8 AS amount FROM ledger_lines WHERE entry_id = $1 ORDER BY line_no', [op.id]);
    await c.db.query('UPDATE ledger_entries SET deleted_at = now() WHERE id = $1', [op.id]);
    await audit(c, 'entry.delete', 'ledger_entry', op.id, { code: rows[0].voucher_code, lines: old.rows.map((r) => ({ num: String(r.number).trim(), amount: num(r.amount) })) });
  },

  async 'blocked.set'(c, op) {
    const before = await c.db.query('SELECT number FROM blocked_numbers WHERE client_id = $1 ORDER BY number', [c.clientId]);
    await c.db.query('DELETE FROM blocked_numbers WHERE client_id = $1', [c.clientId]);
    const numbers = [...new Set(op.numbers)].sort();
    if (numbers.length) await c.db.query('INSERT INTO blocked_numbers (client_id, number) SELECT $1::uuid, unnest($2::text[])', [c.clientId, numbers]);
    await audit(c, 'blocked.set', 'client', c.clientId, before.rows.map((r) => String(r.number).trim()), numbers);
  },

  async 'draw.save'(c, op) {
    const cur = await c.db.query(
      `SELECT id, number FROM draw_results WHERE client_id = $1 AND draw_date = $2 AND session = $3 AND deleted_at IS NULL FOR UPDATE`,
      [c.clientId, op.date, op.session]
    );
    if (cur.rows[0]) {
      await c.db.query('UPDATE draw_results SET number = $2, entered_at = now() WHERE id = $1', [cur.rows[0].id, op.number]);
      await audit(c, 'draw.update', 'draw_result', cur.rows[0].id, { date: op.date, session: op.session, number: String(cur.rows[0].number).trim() }, { number: op.number });
    } else {
      const ins = await c.db.query('INSERT INTO draw_results (client_id, draw_date, session, number) VALUES ($1, $2, $3, $4) RETURNING id', [c.clientId, op.date, op.session, op.number]);
      await audit(c, 'draw.create', 'draw_result', ins.rows[0].id, undefined, { date: op.date, session: op.session, number: op.number });
    }
  },

  async 'draw.delete'(c, op) {
    const cur = await c.db.query(
      `UPDATE draw_results SET deleted_at = now() WHERE client_id = $1 AND draw_date = $2 AND session = $3 AND deleted_at IS NULL RETURNING id, number`,
      [c.clientId, op.date, op.session]
    );
    if (cur.rows[0]) await audit(c, 'draw.delete', 'draw_result', cur.rows[0].id, { date: op.date, session: op.session, number: String(cur.rows[0].number).trim() });
  },

  async 'cover.create'(c, op) {
    const entries = await activeEntryLines(c);
    const covers = await activeCovers(c);
    const locked = lockedEat(covers);
    if (locked !== null && locked !== op.requestedAmount) {
      throw new OpError('EAT_LOCKED', `စားငွေကို ပထမကာဘောင်ချာအတိုင်း ${locked} သာ သုံးနိုင်သည်။`);
    }
    const made = makeCoverVoucher(buildCoverPlan(numberBalances(entries, covers), op.requestedAmount));
    if (!made) throw new OpError('NO_COVER', 'ကာငွေမရှိပါ — nothing left to cover.');
    const code = await freshCode(c, 'cover_vouchers', 'C', op.code);
    await c.db.query(
      `INSERT INTO cover_vouchers (id, client_id, client_local_id, voucher_code, requested_amount, cover_list_total, voucher_date)
       VALUES ($1, $2, $1, $3, $4, $5, $6)`,
      [op.id, c.clientId, code, op.requestedAmount, made.remainingTotal, op.date]
    );
    const rowsToInsert = [
      ...made.allocations.map((a) => ({ ...a, kind: 'eaten' })),
      ...made.remainingLines.map((a) => ({ ...a, kind: 'remaining' }))
    ];
    if (rowsToInsert.length) {
      await c.db.query(
        `INSERT INTO cover_allocations (cover_voucher_id, number, amount, kind)
         SELECT $1::uuid, t.num, t.amount, t.kind FROM unnest($2::text[], $3::numeric[], $4::text[]) AS t(num, amount, kind)`,
        [op.id, rowsToInsert.map((r) => r.num), rowsToInsert.map((r) => r.amount), rowsToInsert.map((r) => r.kind)]
      );
    }
    await audit(c, 'cover.create', 'cover_voucher', op.id, undefined, { code, requestedAmount: op.requestedAmount, remainingTotal: made.remainingTotal, allocations: made.allocations });
    return { code };
  },

  async 'cover.delete'(c, op) {
    const { rows } = await c.db.query(
      `UPDATE cover_vouchers SET deleted_at = now() WHERE client_id = $1 AND id = $2 AND deleted_at IS NULL AND finalized_at IS NULL RETURNING voucher_code, requested_amount, cover_list_total`,
      [c.clientId, op.id]
    );
    if (rows[0]) {
      await audit(c, 'cover.delete', 'cover_voucher', op.id, { code: rows[0].voucher_code, requestedAmount: num(rows[0].requested_amount), remainingTotal: num(rows[0].cover_list_total) });
      return;
    }
    const exists = await c.db.query('SELECT finalized_at, deleted_at FROM cover_vouchers WHERE client_id = $1 AND id = $2', [c.clientId, op.id]);
    if (!exists.rowCount) throw new OpError('COVER_NOT_FOUND', 'Cover voucher not found.');
    if (exists.rows[0].finalized_at && !exists.rows[0].deleted_at) throw new OpError('ENTRY_FINALIZED', 'This cover voucher is finalized and cannot be deleted.');
  },

  async finalize(c, op) {
    const draw = await c.db.query(
      `SELECT number FROM draw_results WHERE client_id = $1 AND draw_date = $2 AND session = $3 AND deleted_at IS NULL`,
      [c.clientId, op.date, op.session]
    );
    if (!draw.rows[0]) throw new OpError('DRAW_NOT_FOUND', 'No draw result for this date and session.');
    const winning = String(draw.rows[0].number).trim();
    const done = await c.db.query(
      `SELECT 1 FROM finalized_records WHERE client_id = $1 AND draw_date = $2 AND session = $3 AND deleted_at IS NULL LIMIT 1`,
      [c.clientId, op.date, op.session]
    );
    if (done.rowCount) throw new OpError('ALREADY_FINALIZED', 'This draw is already finalized.');

    const users = await c.db.query(
      'SELECT id, name, commission_percent, odd, payment FROM ledger_users WHERE client_id = $1 AND deleted_at IS NULL ORDER BY created_at, id FOR UPDATE',
      [c.clientId]
    );
    const entries = (await activeEntryLines(c)).filter((e) => e.date === op.date);
    const summary: Record<string, unknown>[] = [];
    const settledIds: string[] = [];
    for (const u of users.rows) {
      const userLines = entries.filter((e) => e.userId === u.id).flatMap((e) => e.lines);
      const s = settleUser({ commissionPercent: num(u.commission_percent), odd: num(u.odd), payment: u.payment === null ? null : num(u.payment) }, userLines, winning);
      // v0.6.6: a commission user with no stake on this date gets no history row (and keeps their payment).
      if (s.total === 0) continue;
      settledIds.push(u.id);
      const recordId = op.recordIds[u.id];
      await c.db.query(
        `INSERT INTO finalized_records
           (id, client_id, ledger_user_id, user_name, draw_date, session, winning_number, total_stake, win_stake, odd, payout, commission_percent, commission, payment, net)
         VALUES (COALESCE($15::uuid, gen_random_uuid()), $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
        [c.clientId, u.id, u.name, op.date, op.session, winning, round2(s.total), round2(s.winAmount), s.odd, round2(s.payout), s.commissionPercent, round2(s.commission), round2(s.payment), round2(s.net), recordId ?? null]
      );
      summary.push({ user: u.name, total: round2(s.total), net: round2(s.net) });
    }
    if (!settledIds.length) throw new OpError('NOTHING_TO_FINALIZE', 'No commission user has a stake on this date.');
    // The next settlement starts with an empty payment (HTML behaviour) — for the users that were settled.
    await c.db.query('UPDATE ledger_users SET payment = NULL WHERE client_id = $1 AND id = ANY($2::uuid[])', [c.clientId, settledIds]);
    // The date's vouchers leave the active list but are kept, frozen, for the audit trail.
    const frozen = await c.db.query(
      `UPDATE ledger_entries SET finalized_at = now() WHERE client_id = $1 AND entry_date = $2 AND deleted_at IS NULL AND finalized_at IS NULL`,
      [c.clientId, op.date]
    );
    // A finalize closes the cover period: active cover vouchers are frozen and the eat amount can be chosen again.
    const coversClosed = await c.db.query(
      'UPDATE cover_vouchers SET finalized_at = now() WHERE client_id = $1 AND deleted_at IS NULL AND finalized_at IS NULL',
      [c.clientId]
    );
    await audit(c, 'finalize', 'client', c.clientId, undefined, { date: op.date, session: op.session, number: winning, vouchersFrozen: frozen.rowCount, coversClosed: coversClosed.rowCount, records: summary });
  },

  async 'finalized.delete'(c, op) {
    const { rows } = await c.db.query(
      `UPDATE finalized_records SET deleted_at = now() WHERE client_id = $1 AND id = $2 AND deleted_at IS NULL
       RETURNING user_name, draw_date::text AS d, session, winning_number, total_stake::float8 AS total_stake, net::float8 AS net`,
      [c.clientId, op.id]
    );
    if (rows[0]) {
      await audit(c, 'finalized.delete', 'finalized_record', op.id, { user: rows[0].user_name, date: rows[0].d, session: rows[0].session, number: String(rows[0].winning_number).trim(), total: rows[0].total_stake, net: rows[0].net });
      return;
    }
    const exists = await c.db.query('SELECT 1 FROM finalized_records WHERE client_id = $1 AND id = $2', [c.clientId, op.id]);
    if (!exists.rowCount) throw new OpError('RECORD_NOT_FOUND', 'History record not found.');
  }
};

// ------------------------------------------------------------------ runner
function describeDbError(e: unknown): OpError | null {
  if (isPgError(e)) {
    const k = (e as { constraint?: string }).constraint ?? '';
    if (e.code === '23505') {
      if (k.includes('username')) return new OpError('USERNAME_TAKEN', 'This username is already used.');
      return new OpError('ALREADY_EXISTS', 'This record already exists.');
    }
    if (e.code === '23514' || e.code === '23502' || e.code === '22P02') return new OpError('INVALID_DATA', 'A value was rejected by the database.');
    if (e.code === 'P0001') return new OpError('LOCKED', (e as unknown as Error).message);
  }
  return null;
}

async function storedReceipt(db: Db, clientId: string, key: string): Promise<OpResult | null> {
  const { rows } = await db.query('SELECT response FROM sync_receipts WHERE client_id = $1 AND idempotency_key = $2', [clientId, key]);
  return rows[0] ? (rows[0].response as OpResult) : null;
}

async function saveReceipt(db: Db, clientId: string, op: Op, result: OpResult) {
  await db.query(
    `INSERT INTO sync_receipts (client_id, idempotency_key, operation, response) VALUES ($1, $2, $3, $4)
     ON CONFLICT (client_id, idempotency_key) DO NOTHING`,
    [clientId, op.opId, op.type, JSON.stringify(result)]
  );
}

/** Applies one operation in its own transaction. Safe to call twice with the same opId. */
export async function applyOp(clientId: string, op: Op): Promise<OpResult> {
  const again = await storedReceipt(pool, clientId, op.opId);
  if (again) return again;
  try {
    return await withTransaction(async (db) => {
      // One writer per client at a time; also makes duplicate/parallel batches safe.
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [clientId]);
      const seen = await storedReceipt(db, clientId, op.opId);
      if (seen) return seen;
      const handler = handlers[op.type] as (c: Ctx, o: Op) => Promise<Record<string, unknown> | void>;
      const data = await handler({ db, clientId }, op);
      const result: OpResult = { opId: op.opId, status: 'ok', ...(data ? { data } : {}) };
      await saveReceipt(db, clientId, op, result);
      return result;
    });
  } catch (e) {
    const err = e instanceof OpError ? e : describeDbError(e);
    if (!err) throw e; // unexpected: surface as 500, the app keeps the operation and retries later
    const result: OpResult = { opId: op.opId, status: 'error', code: err.code, message: err.message };
    await saveReceipt(pool, clientId, op, result);
    return result;
  }
}

/** Parses and applies a batch in order. A malformed operation is reported without stopping the others. */
export async function applyBatch(clientId: string, rawOps: unknown[]): Promise<OpResult[]> {
  const results: OpResult[] = [];
  for (const raw of rawOps) {
    const parsed = opSchema.safeParse(raw);
    if (!parsed.success) {
      const id = typeof (raw as { opId?: unknown })?.opId === 'string' ? (raw as { opId: string }).opId : '';
      results.push({ opId: id, status: 'error', code: 'INVALID_OPERATION', message: parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ') });
      continue;
    }
    results.push(await applyOp(clientId, parsed.data));
  }
  return results;
}
