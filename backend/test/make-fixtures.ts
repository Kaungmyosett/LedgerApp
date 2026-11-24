// Generates the golden fixtures the Flutter tests check against.
// Expected values come from running the ORIGINAL HTML code (not from the TypeScript port).
// Run (Node 22+):  node --experimental-strip-types test/make-fixtures.ts <ledger.html> <out.json>
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
import { buildCoverPlan, makeCoverVoucher, numberBalances, numbersSummary, sortDraws } from '../src/ledger/logic.ts';
import type { LCover, LDraw, LEntry, LUser } from '../src/ledger/logic.ts';

const require = createRequire(import.meta.url);
const { load } = require('./html-harness.cjs');
const [htmlPath, outPath] = process.argv.slice(2);
if (!htmlPath || !outPath) throw new Error('usage: make-fixtures.ts <ledger.html> <out.json>');
const { run } = load(htmlPath);
const plain = (x: unknown) => JSON.parse(JSON.stringify(x));

let s = 20261121;
const rand = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2 ** 32; };
const pick = <T,>(a: T[]): T => a[Math.floor(rand() * a.length)]!;
const int = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));

// ---- parser cases
const fixed = ['12/45-R1000', '12/45 1000', '12/45=1000', '11/22/33-1000', '00-5000', '51 R2000', '51 2000', '1PP 1000', '1TO 1000', '1BO 1000',
  '1BK 1000', '0BK 5', '9BK 5', 'Apu 1000', 'Nyiko 1000', 'Power 1000', 'Natkat 1000', '12/45-R1000\n00-5000\n55-3000', '11 R500', '12-R100',
  '12 R', 'abc', '', '123-100', '10PP 100', '1PP 5.5', '5,6;7\n8 100'];
const n = () => String(int(0, 99)).padStart(int(1, 2) === 1 ? 1 : 2, '0');
const amt = () => String(pick([100, 500, 1000, 2500, 5000, 12345, 0, 7]));
const slash = () => Array.from({ length: int(1, 4) }, n).join('/');
function line(): string {
  switch (int(0, 11)) {
    case 0: return `${slash()}-R${amt()}`; case 1: return `${slash()} R${amt()}`; case 2: return `${slash()} ${amt()}`;
    case 3: return `${slash()}=${amt()}`; case 4: return `${slash()}-${amt()}`; case 5: return `${n()}-${amt()}`;
    case 6: return `${int(0, 12)}${pick(['PP', 'pp', 'TO', 'BO', 'BK'])} ${amt()}`; case 7: return `${pick(['Apu', 'nyiko', 'POWER', 'Natkat'])} ${amt()}`;
    case 8: return pick(['abc', '12/', '/12 100', '12-', 'R100', '12.5 100']); default: return `${n()} ${amt()}`;
  }
}
const inputs = [...fixed, ...Array.from({ length: 400 }, () => Array.from({ length: int(1, 3) }, line).join(pick(['\n', ',', ';'])))];
const parse = inputs.map((input) => ({ input, ...plain(run(`parseFormat(${JSON.stringify(input)})`)) }));
const blockedIn = ['12,34,56', '5 05 5', '100, 7;9/ 03', 'x,12', '', '00 99 98 1'];
const blocked = blockedIn.map((input) => ({ input, result: plain(run(`parseBlockedNumbers(${JSON.stringify(input)})`)) }));

