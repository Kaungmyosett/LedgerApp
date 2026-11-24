// Cover rule v0.6.1 (owner's rule): fixed eat-per-number per period; each voucher lists only what changed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildCoverPlan, lockedEat, makeCoverVoucher, numberBalances, numbersSummary, parseFormat } from '../src/ledger/logic.js';
import type { LCover, LEntry, LUser, Line } from '../src/ledger/logic.js';

const entry = (id: string, lines: Line[]): LEntry => ({ id, userId: 'u', date: '2026-11-20', lines });
function save(entries: LEntry[], covers: LCover[], eat: number) {
  const made = makeCoverVoucher(buildCoverPlan(numberBalances(entries, covers), eat));
  if (made) covers.push({ id: 'c' + (covers.length + 1), seq: covers.length + 1, requestedAmount: eat, allocations: made.allocations, remainingLines: made.remainingLines });
  return made;
}

test("owner's example: 05=5,000 eat 1,000; then 05 +2,000 and 12=3,000", () => {
  const entries = [entry('e1', [{ num: '05', amount: 5000 }])];
  const covers: LCover[] = [];
  const v1 = save(entries, covers, 1000)!;
  assert.deepEqual(v1.allocations, [{ num: '05', amount: 1000 }]);
  assert.deepEqual(v1.remainingLines, [{ num: '05', amount: 4000 }]);
  assert.equal(lockedEat(covers), 1000);

  entries.push(entry('e2', [{ num: '05', amount: 2000 }, { num: '12', amount: 3000 }]));
  const v2 = save(entries, covers, 1000)!;
  assert.deepEqual(v2.allocations, [{ num: '12', amount: 1000 }], '05 was already eaten, 12 is new');
  assert.deepEqual(v2.remainingLines, [{ num: '05', amount: 2000 }, { num: '12', amount: 2000 }]);
  assert.equal(v2.remainingTotal, 4000);

  const b = numberBalances(entries, covers);
  assert.deepEqual(b['05'], { gross: 7000, covered: 1000, cover: 6000, remaining: 0 });
  assert.deepEqual(b['12'], { gross: 3000, covered: 1000, cover: 2000, remaining: 0 });
  const s = numbersSummary([], entries, covers, []);
  assert.equal(s.totalEaten, 2000);
  assert.equal(s.totalCover, 8000);
});

test('nothing new to cover is refused; small new stakes are eaten by the next voucher', () => {
  const entries = [entry('e1', [{ num: '05', amount: 5000 }])];
  const covers: LCover[] = [];
  save(entries, covers, 1000);
  assert.equal(save(entries, covers, 1000), null, 'no change -> ကာငွေမရှိပါ');
  entries.push(entry('e2', [{ num: '33', amount: 500 }]));
  assert.equal(save(entries, covers, 1000), null, 'only eating, nothing to cover');
  entries.push(entry('e3', [{ num: '33', amount: 900 }]));
  const v = save(entries, covers, 1000)!;
  assert.deepEqual(v.allocations, [{ num: '33', amount: 1000 }]);
  assert.deepEqual(v.remainingLines, [{ num: '33', amount: 400 }]);
});

test('deleting a voucher puts its numbers back for the next one; lock clears when none are left', () => {
  const entries = [entry('e1', [{ num: '05', amount: 5000 }, { num: '07', amount: 300 }])];
  const covers: LCover[] = [];
  save(entries, covers, 1000);
  covers.splice(0, 1);
  assert.equal(lockedEat(covers), null);
  const v = save(entries, covers, 2000)!;
  assert.deepEqual(v.allocations, [{ num: '05', amount: 2000 }, { num: '07', amount: 300 }]);
  assert.deepEqual(v.remainingLines, [{ num: '05', amount: 3000 }]);
});

test('random ledgers: after a voucher every number is fully split into eaten (<= eat) + covered', () => {
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  for (let iter = 0; iter < 2000; iter++) {
    const eat = [100, 500, 1000, 3000][Math.floor(rnd() * 4)]!;
    const entries: LEntry[] = [];
    const covers: LCover[] = [];
    for (let round = 0; round < 4; round++) {
      for (let k = 0, n = 1 + Math.floor(rnd() * 5); k < n; k++) {
        entries.push(entry(`e${iter}-${round}-${k}`, [{ num: String(Math.floor(rnd() * 100)).padStart(2, '0'), amount: [100, 500, 777, 2500][Math.floor(rnd() * 4)]! }]));
      }
      const made = save(entries, covers, eat);
      const bal = numberBalances(entries, covers);
      for (const [n, b] of Object.entries(bal)) {
        assert.ok(b.covered <= Math.min(b.gross, eat) + 1e-9, `eaten above limit ${n}`);
        if (made) {
          assert.equal(b.remaining, 0, `iter ${iter} ${n} left unhandled`);
          assert.equal(b.covered, Math.min(b.gross, eat));
          assert.equal(b.cover, Math.max(0, b.gross - eat));
        }
      }
      for (const v of covers) for (const l of [...v.allocations, ...v.remainingLines]) assert.ok(l.amount > 0);
    }
  }
});

