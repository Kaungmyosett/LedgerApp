# Reference HTML ledger
- `ledger_v30_original.html` — the original file you gave me (unchanged).
- `ledger_v31.html` — v30 plus: morning/evening draws, finalize per session, delete draw results, delete history records, "Active ဂဏန်း N / 100" on the Numbers page.
- `test_v31.cjs` + `harness.cjs` — run the v31 logic without a browser: `node reference/test_v31.cjs reference/ledger_v31.html` (Node 18+). These checks are the starting point for the app's own tests.
