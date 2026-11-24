// Differential test: the TypeScript rules must give exactly the same answers as the original HTML code.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { numberBalances, numbersSummary, parseBlockedNumbers, parseFormat, settleUser, sortDraws } from '../src/ledger/logic.js';
import type { LCover, LDraw, LEntry, LUser } from '../src/ledger/logic.js';

const require = createRequire(import.meta.url);
const { load } = require('./html-harness.cjs');
const HTML = process.env.LEDGER_HTML ?? fileURLToPath(new URL('../../reference/ledger_v31.html', import.meta.url));

// small deterministic PRNG so failures are reproducible
function rng(seed: number) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2 ** 32; }; }
const SEED = Number(process.env.SEED ?? 12345);
const rand = rng(SEED);
const pick = <T,>(a: T[]): T => a[Math.floor(rand() * a.length)]!;
const int = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));
const fmt = (n: number) => Number(n || 0).toLocaleString('en-US');

// ---------------------------------------------------------------- parser
function randomFormatLine(): string {
  const n = () => String(int(0, 99)).padStart(int(1, 2) === 1 ? 1 : 2, '0');
  const amt = () => String(pick([100, 500, 1000, 2500, 5000, 12345, 0, 7]));
  const sep = () => pick([' ', '', '-', '=', ' - ', '  ']);
  const slash = () => Array.from({ length: int(1, 4) }, n).join('/');
  switch (int(0, 15)) {
    case 0: return `${slash()}-R${amt()}`;
    case 1: return `${slash()} R${amt()}`;
    case 2: return `${slash()} ${amt()}`;
    case 3: return `${slash()}=${amt()}`;
    case 4: return `${slash()}-${amt()}`;
    case 5: return `${n()}-${amt()}`;
    case 6: return `${n()} R${amt()}`;
    case 7: return `${int(0, 12)}${pick(['PP', 'pp', 'TO', 'BO', 'BK', 'bk'])}${sep()}${amt()}`;
    case 8: return `${pick(['Apu', 'nyiko', 'POWER', 'Natkat'])} ${amt()}`;
    case 9: return `${n()}${sep()}${amt()}`;
    case 10: return pick(['abc', '12/', '/12 100', '123-100', '12-', 'R100', '', '  ', '12 R', '1 PP', '1PP-', '1PP 5.5', '12.5 100']);
    case 11: return `${slash()}${sep()}R${amt()}`;
    case 12: return `${n()}/${n()}${sep()}${amt()}`;
    default: return `${n()} ${amt()}`;
  }
}

test('parseFormat matches the HTML on 4000 random inputs', () => {
  const { run } = load(HTML);
  for (let i = 0; i < 4000; i++) {
    const raw = Array.from({ length: int(1, 4) }, randomFormatLine).join(pick(['\n', ',', ';', '\r\n', ' , ']));
    // v0.6.7: "=" before/after R and after PP/TO/BO/BK means "-" (the HTML only knows "-"), so compare with that spelling.
    const htmlRaw = raw.split(/([\n,;]+)/).map((p) => (/(R|PP|TO|BO|BK)/i.test(p) ? p.replace(/=/g, '-') : p)).join('');
    const expected = run(`parseFormat(${JSON.stringify(htmlRaw)})`);
    const got = parseFormat(raw);
    if (htmlRaw === raw) {
      assert.deepStrictEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(expected)), `input: ${JSON.stringify(raw)}`);
    } else {
      assert.deepStrictEqual(JSON.parse(JSON.stringify(got.result)), JSON.parse(JSON.stringify(expected.result)), `input: ${JSON.stringify(raw)}`);
      assert.equal(got.errors.length, expected.errors.length, `input: ${JSON.stringify(raw)}`);
    }
  }
});

test('parseFormat matches the HTML on the documented examples', () => {
  const { run } = load(HTML);
  const cases = ['12/45-R1000', '12/45 1000', '12/45=1000', '11/22/33-1000', '00-5000', '51 R2000', '51 2000', '1PP 1000', '1TO 1000', '1BO 1000',
    '1BK 1000', 'Apu 1000', 'Nyiko 1000', 'Power 1000', 'Natkat 1000', '12/45-R1000\n00-5000\n55-3000', '11 R500', '12-R100'];
  for (const raw of cases) assert.deepStrictEqual(JSON.parse(JSON.stringify(parseFormat(raw))), JSON.parse(JSON.stringify(run(`parseFormat(${JSON.stringify(raw)})`))), raw);
});

test('parseBlockedNumbers matches the HTML', () => {
  const { run } = load(HTML);
  for (const raw of ['12,34,56', '5 05 5', '100, 7;9/ 03', 'x,12', '', '00 99 98 1']) {
    assert.deepStrictEqual(parseBlockedNumbers(raw), JSON.parse(JSON.stringify(run(`parseBlockedNumbers(${JSON.stringify(raw)})`))), raw);
  }
});

