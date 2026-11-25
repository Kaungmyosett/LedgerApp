import type { Db } from '../db.js';

const n = (v: unknown) => Number(v);

/** Everything the app needs, for one client. Dates are plain 'YYYY-MM-DD' strings; money is a JSON number. */
export async function loadSnapshot(db: Db, clientId: string) {
  // Finalize freezes vouchers and inserts history in one transaction, with a shared
  // PostgreSQL now() timestamp. Keep deleted history rows in the split so a deletion
  // cannot reassign that person's share to the other commission users.
  const [users, entries, blocked, draws, covers, finals, debtEntries, blockedLog] = await Promise.all([
    db.query(
      `SELECT id, name, username, commission_percent::float8 AS commission_percent, odd::float8 AS odd, payment::float8 AS payment, settlement_schedule,
              EXISTS (SELECT 1 FROM ledger_entries e WHERE e.client_id = $1 AND e.ledger_user_id = u.id
                      AND e.finalized_at IS NOT NULL AND e.deleted_at IS NULL) AS has_finalized_vouchers
         FROM ledger_users u WHERE client_id = $1 AND deleted_at IS NULL ORDER BY created_at, id`, [clientId]),
    db.query(
      `SELECT e.id, e.ledger_user_id AS user_id, e.voucher_code, e.entry_mode, e.session, to_char(e.entry_date, 'YYYY-MM-DD') AS d,
              COALESCE(e.device_created_at, e.created_at) AS created,
              (SELECT json_agg(json_build_object('num', trim(l.number), 'amount', l.amount::float8) ORDER BY l.line_no)
                 FROM ledger_lines l WHERE l.entry_id = e.id) AS lines
         FROM ledger_entries e
        WHERE e.client_id = $1 AND e.deleted_at IS NULL AND e.finalized_at IS NULL
        ORDER BY created, e.id`, [clientId]),
    db.query('SELECT trim(number) AS number FROM blocked_numbers WHERE client_id = $1 ORDER BY number', [clientId]),
    db.query(
      `SELECT to_char(draw_date, 'YYYY-MM-DD') AS d, session, trim(number) AS number, entered_at
         FROM draw_results WHERE client_id = $1 AND deleted_at IS NULL ORDER BY draw_date, session`, [clientId]),
    db.query(
      `SELECT v.id, v.voucher_code, v.seq::text AS seq, v.requested_amount::float8 AS requested, v.cover_list_total::float8 AS total,
              v.session, to_char(v.voucher_date, 'YYYY-MM-DD') AS d, COALESCE(v.device_created_at, v.created_at) AS created_at,
              COALESCE((SELECT json_agg(json_build_object('num', trim(a.number), 'amount', a.amount::float8) ORDER BY a.number)
                          FROM cover_allocations a WHERE a.cover_voucher_id = v.id AND a.kind = 'eaten'), '[]'::json) AS allocations,
              COALESCE((SELECT json_agg(json_build_object('num', trim(a.number), 'amount', a.amount::float8) ORDER BY a.number)
                          FROM cover_allocations a WHERE a.cover_voucher_id = v.id AND a.kind = 'remaining'), '[]'::json) AS remaining
         FROM cover_vouchers v WHERE v.client_id = $1 AND v.deleted_at IS NULL AND v.finalized_at IS NULL ORDER BY v.seq`, [clientId]),
    db.query(
      `WITH records AS (
         SELECT * FROM finalized_records WHERE client_id = $1
       ), periods AS (
         SELECT DISTINCT created_at FROM records WHERE deleted_at IS NULL
       ), stakes AS (
         SELECT r.id, r.created_at, r.ledger_user_id, l.number, SUM(l.amount) AS stake
           FROM records r
           JOIN periods p USING (created_at)
           JOIN ledger_entries e ON e.client_id = $1 AND e.finalized_at = r.created_at
             AND e.entry_date = r.draw_date AND e.ledger_user_id = r.ledger_user_id
           JOIN ledger_lines l ON l.entry_id = e.id
          GROUP BY r.id, r.created_at, r.ledger_user_id, l.number
       ), cover_by_number AS (
         SELECT v.finalized_at, a.number, a.kind, SUM(a.amount * 100) AS cents
           FROM periods p
           JOIN cover_vouchers v ON v.client_id = $1 AND v.finalized_at = p.created_at
           JOIN cover_allocations a ON a.cover_voucher_id = v.id
          GROUP BY v.finalized_at, a.number, a.kind
       ), weighted AS (
         SELECT s.*, c.kind, c.cents, c.cents * s.stake AS numerator,
                SUM(s.stake) OVER (PARTITION BY s.created_at, s.number, c.kind) AS denominator
           FROM stakes s JOIN cover_by_number c ON c.finalized_at = s.created_at AND c.number = s.number
       ), ranked AS (
         SELECT *, div(numerator, denominator) AS base,
                ROW_NUMBER() OVER (PARTITION BY created_at, number, kind
                                   ORDER BY mod(numerator, denominator) DESC, ledger_user_id) AS rank
           FROM weighted
       ), distributed AS (
         SELECT id, kind, base + CASE WHEN rank <= cents -
                SUM(base) OVER (PARTITION BY created_at, number, kind) THEN 1 ELSE 0 END AS cents
           FROM ranked
       ), shares AS (
         SELECT id, SUM(cents) FILTER (WHERE kind = 'eaten') / 100 AS eaten,
                SUM(cents) FILTER (WHERE kind = 'remaining') / 100 AS covered
           FROM distributed GROUP BY id
       )
       SELECT r.id, r.ledger_user_id AS user_id, r.user_name, to_char(r.draw_date, 'YYYY-MM-DD') AS d,
              r.session, trim(r.winning_number) AS number, r.total_stake::float8 AS total,
              r.win_stake::float8 AS win_amount, r.odd::float8 AS odd, r.payout::float8 AS payout,
              r.commission::float8 AS commission, r.payment::float8 AS payment, r.net::float8 AS net,
              r.created_at, COALESCE(s.eaten, 0) AS eaten, COALESCE(s.covered, 0) AS covered
         FROM records r LEFT JOIN shares s ON s.id = r.id
        WHERE r.deleted_at IS NULL ORDER BY r.draw_date, r.session, r.created_at, r.id`, [clientId]),
    db.query(
      `SELECT id, ledger_user_id AS user_id, user_name, to_char(entry_date, 'YYYY-MM-DD') AS d, kind, amount, created_at, session
         FROM ledger_debt_journal WHERE client_id = $1 ORDER BY entry_date, created_at, id`, [clientId]),
    db.query(
      `SELECT op_id, ledger_user_id, user_name, trim(number) AS number, amount, created_at
         FROM ledger_blocked_number_log WHERE client_id = $1 ORDER BY created_at DESC, op_id, number`,
      [clientId]
    )
  ]);

  return {
    serverTime: new Date().toISOString(),
    users: users.rows.map((r) => ({
      id: r.id, name: r.name, username: r.username, commissionPercent: n(r.commission_percent), odd: n(r.odd), payment: r.payment === null ? null : n(r.payment),
      settlementSchedule: r.settlement_schedule, hasFinalizedVouchers: r.has_finalized_vouchers
    })),
    entries: entries.rows.map((r) => ({
      id: r.id, userId: r.user_id, code: r.voucher_code, mode: r.entry_mode, date: r.d, session: r.session, createdAt: new Date(r.created).toISOString(), lines: r.lines ?? []
    })),
    blockedLog: blockedLog.rows.map((r) => ({
      opId: r.op_id, userId: r.ledger_user_id, userName: r.user_name, num: r.number,
      amount: n(r.amount), createdAt: new Date(r.created_at).toISOString()
    })),
    blockedNumbers: blocked.rows.map((r) => r.number as string),
    drawResults: draws.rows.map((r) => ({ date: r.d, session: r.session, number: r.number, enteredAt: new Date(r.entered_at).toISOString() })),
    coverVouchers: covers.rows.map((r) => ({
      id: r.id, code: r.voucher_code, seq: n(r.seq), requestedAmount: n(r.requested), coverListTotal: n(r.total), date: r.d,
      createdAt: new Date(r.created_at).toISOString(), session: r.session, allocations: r.allocations, remainingLines: r.remaining
    })),
    debtEntries: debtEntries.rows.map((r) => {
      const amount = n(r.amount);
      // Keep amount and kind readable by older clients. The session marks an automatic posting.
      const kind = r.kind === 'settlement' ? (amount < 0 ? 'repayment' : 'debt') : r.kind;
      return {
        id: r.id, userId: r.user_id, userName: r.user_name, date: r.d, kind,
        amount: Math.abs(amount), session: r.session, createdAt: new Date(r.created_at).toISOString()
      };
    }),
    finalizedRecords: finals.rows.map((r) => ({
      id: r.id, userId: r.user_id, userName: r.user_name, date: r.d, session: r.session, number: r.number, total: n(r.total), winAmount: n(r.win_amount),
      odd: n(r.odd), payout: n(r.payout), commission: n(r.commission), payment: n(r.payment), net: n(r.net), eaten: n(r.eaten), covered: n(r.covered), createdAt: new Date(r.created_at).toISOString()
    }))
  };
}
