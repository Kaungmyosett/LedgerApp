// Pure ledger rules, ported 1:1 from ledger_v30/v31.html. No database, no I/O.
// The same operations in the same order are used on purpose so floating-point results match the HTML.
// backend/test/logic.diff.test.ts compares this file against the HTML on thousands of random cases.

export interface Line { num: string; amount: number }
export interface LUser { id: string; name: string; username: string; commissionPercent: number; odd: number; payment: number | null }
export interface LEntry { id: string; userId: string; date: string; lines: Line[] }
export interface LDraw { date: string; session: 'morning' | 'evening'; number: string }
export interface LCover { id: string; seq: number; requestedAmount: number; allocations: Line[]; remainingLines: Line[] }

/** Round to 2 decimals, half away from zero (same in Dart and PostgreSQL). */
export function round2(x: number): number {
  const s = x < 0 ? -1 : 1;
  return (s * Math.round(Math.abs(x) * 100)) / 100;
}

export const pad2 = (n: string | number): string => String(n ?? '').trim().padStart(2, '0');

// ---------------------------------------------------------------- Format parser
const BROTHER: Record<number, number[]> = {
  0: [0, 19, 28, 37, 46, 55, 64, 73, 82, 91], 1: [1, 10, 29, 38, 47, 56, 65, 74, 83, 92],
  2: [2, 11, 20, 39, 48, 57, 66, 75, 84, 93], 3: [3, 12, 21, 30, 49, 58, 67, 76, 85, 94],
  4: [4, 13, 22, 31, 40, 59, 68, 77, 86, 95], 5: [5, 14, 23, 32, 41, 50, 69, 78, 87, 96],
  6: [6, 15, 24, 33, 42, 51, 60, 79, 88, 97], 7: [7, 16, 25, 34, 43, 52, 61, 70, 89, 98],
  8: [8, 17, 26, 35, 44, 53, 62, 71, 80, 99], 9: [9, 18, 27, 36, 45, 54, 63, 72, 81, 90]
};
const SPECIAL: Record<string, number[]> = {
  apu: [0, 11, 22, 33, 44, 55, 66, 77, 88, 99],
  nyiko: [12, 21, 23, 32, 34, 43, 45, 54, 56, 65, 67, 76, 78, 87, 89, 98, 90, 9, 1, 10],
  power: [5, 16, 27, 38, 49, 50, 61, 72, 83, 94],
  natkat: [7, 18, 24, 35, 69, 70, 81, 42, 53, 96]
};

// v0.6.7: Myanmar words accepted in the Format box (owner's list). Tall-aa (U+102B) is treated like aa (U+102C).
const MY_WORDS: [RegExp, string][] = [
  [/\u1001\u103d\u1031\u1015\u1030\u1038/g, 'KHWEPU'], // ခွေပူး (before ခွေ)
  [/\u1001\u103d\u1031/g, 'KHWE'],                 // ခွေ
  [/\u100a\u102e\u1000\u102d\u102f/g, 'Nyiko'],     // ညီကို
  [/\u1015\u102c\u101d\u102c/g, 'Power'],          // ပါဝါ
  [/\u1014\u1000\u1039\u1001\u1010\u103a/g, 'Natkat'], // နက္ခတ်
  [/\u1021\u1015\u1030\u1038/g, 'Apu'],             // အပူး
  [/\u1015\u102c\u1010\u103a/g, 'PP'],              // ပါတ်
  [/\u1011\u102d\u1015\u103a/g, 'TO'],              // ထိပ်
  [/\u1015\u102d\u1010\u103a/g, 'BO']               // ပိတ်
];
export function normalizeFormatLine(line: string): string {
  let s = line.replace(/\u102b/g, '\u102c');
  for (const [re, en] of MY_WORDS) s = s.replace(re, ' ' + en + ' ');
  return s.replace(/\s+/g, ' ').trim();
}

