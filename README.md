# 2D Ledger — Production Starter

This is the first backend/database foundation for the existing 2D Ledger.

## Confirmed product decisions
- One owner-operated Admin account manages many Clients.
- Android and iPhone are the target platforms (Flutter client planned).
- Admin creates Client accounts; there is no public registration.
- Admin login: phone + password.
- Client login: email + a one-time code issued by the Admin (clients have no password). One phone per client.
- Each client owns a private ledger (see `docs/LEDGER_SPEC.md`).
- Ledger entries can be saved offline as drafts and synchronized when connectivity returns.
- Preserve 2D numbers as two-character strings (`00`–`99`).

## Important status
This is a **starter foundation**, not a deployed production service and not yet the finished mobile app.
The current HTML file is a browser-only demo using `localStorage`; it is not a secure multi-user backend.
The database schema below is designed to keep client data isolated and make sync retries idempotent.

## Contents
- `database/001_initial_schema.sql` — PostgreSQL schema.
- `backend/package.json` — backend dependencies and scripts.
- `backend/tsconfig.json` — TypeScript configuration.
- `backend/src/` — API: authentication, Admin creates clients, clients log in with an Admin-issued code, audit logging (v0.2).
- `database/002_auth_hardening.sql` — login lockout, refresh tokens, append-only audit log.
- `mobile/` — Flutter app (login for Admin and Client, Admin client management). See `mobile/README.md`.
- `reference/` — the HTML ledger (original v30 and the updated v31) with logic tests.
- `docs/LEDGER_SPEC.md` — what ledger_v30.html does, extracted as rules and formulas.
- `docs/AUTH.md` — auth endpoints, security behaviour, smoke test.
- `backend/.env.example` — environment variable template.
- `docs/API_AND_SYNC.md` — API outline and offline synchronization rules.
- `docs/MIGRATION_AND_TEST_PLAN.md` — migration and calculation regression plan.

## Start the database
Requires Docker and Docker Compose:
```bash
docker compose up -d db
```

## Start the API
```bash
cd backend
cp .env.example .env        # set a strong JWT_SECRET (32+ chars)
npm install
npm run migrate             # applies database/*.sql in order
ADMIN_NAME="Owner" ADMIN_PHONE="09xxxxxxxxx" ADMIN_PASSWORD="<12+ chars>" npm run create-admin
npm run dev
npm test
```
See `docs/AUTH.md` for the endpoints and a curl smoke test.
Set a strong `DATABASE_URL` and `JWT_SECRET` before exposing the service. The API refuses to start in production with the example secret.

## Security decisions
- Passwords must be stored only as Argon2id hashes (never plaintext).
- Authentication must resolve account identity on the server.
- A Client API request must always be scoped to the authenticated client ID; never trust a client ID supplied in the request body.
- Use HTTPS in production.
- Keep audit records append-only for normal application roles.
- Use database backups and test restore procedures before launch.

## Status
Done (v0.6): everything in v0.5, plus the client ledger on the server and in the app — commission users, vouchers (Format + manual), blocked numbers, Numbers 00–99 with the Active count, morning/evening draw results (deletable), cover vouchers, finalize per session, deletable history, offline queue with idempotent sync.
Verified in the build sandbox: the ledger rules (TypeScript) against the real HTML on thousands of random cases. NOT verified there (no PostgreSQL/Flutter available): the SQL (run `npm run test:db`) and the Flutter app (run `flutter test`, then try it by hand).
Next: real-device testing, backups/deploy, and anything you find while using it.


## For test ngrok server
ngrok http 3000 --url=unchary-stational-mildred.ngrok-free.dev