test('your eaten: no cover -> computed from the total stake; with cover -> from what was eaten', () => {
  const users: LUser[] = [{ id: 'u', name: 'U', username: 'U', commissionPercent: 10, odd: 80, payment: null }];
  const entries = [entry('e1', [{ num: '05', amount: 1000 }, { num: '12', amount: 4000 }])];
  const draws = [{ date: '2026-11-20', session: 'evening' as const, number: '05' }];
  // No cover voucher: total 5,000 - 10% commission - 80 x 1,000 on the winning number.
  let s = numbersSummary(users, entries, [], draws);
  assert.equal(s.otherDealerCover, 0);
  assert.equal(s.yourEaten, 5000 - 500 - 80000);
  // With a cover voucher (eat 500 per number): eaten 1,000 (05=500, 12=500), cover 05=500, 12=3,500.
  const covers: LCover[] = [];
  save(entries, covers, 500);
  s = numbersSummary(users, entries, covers, draws);
  assert.equal(s.totalEaten, 1000);
  assert.equal(s.yourEaten, 1000 - 100 - 80 * 500);
  assert.equal(s.otherDealerCover, 4000 - 4000 * 0.13 - 80 * 500);
});

test("your eaten without cover: each user's own commission and odd; winning number nobody bet", () => {
  const users: LUser[] = [
    { id: 'a', name: 'A', username: 'A', commissionPercent: 10, odd: 80, payment: null },
    { id: 'b', name: 'B', username: 'B', commissionPercent: 5, odd: 85, payment: 300 }
  ];
  const entries: LEntry[] = [
    { id: 'e1', userId: 'a', date: '2026-11-20', lines: [{ num: '05', amount: 1000 }, { num: '12', amount: 2000 }] },
    { id: 'e2', userId: 'b', date: '2026-11-20', lines: [{ num: '05', amount: 500 }, { num: '40', amount: 4000 }] }
  ];
  // Winning 33: nobody bet it -> only commissions: 7,500 - 300 - 225 = 6,975 (not the plain total 7,500).
  let s = numbersSummary(users, entries, [], [{ date: '2026-11-20', session: 'evening', number: '33' }]);
  assert.equal(s.yourEaten, 7500 - 300 - 225);
  // Winning 05: payouts 1,000 x 80 + 500 x 85.
  s = numbersSummary(users, entries, [], [{ date: '2026-11-20', session: 'evening', number: '05' }]);
  assert.equal(s.yourEaten, 7500 - 300 - 225 - 80000 - 42500);
});

test('Format: "Apu-1000" and Myanmar words (v0.6.7)', () => {
  const same = (a: string, b: string) => assert.deepEqual(parseFormat(a), { ...parseFormat(b), errors: parseFormat(b).errors }, `${a} vs ${b}`);
  for (const sep of ['-', '=', '', ' - ']) same(`Apu${sep}1000`, 'Apu 1000');
  same('power-500', 'Power 500');
  same('အပူး 1000', 'Apu 1000');
  same('အပူး-1000', 'Apu 1000');
  same('3ပါတ်200', '3PP200');
  same('3 ပါတ် 200', '3PP200');
  same('5ထိပ်100', '5TO100');
  same('5ပိတ်100', '5BO100');
  same('ပါဝါ 300', 'Power 300');
  same('နက္ခတ်-300', 'Natkat 300');
  same('3ပာတ်200', '3PP200'); // ပါတ် typed with the short aa
  // a bad line keeps the user's own text in the message
  assert.deepEqual(parseFormat('ပါတ် 200').errors, ['Format မမှန်ပါ: ပါတ် 200']);
  // "=" like "-" (owner's screenshot)
  same('1ပါတ်=100', '1PP100');
  same('1ထိပ်=100', '1TO100');
  same('1ပိတ်=100', '1BO100');
  same('8Bk=500', '8BK500');
  same('17=R2500', '17R2500');
  same('25/70/50/73=R15000', '25/70/50/73R15000');
  same('17R=2500', '17R2500');
  same('apu=500', 'Apu 500');
  assert.equal(parseFormat('17=R2500\n8Bk=500\n1ပါတ်=100').errors.length, 0);
  // v0.6.8: ညီကို, ခွေ, ခွေပူး
  same('ညီကို 1000', 'Nyiko 1000');
  same('ညီကို=1000', 'Nyiko 1000');
  for (const sep of ['', '-', '=', ' - ']) {
    same(`012ခွေ${sep}1000`, '01/02/10/12/20/21=1000');
    same(`012ခွေပူး${sep}1000`, '01/02/10/12/20/21/00/11/22=1000');
  }
  same('0112ခွေ500', '01/02/10/12/20/21=500'); // repeated digit counted once
  // any of 0-9: all ten digits -> 90 numbers (ခွေ), 100 numbers (ခွေပူး)
  assert.equal(parseFormat('0123456789ခွေ100').result.length, 90);
  assert.equal(parseFormat('0123456789ခွေပူး=100').result.length, 100);
  assert.equal(parseFormat('01234567890123ခွေ100').result.length, 90);
  assert.equal(parseFormat('1ခွေ1000').errors.length, 1);
  assert.equal(parseFormat('13579ခွေ-100').result.length, 20);
  assert.equal(parseFormat('11ခွေ1000').errors.length, 1);
});

test('Format: a double (00, 11, …) is never charged twice', () => {
  const amt = (raw: string) => Object.fromEntries(parseFormat(raw).result.map((l) => [l.num, l.amount]));
  // R on a double: the reverse is the same number, so it counts once
  assert.deepEqual(amt('00/11 R1000'), { '00': 1000, '11': 1000 });
  assert.deepEqual(amt('00/11-R1000'), amt('00/11-1000'));
  assert.deepEqual(amt('12/00 R1000'), { '12': 1000, '21': 1000, '00': 1000 });
  // PP: 19 numbers, the double once
  const pp = amt('1PP 1000');
  assert.equal(Object.keys(pp).length, 19);
  assert.equal(pp['11'], 1000);
  assert.equal(amt('0PP 500')['00'], 500);
  // writing the same number twice on purpose still adds up
  assert.deepEqual(amt('11-1000\n11-1000'), { '11': 2000 });
});
