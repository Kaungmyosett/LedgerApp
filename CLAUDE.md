# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A 2D lottery ledger: one owner-operated **Admin** manages many **Clients**, each with a private ledger (commission users, vouchers, blocked numbers, draw results, cover vouchers, finalized history). Three parts:

- `backend/` — Node/TypeScript (ESM) Express API on PostgreSQL (`pg`, `zod`, `argon2`, JWT).
- `database/NNN_*.sql` — ordered migrations; each file manages its own `BEGIN/COMMIT`.
- `mobile/` — one Flutter codebase, built as two apps via flavors: `client` ("2D Ledger") and `admin` ("2D Ledger Admin"); `provider` for state.
- `reference/ledger_v31.html` — the original browser-only ledger. Source of truth for ledger calculations **except the owner-approved changes listed under Architecture** (those live in `logic.ts`/`logic.dart` and their tests).

Docs in `docs/` are the spec: `LEDGER_SPEC.md` (rules/formulas), `API_AND_SYNC.md` (endpoints + sync contract), `AUTH.md`, `PRODUCTION.md` (deploy, client/admin flavors).

## Commands

Database (from repo root): `docker compose up -d db`

Backend (from `backend/`; needs `.env` with `DATABASE_URL` and a 32+ char `JWT_SECRET`):
```bash
npm run dev              # tsx watch src/server.ts
npm run typecheck
npm run build && npm start
npm run migrate          # applies database/*.sql not yet in schema_migrations
ADMIN_NAME=.. ADMIN_PHONE=.. ADMIN_PASSWORD=.. npm run create-admin
npm test                 # pure tests: logic diff vs HTML, cover, phone, otp
npm run test:db          # integration + SQL-injection tests; skipped unless TEST_DATABASE_URL is set
npx tsx --test test/cover.test.ts    # single test file
SEED=999 npx tsx --test test/logic.diff.test.ts   # differential test with a different random seed
```
`test:db` needs a throwaway DB (it leaves data behind): `docker compose exec db createdb -U ledger ledger_test`, migrate it with `DATABASE_URL=...ledger_test npm run migrate`, then run with `TEST_DATABASE_URL=...ledger_test`.

