# Ledger specification (extracted from `ledger_v30.html`)

This is what the existing HTML does today. The server and the app must reproduce it exactly.
Items marked **DECISION** are places where the HTML cannot be copied literally.

## 1. Structure
```
Admin (1)  ──creates──▶  Client (dealer account, logs in with a code)
                              └── owns one private ledger:
                                    Commission Users  (name, username, commission %, odd, payment)
                                    Vouchers (entries) per commission user, each with lines  number 00–99 = amount
                                    Blocked numbers (one list for the whole ledger)
                                    Draw results (one per date)
                                    Cover vouchers
                                    Finalized records (history)
```
Commission %, odd and payment belong to **commission users inside a client's ledger**, not to the client account.
A client sees only their own ledger. The Admin manages client accounts, not ledger contents.

## 2. Numbers and money
- Numbers are always 2 characters `00`–`99` (leading zero kept).
- Stakes are whole kyat. Odd (default 80) and commission % (default 10) may have decimals.
- **DECISION:** the HTML never rounds (it prints up to 3 decimals). The server stores money as `NUMERIC` and the app computes with exact decimals; amounts are rounded half-up to 2 decimals only when a finalized record is saved.
- **DECISION (time zone):** the HTML uses the device's local date (`en-CA`). Dates for entries, draws and settlement are sent by the phone, never taken from the server's UTC clock, so a bet at 11 pm Myanmar time is not filed on the wrong day.

## 3. Entering bets
Two modes: **Format** (text, several lines) and **manual** (number + amount rows).
Format lines (split on newline, `,` or `;`), amounts are positive integers:

| Input | Meaning |
|---|---|
| `12/45-R1000` or `12/45 R1000` | 12, 21, 45, 54 (R adds the reverse). A double has no reverse: `00/11 R1000` = 00 and 11 at 1000 each (v0.7.4) |
| `12/45 1000`, `12/45=1000`, `11/22/33-1000` | exactly those numbers, no reverse |
| `00-5000` | number 00 gets 5000 |
| `51 R2000` | 51 and 15 · `51 2000` = 51 only |
| `1PP 1000` | all numbers containing digit 1 in either position (10–19 and 01,21,…91): 19 numbers, 11 counted once (v0.7.4) |
| `1TO 1000` | tens digit 1 (10–19) · `1BO 1000` ones digit 1 (01,11,…91) |
| `1BK 1000` | "brother" set for digit 1 (digits sum to 1 mod 10: 01,10,29,38,…) |
| `Apu`, `Nyiko`, `Power`, `Natkat` + amount | fixed number sets (listed in the HTML source) |

- Repeated numbers in one submission are merged by adding amounts.
- In both entry modes, blocked numbers and amounts are shown separately and excluded from the saved voucher. An all-blocked submission leaves the voucher unchanged (or creates no voucher). Every submitted blocked number and its amount appears in the blocked-number log under the submitting commission user's name.
- A saved voucher gets a code `V` + 8 digits and the selected date and draw session.
- **DECISION (offline):** the phone parses and previews on-device (so it works offline) and saves a draft with a provisional voucher code. The server rechecks the blocked list, keeps the allowed lines, and preserves or replaces the provisional code as needed.
- Editing a voucher replaces its lines (numbers 00–99, amount > 0, at least one allowed line; blocked numbers are rechecked on edit).
- **DECISION:** "delete voucher / commission user / cover voucher" become soft deletes with an audit record. A commission user with linked vouchers, retained history, or debt entries cannot be deleted.

## 4. Per-user settlement (စာရင်းတွက်မည် and Finalize)
For one commission user and one date/session, using that draw number:
```
total      = sum of all line amounts in that date and session
winAmount  = sum of lines whose number == drawn number
payout     = winAmount × odd
commission = total × commission% / 100
net        = total − payout − commission − payment
net >= 0  → the user owes the dealer net;   net < 0 → the dealer pays the user |net|
```
No draw number yet → show only total and payment.