export function parseFormat(raw: string): { result: Line[]; errors: string[] } {
  const bets: Line[] = [];
  const errors: string[] = [];
  const add = (num: number, amount: number) => {
    if (Number.isInteger(num) && num >= 0 && num <= 99 && Number.isFinite(amount) && amount > 0) {
      bets.push({ num: String(num).padStart(2, '0'), amount });
    }
  };
  const lines = String(raw || '').replace(/\r/g, '\n').split(/[\n,;]+/).map((x) => x.trim()).filter(Boolean);
  for (const original of lines) {
    const line = normalizeFormatLine(original);
    const bad = (msg: string) => errors.push(msg + original);
    let m: RegExpMatchArray | null;
    let amount: number;
    let nums: string[];
    // v0.6.7: "Apu-1000", "Apu=1000" and "Apu1000" mean the same as "Apu 1000".
    if ((m = line.match(/^(Apu|Nyiko|Power|Natkat)\s*[-=]?\s*(\d+)$/i))) {
      SPECIAL[m[1]!.toLowerCase()]!.forEach((n) => add(n, Number(m![2])));
      continue;
    }
    // v0.6.8 ခွေ: "012ခွေ1000" = every pair of two different digits (01/02/10/12/20/21);
    // ခွေပူး adds the doubles too (00/11/22). "-" or "=" before the amount is optional.
    if ((m = line.match(/^(\d{2,20})\s*(KHWEPU|KHWE)\s*[-=]?\s*(\d+)$/i))) {
      const digits = [...new Set(m[1]!.split('').map(Number))];
      amount = Number(m[3]);
      if (digits.length < 2) { bad('ခွေ တွင် မတူသော digit ၂ လုံးနှင့်အထက် လိုသည်: '); continue; }
      for (const a of digits) for (const b of digits) if (a !== b) add(a * 10 + b, amount);
      if (m[2]!.toUpperCase() === 'KHWEPU') for (const a of digits) add(a * 11, amount);
      continue;
    }
    if ((m = line.match(/^(\d{1,2})\s*(PP|TO|BO|BK)\s*[-=]?\s*(\d+)$/i))) {
      const digit = Number(m[1]);
      const kind = m[2]!.toUpperCase();
      amount = Number(m[3]);
      if (digit > 9) { bad('PP / TO / BO / BR တွင် 0 မှ 9 အထိ digit သာသုံးပါ: '); continue; }
      if (kind === 'PP') { for (let i = 0; i < 10; i++) { add(digit * 10 + i, amount); if (i !== digit) add(i * 10 + digit, amount); } } // 1PP: 11 once
      else if (kind === 'TO') { for (let i = 0; i < 10; i++) add(digit * 10 + i, amount); }
      else if (kind === 'BO') { for (let i = 0; i < 10; i++) add(i * 10 + digit, amount); }
      else BROTHER[digit]!.forEach((n) => add(n, amount));
      continue;
    }
    if ((m = line.match(/^([\d/]+)\s*-\s*(\d+)$/))) {
      amount = Number(m[2]); nums = m[1]!.split('/');
      if (nums.some((n) => !/^[0-9]{1,2}$/.test(n) || Number(n) > 99) || amount <= 0) { bad('ဂဏန်း သို့မဟုတ် ငွေပမာဏ မမှန်ပါ: '); continue; }
      nums.forEach((n) => add(Number(n), amount)); continue;
    }
    if ((m = line.match(/^(\d{1,2})\s*-\s*(\d+)$/))) {
      const num = Number(m[1]); const amt = Number(m[2]);
      if (num <= 99 && amt > 0) add(num, amt); else bad('ဂဏန်း သို့မဟုတ် ငွေပမာဏ မမှန်ပါ: ');
      continue;
    }
    if ((m = line.match(/^([\d/]+)\s*[-=]?\s*R\s*[-=]?\s*(\d+)$/i))) {
      amount = Number(m[2]); nums = m[1]!.split('/');
      if (nums.some((n) => !/^\d{1,2}$/.test(n) || Number(n) > 99)) { bad('ဂဏန်း format မမှန်ပါ: '); continue; }
      nums.forEach((n) => { const v = Number(n); const r = Number(String(v).padStart(2, '0').split('').reverse().join('')); add(v, amount); if (r !== v) add(r, amount); }); // 00 R: 00 once
      continue;
    }
    if ((m = line.match(/^([\d/]+)\s+(\d+)$/))) {
      amount = Number(m[2]); nums = m[1]!.split('/');
      if (nums.some((n) => !/^\d{1,2}$/.test(n) || Number(n) > 99)) { bad('ဂဏန်း format မမှန်ပါ: '); continue; }
      nums.forEach((n) => add(Number(n), amount)); continue;
    }
    if ((m = line.match(/^([\d/]+)\s*=\s*(\d+)$/))) {
      amount = Number(m[2]); nums = m[1]!.split('/');
      if (nums.some((n) => !/^\d{1,2}$/.test(n) || Number(n) > 99)) { bad('ဂဏန်း format မမှန်ပါ: '); continue; }
      nums.forEach((n) => add(Number(n), amount)); continue;
    }
    bad('Format မမှန်ပါ: ');
  }
  const merged = new Map<string, number>();
  bets.forEach((x) => merged.set(x.num, (merged.get(x.num) || 0) + x.amount));
  return { result: [...merged].map(([num, amount]) => ({ num, amount })), errors };
}

