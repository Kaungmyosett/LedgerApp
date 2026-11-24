import type { Db } from '../db.js';

const n = (v: unknown) => Number(v);

/** Everything the app needs, for one client. Dates are plain 'YYYY-MM-DD' strings; money is a JSON number. */
export async function loadSnapshot(db: Db, clientId: string) {
  const [users, entries, blocked, draws, covers, finals] = await Promise.all([
    db.query(
      `SELECT id, name, username, commission_percent::float8 AS commission_percent, odd::float8 AS odd, payment::float8 AS payment
         FROM ledger_users WHERE client_id = $1 AND deleted_at IS NULL ORDER BY created_at, id`, [clientId]),
    db.query(
      `SELECT e.id, e.ledger_user_id AS user_id, e.voucher_code, e.entry_mode, to_char(e.entry_date, 'YYYY-MM-DD') AS d,
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
              to_char(v.voucher_date, 'YYYY-MM-DD') AS d, v.created_at,
              COALESCE((SELECT json_agg(json_build_object('num', trim(a.number), 'amount', a.amount::float8) ORDER BY a.number)
                          FROM cover_allocations a WHERE a.cover_voucher_id = v.id AND a.kind = 'eaten'), '[]'::json) AS allocations,
              COALESCE((SELECT json_agg(json_build_object('num', trim(a.number), 'amount', a.amount::float8) ORDER BY a.number)
                          FROM cover_allocations a WHERE a.cover_voucher_id = v.id AND a.kind = 'remaining'), '[]'::json) AS remaining
         FROM cover_vouchers v WHERE v.client_id = $1 AND v.deleted_at IS NULL AND v.finalized_at IS NULL ORDER BY v.seq`, [clientId]),
    db.query(
      `SELECT id, ledger_user_id AS user_id, user_name, to_char(draw_date, 'YYYY-MM-DD') AS d, session, trim(winning_number) AS number,
              total_stake::float8 AS total, win_stake::float8 AS win_amount, odd::float8 AS odd, payout::float8 AS payout,
              commission::float8 AS commission, payment::float8 AS payment, net::float8 AS net, created_at
         FROM finalized_records WHERE client_id = $1 AND deleted_at IS NULL ORDER BY draw_date, session, created_at, id`, [clientId])
  ]);

  return {
    serverTime: new Date().toISOString(),
    users: users.rows.map((r) => ({
      id: r.id, name: r.name, username: r.username, commissionPercent: n(r.commission_percent), odd: n(r.odd), payment: r.payment === null ? null : n(r.payment)
    })),
    entries: entries.rows.map((r) => ({
      id: r.id, userId: r.user_id, code: r.voucher_code, mode: r.entry_mode, date: r.d, createdAt: new Date(r.created).toISOString(), lines: r.lines ?? []
    })),
    blockedNumbers: blocked.rows.map((r) => r.number as string),
    drawResults: draws.rows.map((r) => ({ date: r.d, session: r.session, number: r.number, enteredAt: new Date(r.entered_at).toISOString() })),
    coverVouchers: covers.rows.map((r) => ({
      id: r.id, code: r.voucher_code, seq: n(r.seq), requestedAmount: n(r.requested), coverListTotal: n(r.total), date: r.d,
      createdAt: new Date(r.created_at).toISOString(), allocations: r.allocations, remainingLines: r.remaining
    })),
    finalizedRecords: finals.rows.map((r) => ({
      id: r.id, userId: r.user_id, userName: r.user_name, date: r.d, session: r.session, number: r.number, total: n(r.total), winAmount: n(r.win_amount),
      odd: n(r.odd), payout: n(r.payout), commission: n(r.commission), payment: n(r.payment), net: n(r.net), createdAt: new Date(r.created_at).toISOString()
    }))
  };
}