// ---- ledger scenarios
const scenarios = [];
for (let iter = 0; iter < 80; iter++) {
  const users: LUser[] = Array.from({ length: int(1, 3) }, (_, i) => ({
    id: 'u' + (i + 1), name: 'U' + (i + 1), username: 'user' + (i + 1),
    commissionPercent: pick([0, 5, 7.5, 10, 12.5, 15, 20, 33.33]), odd: pick([70, 75, 80, 85, 90, 82.5]), payment: pick([null, null, 0, 1000, 25000])
  }));
  const dates = ['2026-11-18', '2026-11-19'];
  const entries: LEntry[] = Array.from({ length: int(0, 7) }, (_, i) => ({
    id: 'e' + i, userId: pick(users).id, date: pick(dates),
    lines: Array.from({ length: int(1, 6) }, () => ({ num: String(int(0, 99)).padStart(2, '0'), amount: pick([100, 300, 500, 1000, 2500, 777, 12000]) }))
  }));
  const draws: LDraw[] = [];
  for (const d of dates) for (const sess of ['morning', 'evening'] as const) if (rand() < 0.6) draws.push({ date: d, session: sess, number: String(int(0, 99)).padStart(2, '0') });
  run(`db.users=${JSON.stringify(users)};db.entries=${JSON.stringify(entries.map((e) => ({ ...e, voucher: e.id, created: '2026-11-18T00:00:00.000Z' })))};db.drawResults=${JSON.stringify(draws.map((d) => ({ ...d, enteredAt: 'x' })))};db.coverVouchers=[];db.finalizedRecords=[];db.blockedNumbers=[]`);

  // Cover vouchers use the owner's v0.6.1 rule (fixed eat per number, vouchers list only changes), computed with
  // logic.ts (verified by cover.test.ts). Stakes are added between vouchers so later vouchers have changes to list.
  const covers: LCover[] = [];
  const coverOps: any[] = [];
  const coverEntries: LEntry[] = entries.slice(0, Math.ceil(entries.length / 2));
  const later = entries.slice(coverEntries.length);
  let seq = 0;
  let eat = pick([100, 250, 500, 1000, 3000]);
  for (let k = 0, cnt = int(0, 3); k < cnt; k++) {
    if (later.length) coverEntries.push(later.shift()!);
    const requested = covers.length ? eat : (eat = pick([100, 250, 500, 1000, 3000]));
    const v = makeCoverVoucher(buildCoverPlan(numberBalances(coverEntries, covers), requested));
    if (v) {
      coverOps.push({ kind: 'create', entryCount: coverEntries.length, requested, allocations: v.allocations, remainingLines: v.remainingLines, remainingTotal: v.remainingTotal });
      covers.push({ id: 'c' + (seq + 1), seq: ++seq, requestedAmount: requested, allocations: v.allocations, remainingLines: v.remainingLines });
      if (rand() < 0.3) {
        const idx = int(0, covers.length - 1);
        covers.splice(idx, 1);
        coverOps.push({ kind: 'delete', index: idx });
      }
    } else coverOps.push({ kind: 'refused', entryCount: coverEntries.length, requested });
  }
  while (later.length) coverEntries.push(later.shift()!);
  const htmlNoCoverBalances = plain(run('numberBalances()')); // HTML, all entries, no cover vouchers
  const balances = numberBalances(entries, covers);

  const summary = numbersSummary(users, entries, covers, draws);
  const latest = sortDraws(draws)[0];
  let finalize = null;
  if (latest) {
    run(`confirmFinalize(${JSON.stringify(latest.date)},${JSON.stringify(latest.session)})`);
    finalize = {
      date: latest.date, session: latest.session, number: latest.number,
      // v0.6.6: users with no stake get no history row (the HTML still writes one).
      records: plain(run('db.finalizedRecords')).filter((r: any) => r.total !== 0).map((r: any) => ({ userId: r.userId, total: r.total, winAmount: r.winAmount, odd: r.odd, payout: r.payout, commission: r.commission, payment: r.payment, net: r.net }))
    };
  }
  scenarios.push({
    users, entries, draws, coverOps, balances, balancesNoCover: htmlNoCoverBalances,
    summary: { activeCount: summary.activeCount, winning: summary.winning, totalGross: summary.totalGross, totalEaten: summary.totalEaten, totalCover: summary.totalCover, winGross: summary.winGross, avgOdd: summary.avgOdd, avgWinnerCommission: summary.avgWinnerCommission, yourEaten: summary.yourEaten, otherDealerCover: summary.otherDealerCover },
    latestDraw: latest ?? null, finalize
  });
}
writeFileSync(outPath, JSON.stringify({ parse, blocked, scenarios }, null, 1));
console.log(`wrote ${outPath}: ${parse.length} parse cases, ${scenarios.length} scenarios`);