export function parseBlockedNumbers(raw: string): string[] {
  const out = new Set<string>();
  String(raw || '').split(/[\s,;/]+/).filter(Boolean).forEach((x) => {
    if (/^\d{1,2}$/.test(x) && Number(x) <= 99) out.add(x.padStart(2, '0'));
  });
  return [...out].sort((a, b) => Number(a) - Number(b));
}

// ---------------------------------------------------------------- Numbers / cover
// Cover rule (v0.6.1, replaces the HTML's rule at the owner's request):
//  * The first cover voucher of a period fixes "eat per number" (E). Later vouchers must use the same E,
//    until every active cover voucher is deleted or the period is finalized.
//  * For each number: stake g, already eaten Ep, already covered Cp (sums over the active vouchers).
//      eat now   = max(0, min(g, E) - Ep)
//      cover now = max(0, max(0, g - E) - Cp)
//    so a new voucher lists only what changed since the previous vouchers.
//  * A voucher with nothing to cover is refused ("ကာငွေမရှိပါ").
export interface Balance { gross: number; covered: number; cover: number; remaining: number }

/** covered = eaten so far, cover = sent to other dealers so far, remaining = not handled yet. */
export function numberBalances(entries: { lines: Line[] }[], covers: LCover[]): Record<string, Balance> {
  const gross: Record<string, number> = {}; const eaten: Record<string, number> = {}; const cover: Record<string, number> = {};
  const addTo = (m: Record<string, number>, x: Line) => {
    const n = pad2(x.num); if (/^\d{2}$/.test(n)) m[n] = (m[n] || 0) + Math.max(0, Number(x.amount) || 0);
  };
  entries.forEach((e) => (e.lines || []).forEach((x) => addTo(gross, x)));
  covers.forEach((v) => {
    (v.allocations || []).forEach((x) => addTo(eaten, x));
    (v.remainingLines || []).forEach((x) => addTo(cover, x));
  });
  const out: Record<string, Balance> = {};
  for (let i = 0; i < 100; i++) {
    const n = String(i).padStart(2, '0'); const g = gross[n] || 0; const e = eaten[n] || 0; const c = cover[n] || 0;
    out[n] = { gross: g, covered: e, cover: c, remaining: Math.max(0, g - e - c) };
  }
  return out;
}

/** The fixed eat-per-number of the current period, or null when there is no active cover voucher. */
export function lockedEat(covers: LCover[]): number | null {
  if (!covers.length) return null;
  return [...covers].sort((a, b) => a.seq - b.seq)[0]!.requestedAmount;
}

export interface CoverPlan { eatPerNumber: number; eat: Line[]; cover: Line[]; eatTotal: number; coverTotal: number }

export function buildCoverPlan(balances: Record<string, Balance>, eatPerNumber: number): CoverPlan {
  const eat: Line[] = []; const cover: Line[] = [];
  for (let i = 0; i < 100; i++) {
    const num = String(i).padStart(2, '0');
    const b = balances[num]!;
    if (b.gross <= 0) continue;
    const e = Math.max(0, Math.min(b.gross, eatPerNumber) - b.covered);
    const c = Math.max(0, Math.max(0, b.gross - eatPerNumber) - b.cover);
    if (e > 0) eat.push({ num, amount: e });
    if (c > 0) cover.push({ num, amount: c });
  }
  const sum = (l: Line[]) => l.reduce((a, x) => a + x.amount, 0);
  return { eatPerNumber, eat, cover, eatTotal: sum(eat), coverTotal: sum(cover) };
}

/** Saved voucher content: allocations = eaten now, remainingLines = the cover list. Null when nothing to cover. */
export function makeCoverVoucher(plan: CoverPlan): { allocations: Line[]; remainingLines: Line[]; remainingTotal: number } | null {
  if (plan.coverTotal <= 0) return null;
  return { allocations: plan.eat, remainingLines: plan.cover, remainingTotal: plan.coverTotal };
}

// ---------------------------------------------------------------- Settlement
export interface Settlement { total: number; winAmount: number; odd: number; payout: number; commissionPercent: number; commission: number; payment: number; net: number }

