# Migration and calculation regression plan

## Existing HTML source observations
The supplied HTML is a browser-only demo:
- It stores its database in `localStorage` under `ledgerCommissionFormatV2`.
- It has Commission Users, vouchers/entries, blocked numbers, cover vouchers, draw results and finalized history.
- It uses 2D number strings padded to two characters.
- A client/user has `commissionPercent`, `odd` and optional `payment`.
- The number summary distinguishes gross stake, covered/eaten amount and remaining cover from the latest cover voucher.
- Per-client settlement currently computes:
  `net = total stake - (winning stake × Odd) - commission - payment`.
- Finalization snapshots settlement rows, resets each user's payment and removes entries for the finalized date from the active entry list.

These semantics must be regression-tested before changing implementation. Do not assume the current finalization behavior is ideal; preserve it initially, then obtain explicit approval for any behavior change.

## Required regression fixtures
Create fixtures from the original HTML and record expected outputs for:
1. Input parser: manual and formatted entry modes.
2. Number normalization: `7` becomes `07`; `00` remains `00`; reject values outside `00`–`99`.
3. Blocked number rejection.
4. Per-client total stake.
5. Winning stake and payout (`winning stake × client Odd`).
6. Commission (`total stake × commission percent / 100`).
7. Net amount (`total - payout - commission - payment`).
8. Cover voucher allocation, eaten and remaining amounts.
9. Number dashboard gross/eaten/cover totals.
10. Finalization duplicate prevention, immutable history snapshot, and active-entry behavior.

## Migration safeguards
- Export and back up the existing browser data before migration.
- Preserve original voucher IDs and timestamps where possible.
- Do not import demo users as real authenticated accounts without Admin review.
- Validate totals before and after import.
- Keep a read-only copy of the original HTML and a signed-off export.
- Test restore from backup before production launch.