// ---------------------------------------------------------------- scenarios
function scenario() {
  const users: LUser[] = Array.from({ length: int(1, 3) }, (_, i) => ({
    id: 'u' + (i + 1), name: 'U' + (i + 1), username: 'user' + (i + 1),
    commissionPercent: pick([0, 5, 7.5, 10, 12.5, 15, 20, 33.33]), odd: pick([70, 75, 80, 80, 85, 90, 82.5]),
    payment: pick([null, null, 0, 1000, 25000])
  }));
  const dates = ['2026-11-18', '2026-11-19'];
  const entries: LEntry[] = Array.from({ length: int(0, 7) }, (_, i) => ({
    id: 'e' + i, userId: pick(users).id, date: pick(dates),
    lines: Array.from({ length: int(1, 6) }, () => ({ num: String(int(0, 99)).padStart(2, '0'), amount: pick([100, 300, 500, 1000, 2500, 777, 12000]) }))
  }));
  const draws: LDraw[] = [];
  for (const d of dates) for (const s of ['morning', 'evening'] as const) if (rand() < 0.6) draws.push({ date: d, session: s, number: String(int(0, 99)).padStart(2, '0') });
  return { users, entries, draws };
}

function seedHtml(run: (c: string) => any, users: LUser[], entries: LEntry[], draws: LDraw[]) {
  run(`db.users=${JSON.stringify(users)};db.entries=${JSON.stringify(entries.map((e) => ({ ...e, voucher: e.id, created: '2026-11-18T00:00:00.000Z' })))};db.drawResults=${JSON.stringify(draws.map((d) => ({ ...d, enteredAt: 'x' })))};db.coverVouchers=[];db.finalizedRecords=[];db.blockedNumbers=[]`);
}

test('balances (no cover), numbers summary and settlement match the HTML (600 random ledgers)', () => {
  const { run, els } = load(HTML);
  for (let iter = 0; iter < 600; iter++) {
    const { users, entries, draws } = scenario();
    seedHtml(run, users, entries, draws);
    // Cover vouchers follow the owner's new rule (v0.6.1) and are tested in cover.test.ts, not against the HTML.
    const covers: LCover[] = [];
    // balances
    const htmlBal = run('numberBalances()');
    assert.deepStrictEqual(JSON.parse(JSON.stringify(numberBalances(entries, covers))), JSON.parse(JSON.stringify(htmlBal)), 'balances');
    // numbers page
    run('renderNumbers()');
    const html = els.numbersPanel.innerHTML as string;
    const s = numbersSummary(users, entries, covers, draws);
    assert.ok(html.includes(`${s.activeCount} / 100`), `active count ${s.activeCount}`);
    assert.ok(html.includes(`<td class="money">${fmt(s.totalGross)} ကျပ်</td><td class="money">${fmt(s.totalEaten)} ကျပ်</td><td class="money">${fmt(s.totalCover)} ကျပ်</td>`), 'totals row');
    if (s.winning) {
      assert.ok(html.includes(`တင်ငွ (${s.winning})</label><strong>${fmt(s.winGross)}</strong>`), 'winning gross');
      // yourEaten follows the owner's v0.6.6 rule (no cover -> computed from the total stake); tested in cover.test.ts.
      assert.ok(html.includes(`>${fmt(Math.abs(s.otherDealerCover))}</strong>`), `otherDealerCover ${s.otherDealerCover}`);
      assert.ok(html.includes(s.otherDealerCover > 0 ? 'ဒိုင်ကိုပေးရန်' : 'ဒိုင်စီမှရရန်'));
    }
    // latest draw order
    const htmlLatest = run('sortDraws().map(d=>d.date+"|"+d.session+"|"+d.number)');
    assert.deepStrictEqual(sortDraws(draws).map((d) => `${d.date}|${d.session}|${d.number}`), JSON.parse(JSON.stringify(htmlLatest)));
    // finalize the latest unfinalized draw in HTML and compare every record
    for (const d of sortDraws(draws).slice(0, 1)) {
      run(`confirmFinalize(${JSON.stringify(d.date)},${JSON.stringify(d.session)})`);
      const recs = run('db.finalizedRecords') as any[];
      assert.equal(recs.length, users.length);
      for (const r of recs) {
        const u = users.find((x) => x.id === r.userId)!;
        const lines = entries.filter((e) => e.userId === u.id && e.date === d.date).flatMap((e) => e.lines);
        const st = settleUser(u, lines, d.number);
        assert.deepStrictEqual(
          { total: st.total, winAmount: st.winAmount, odd: st.odd, payout: st.payout, commission: st.commission, payment: st.payment, net: st.net },
          { total: r.total, winAmount: r.winAmount, odd: r.odd, payout: r.payout, commission: r.commission, payment: r.payment, net: r.net }, 'settlement');
      }
    }
  }
});