Mobile (from `mobile/`):
```bash
flutter pub get
flutter test
flutter test test/ledger_logic_test.dart
flutter analyze
flutter run --flavor client --dart-define=API_URL=http://192.168.1.20:3000   # Android has flavors, so --flavor is required
flutter build apk --release --flavor client --dart-define=API_URL=https://...  # app for clients (no Admin login)
flutter build apk --release --flavor admin  --dart-define=API_URL=https://...  # owner's own app
dart run flutter_launcher_icons   # regenerates per-flavor icons from flutter_launcher_icons-{client,admin}.yaml
```
The flavor (or `--dart-define=APP_MODE=client|admin|both`) decides which logins the build offers — `lib/config.dart`.
The server address can also be changed inside the app (Server dialog, `lib/util/server_url.dart`); the saved value wins over `API_URL`.
Current free online test: Mac + `ngrok http 3000 --url=<static>.ngrok-free.dev` (Cloudflare quick tunnels are blocked on the owner's network) — `docs/TEST_ONLINE_FREE.md`.

Reference HTML logic without a browser: `node reference/test_v31.cjs reference/ledger_v31.html`.

## Architecture

### Ledger logic: HTML + two ports that must stay identical to each other
1. `reference/ledger_v31.html` — original JS.
2. `backend/src/ledger/logic.ts` — TypeScript port (parser, cover plan, number balances, settlement). `test/logic.diff.test.ts` loads the real HTML via `test/html-harness.cjs` and compares outputs on thousands of random cases (parser, balances without cover, numbers summary, settlement).
3. `mobile/lib/ledger/logic.dart` — Dart port, checked by `mobile/test/ledger_logic_test.dart` against `mobile/test/fixtures/ledger_golden.json`.

`logic.ts` and `logic.dart` must always match each other. Regenerate fixtures with
`node --experimental-strip-types backend/test/make-fixtures.ts reference/ledger_v31.html mobile/test/fixtures/ledger_golden.json`
(parser/finalize values come from the HTML; cover values come from `logic.ts`).

**Owner-approved differences from the HTML — keep them, do NOT "fix" them back** (details: `docs/LEDGER_SPEC.md`):
- Cover (v0.6.1): input is *eat per number*, fixed by the first cover voucher of a period (`EAT_LOCKED`); each voucher lists only what changed; numbers page sums all cover lists. Tested in `backend/test/cover.test.ts`.
- Finalize (v0.6.6): users with total stake 0 get no history row and keep their payment; nobody with stake → `NOTHING_TO_FINALIZE`; finalize also closes the cover period.
- Numbers page (v0.6.6): with no cover, "your eaten" = total stake − Σ(user stake × user commission%) − Σ(user winning stake × user odd).
- Format box (v0.6.7–0.6.8): `=` works like `-` (`1PP=100`, `17=R2500`, `Apu-1000`); Myanmar words ပါတ်/အပူး/ထိပ်/ပိတ်/ပါဝါ/နက္ခတ်/ညီကို; `012ခွေ` (all ordered pairs of different digits) and `012ခွေပူး` (+ doubles).
- Doubles counted once (v0.7.4): `00/11 R1000` = 00 and 11 at 1000 each (a double has no separate reverse); `1PP` = 19 numbers with 11 once. Unlike the others, this one was also changed in `reference/ledger_v31.html` (the untouched original is `ledger_v30_original.html`), so the diff test and fixtures include it.
Other changes to ledger rules need the owner's explicit approval — see `docs/MIGRATION_AND_TEST_PLAN.md`.

### Offline-first operation sync
- The app keeps the ledger in `ledger_data.json` (`mobile/lib/ledger/ledger_store.dart`) and records every change as an operation (`lib/ledger/ops.dart`) in a queue. Local state = server snapshot + pending ops re-applied by the local reducer (a preview only).
- `POST /v1/client/ledger/sync` with `{ops: [...]}` (max 200): `backend/src/ledger/ops.ts` validates each op with a zod discriminated union (`opSchema`), then applies them **in order, each in its own transaction under a per-client advisory lock**. Every op's result (ok or error) is stored in `sync_receipts` by `opId`, so resends are idempotent. Errors are final — the app shows them as rejected, never retries.
- **Server is authoritative**: cover plans, settlement amounts and finalize records are recomputed server-side with `logic.ts`. After each sync the app downloads `GET /v1/client/ledger/snapshot` (`snapshot.ts`) and replaces its base copy.
- Entity ids and `opId`s are client-generated UUIDs. Adding an op type means updating `opSchema`/handlers in `ops.ts`, the Dart op + reducer, and the docs.

### Auth and scoping
- Admin: phone + password (Argon2id). Client: email + one-time 6-digit code issued by the Admin (stored as keyed hash), single device session. Short access JWT + rotating refresh tokens; lockout + per-IP rate limit on `/v1/auth`.
- Client endpoints always derive `client_id` from the token (`middleware/auth.ts`); never accept a client id from the body/URL.
- All SQL is parameterized (`$1`…); search escapes `\ % _` before `ILIKE`. `sqli.integration.test.ts` guards this.
- Sensitive actions write to the append-only audit log (`src/audit.ts`). History rows and draw results are soft-deleted with an audit entry; finalized vouchers are frozen.
- Config is validated by zod in `src/config.ts`; the server refuses to start in production with the example `JWT_SECRET`.
- Plans (migration 007): `clients.plan` (`basic` = 1 month, `pro` = 3 months) + `access_until`. Expired → client login and `/v1/client/ledger/*` return `PLAN_EXPIRED`; `/v1/client/me` stays open. Admin renews with `POST /v1/admin/clients/:id/extend`.
- The phone also locks changes offline (`LedgerStore.lockReason`): plan ended, no server contact for 7 days (`offlineGrace`), or clock moved back. Viewing still works.

## Conventions
- 2D numbers are always two-character strings `00`–`99` (never ints). Money: positive, at most 2 decimals.
- Backend is ESM: import local files with the `.js` extension (`'../db.js'`) even from `.ts`.
- Mobile UI strings live in `mobile/lib/i18n/strings.dart` (Myanmar default + English); every key must exist in both maps (`test/i18n_test.dart`).
- New migrations: next `NNN_name.sql` in `database/`, self-contained transaction; never edit an applied one.