## 5. Draw results (ထွက်ဂဏန်း)
- **Two draws per day: morning and evening.** One number per date **per session**; saving again for the same date + session overwrites it.
- The session defaults from the time (before 13:00 device time = morning, otherwise evening) but the user can choose it, so a late-entered morning result is filed correctly.
- **Deletable (new):** each saved draw has a delete button with a confirmation. On the server this is a soft delete that is written to the audit log with the old number; it disappears from the screens.
- "Latest draw" (used by the Numbers page) = latest date, and on the same date evening before morning.

## 6. Finalize (အပြီးစာရင်းချုပ်) — twice a day
Finalize is done **per draw (date + session)**. It uses the most recent draw that has not been finalized yet. Refused if there is no draw, or if every draw is already finalized.
For **every** commission user it writes a history record (formulas in section 4, `payment` included, plus the session), sets each user's `payment` back to empty, and moves that date and session's current vouchers out of the "all bets" list.
- Only the selected session's vouchers and cover vouchers are frozen. New vouchers store an explicit session. Existing open vouchers are assigned from their creation time using the Yangon 13:00 cutoff; previous finalizations remain frozen.
- **DECISION:** the HTML deletes the finalized vouchers. The server keeps them, marked finalized (hidden from the active lists, frozen, never deletable). The screen behaves the same.
- **History records can be deleted (new):** each history row has a delete button with a confirmation. The server does a soft delete recorded in the audit log (the numbers are kept in the audit entry); the record disappears from the history screen. Record values can never be edited, only deleted. Deleting a history record does not bring its vouchers back.