export function settleUser(user: Pick<LUser, 'commissionPercent' | 'odd' | 'payment'>, lines: Line[], winning: string): Settlement {
  const total = lines.reduce((a, x) => a + Number(x.amount || 0), 0);
  const winAmount = winning ? lines.filter((x) => pad2(x.num) === winning).reduce((a, x) => a + Number(x.amount || 0), 0) : 0;
  const odd = Number(user.odd ?? 80);
  const payout = winAmount * odd;
  const commission = (total * Number(user.commissionPercent || 0)) / 100;
  const payment = Number(user.payment || 0);
  const net = total - payout - commission - payment;
  return { total, winAmount, odd, payout, commissionPercent: Number(user.commissionPercent || 0), commission, payment, net };
}

// ---------------------------------------------------------------- Draws
export const drawNum = (x: { number: string }): string => String(x.number || '');

/** Latest first: newest date, and on the same date evening before morning. */
export function sortDraws<T extends LDraw>(draws: T[]): T[] {
  return [...draws].filter((x) => drawNum(x)).sort((a, b) =>
    (b.date < a.date ? -1 : b.date > a.date ? 1 : 0) ||
    ((b.session === 'evening' ? 1 : 0) - (a.session === 'evening' ? 1 : 0)));
}

// ---------------------------------------------------------------- Numbers page summary
export interface NumbersSummary {
  balances: Record<string, Balance>;
  totalGross: number; totalEaten: number; totalCover: number; activeCount: number;
  winning: string; winGross: number; avgOdd: number; avgWinnerCommission: number;
  yourEaten: number; otherDealerCover: number;
}

export function numbersSummary(users: LUser[], entries: LEntry[], covers: LCover[], draws: LDraw[]): NumbersSummary {
  const balances = numberBalances(entries, covers);
  const latest = sortDraws(draws)[0];
  const winning = latest ? drawNum(latest).padStart(2, '0') : '';
  let totalGross = 0; let totalEaten = 0; let totalCover = 0;
  Object.values(balances).forEach((x) => { totalGross += x.gross; totalEaten += x.covered; totalCover += x.cover; });
  const activeCount = Object.values(balances).filter((x) => x.gross > 0).length;
  const winBalance = winning ? balances[winning]! : { gross: 0, covered: 0, cover: 0, remaining: 0 };
  const winUsers: { stake: number; odd: number; commission: number }[] = [];
  if (winning) {
    users.forEach((u) => {
      const stake = entries.filter((e) => e.userId === u.id).flatMap((e) => e.lines || [])
        .filter((x) => pad2(x.num) === winning).reduce((sum, x) => sum + Math.max(0, Number(x.amount) || 0), 0);
      if (stake > 0) winUsers.push({ stake, odd: Number(u.odd ?? 80), commission: Number(u.commissionPercent || 0) });
    });
  }
  const winUserStake = winUsers.reduce((a, x) => a + x.stake, 0);
  const avgOdd = winUserStake ? winUsers.reduce((a, x) => a + x.stake * x.odd, 0) / winUserStake : 0;
  const avgWinnerCommission = winUsers.length ? winUsers.reduce((a, x) => a + x.commission, 0) / winUsers.length : 0;
  const otherDealerCover = totalCover - (totalCover * 0.13) - (avgOdd * winBalance.cover);
  // v0.6.6 (owner's rule): with nothing covered to other dealers, you eat the whole stake,
  // so "your eaten" is computed from the total stake (and the full stake on the winning number).
  // Computed per commission user: total stake - (their stake x their commission %) - (their winning stake x their odd).
  let yourEaten: number;
  if (totalCover === 0) {
    let commission = 0; let payout = 0;
    users.forEach((u) => {
      const lines = entries.filter((e) => e.userId === u.id).flatMap((e) => e.lines || []);
      const stake = lines.reduce((a, x) => a + Math.max(0, Number(x.amount) || 0), 0);
      const win = winning ? lines.filter((x) => pad2(x.num) === winning).reduce((a, x) => a + Math.max(0, Number(x.amount) || 0), 0) : 0;
      commission += stake * Number(u.commissionPercent || 0) / 100;
      payout += win * Number(u.odd ?? 80);
    });
    yourEaten = totalGross - commission - payout;
  } else {
    yourEaten = totalEaten - (avgWinnerCommission / 100 * totalEaten) - (avgOdd * winBalance.covered);
  }
  return { balances, totalGross, totalEaten, totalCover, activeCount, winning, winGross: winBalance.gross, avgOdd, avgWinnerCommission, yourEaten, otherDealerCover };
}