## 7. Numbers 00–99 page
Per number: `gross` (sum of all active vouchers), `eaten` (sum of allocations of all saved cover vouchers), `cover` (the **latest** cover voucher's remaining list only; zero when there is no cover voucher).
With a latest draw number `W`:
```
avgOdd             = stake-weighted average of odd over users who staked on W
avgWinnerCommission= plain average of commission% over those users
yourEaten          = totalEaten − avgWinnerCommission/100 × totalEaten − avgOdd × eaten[W]
otherDealerCover   = totalCover − totalCover × 0.13 − avgOdd × cover[W]
```
(`otherDealerCover > 0` → pay the other dealer; otherwise receive from them.) The **13% is fixed** (confirmed by the owner), not a setting.

**Active numbers (new):** the page shows how many of the 100 numbers are *active*, meaning their total stake (`gross`, the "စုစုပေါင်းတင်ငွေ" column) is not 0, as "Active ဂဏန်း N / 100". It counts numbers with `gross > 0` and is unaffected by eaten/cover amounts.

## 8. Cover (ကာဂဏန်းထုတ်ရန်)
Input: one whole-kyat amount `R`.
```
for each number with gross > 0:  take = min(R, remaining[number]);  allocate take
remaining[number] = (latest cover voucher exists) ? latest.remaining[number] : gross[number]
```
New remaining list = `remaining − take` for each number, keeping values > 0. Saving is refused when nothing is allocated or the new remaining total is 0. The saved voucher stores: id `C`+8 digits, requested amount, allocations (eaten), remaining lines, total, date. Deleting a cover voucher makes the previous one the "latest" again. The list can be copied as `12=500` lines plus `Total=…`.

## 9. Commission users and blocked numbers
- Fields: name, username (unique within the ledger), commission 0–100, odd ≥ 0, optional payment ≥ 0.
- Blocked numbers: one list per ledger, entered as comma/space separated `00`–`99`, applies to every commission user.

## 10. Decisions confirmed by the owner
1. One client = one phone only (a new login signs the old phone out).
2. Finalize happens twice a day, morning and evening.
3. The 13% is fixed.
4. Draw results and history records can be deleted (recorded as soft deletes in the audit log).
5. Clients are identified by email; the Admin gives them a one-time code.

## v0.6 implementation map

| Rule | Server | App |
|---|---|---|
| Format parser, blocked-number parser | `backend/src/ledger/logic.ts` | `mobile/lib/ledger/logic.dart` |
| Balances, cover plan/voucher, numbers summary (Active count) | same | same |
| Settlement, finalize (per date + session) | `logic.ts` + `ops.ts` | `logic.dart` + `ops.dart` (preview) |
| Operations / sync | `ops.ts`, `routes/ledger.ts` | `ops.dart`, `ledger_store.dart` |

Tests: `backend/test/logic.diff.test.ts` runs random cases through the real HTML and compares; `backend/test/make-fixtures.ts` writes `mobile/test/fixtures/ledger_golden.json`, which `mobile/test/ledger_logic_test.dart` checks the Dart port against; `backend/test/ledger.integration.test.ts` (`npm run test:db`, needs `TEST_DATABASE_URL`) exercises the SQL.

## Cover rule — changed in v0.6.1 (owner's decision; differs from ledger_v31.html)

* The input is **eat per number** (စားမည့်ပမာဏ). The first cover voucher fixes it; later vouchers must use the same amount (server error `EAT_LOCKED`). It can change again only when every active cover voucher is deleted or after a finalize (finalize closes the cover period).
* For each number with stake g, already eaten Ep and already covered Cp (all active vouchers):
  eat now = max(0, min(g, E) − Ep), cover now = max(0, max(0, g − E) − Cp). A voucher lists only these changes.
* Nothing to cover → refused (ကာငွေမရှိပါ). Small new stakes below E are eaten by the next voucher that is saved.
* Example: 05=5,000, E=1,000 → voucher 1: eat 05=1,000, cover 05=4,000. Then 05 +2,000 and 12=3,000 → voucher 2: eat 12=1,000, cover 05=2,000, 12=2,000.
* Numbers page: စားငွေ = sum of eaten over all active vouchers, ကာငွေ = sum of all cover lists (no longer only the latest voucher).
* Copy = the voucher's cover list as `NN=amount` lines + `Total=`.

## v0.6.6 changes (owner's decisions)

* Numbers page: "သင်၏စားငွေတွက်ပြီး" / "တခြားဒိုင်ကာငွေတွက်ပြီး". When nothing has been covered (total cover = 0, so other-dealer cover is 0),
  your eaten is computed from the total stake, per commission user: total stake − Σ(user stake × user commission%) − Σ(user stake on the winning number × user odd).
  (Payments are not deducted here.) With cover vouchers it uses the eaten amounts as before.
  Colours: your eaten + green / − red; other dealer cover + red (you pay) / − green.
* Finalize: commission users with total stake 0 on that date get no history row and keep their payment. If nobody has a stake the finalize is refused (`NOTHING_TO_FINALIZE`).
* Settlement dialog: total stake 0 → "တင်ငွေ မရှိသေးပါ"; the total is labelled "စုစုပေါင်း တင်ငွေ".

## v0.6.7 — Format box additions (owner's decisions; not in ledger_v31.html)

* `Apu-1000`, `Apu=1000`, `Apu1000` = `Apu 1000` (also Nyiko / Power / Natkat). `=` also works like `-` in `1PP=100`, `8BK=500`, `17=R2500`, `17R=2500`.
* Myanmar words: ပါတ် = PP, အပူး = Apu, ထိပ် = TO, ပိတ် = BO, ပါဝါ = Power, နက္ခတ် = Natkat (tall-aa ါ is accepted for ာ).
  e.g. `3ပါတ်200`, `အပူး-1000`, `5ထိပ်100`. Same code in logic.ts and logic.dart; error messages quote what was typed.
* Manual rows: column titles ဂဏန်း / အမျိုးအစား / ငွေ above the rows; type names shown in Myanmar (အာ, ပါတ်, ထိပ်, ပိတ်, ဘရိတ်, ပါဝါ, နက္ခတ်).

## v0.6.8 — ခွေ / ခွေပူး / ညီကို (owner's rules)

* `012ခွေ1000` (also `012ခွေ-1000`, `012ခွေ=1000`) = every pair of two different digits: 01/02/10/12/20/21 = 1000.
* `012ခွေပူး1000` = the same plus the doubles: 01/02/10/12/20/21/00/11/22 = 1000.
* Any of the digits 0–9 (up to 20 typed); a repeated digit counts once (all ten digits = 90 numbers, or 100 with ခွေပူး); fewer than 2 different digits is an error.
* `ညီကို` = Nyiko. All of these are also types in the manual rows (ခွေ / ခွေပူး take the digits in the number box, ညီကို needs no number).
