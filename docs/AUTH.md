# Accounts and login (v0.5)

## Who is who
- **Admin** — exactly one account (the owner). Logs in with phone + password. Creates every client account and issues their login codes.
- **Client** — a dealer account created by the Admin, identified by email. Each client has a private ledger (see `LEDGER_SPEC.md`).
  Clients **cannot sign themselves up and have no password or email**. They log in only with their **email address** + a 6-digit code the Admin gives them. (The system does not send any email; the Admin passes the code on.)

## Client login code
- The Admin creates a client (name + email) and the app shows a 6-digit code **once**. The Admin passes it to the client (Viber, call, in person).
- The code works **once**, then the client stays signed in on that phone (30-day session that renews itself).
- Valid for 24 hours by default (`LOGIN_CODE_TTL_HOURS`, 1–168 per code).
- Only a keyed hash is stored; nobody, including the Admin, can read a code afterwards. Lost or expired code → Admin generates a new one (the old one stops working).
- 5 wrong attempts lock the client for 15 minutes **and cancel the current code**; the Admin issues a new code (which also clears the lock).
- **One phone per client.** When a client logs in with a code, every other device of that client is signed out immediately (access tokens carry a `session_version` that is checked on every request). Moving to a new phone = Admin issues a new code; the old phone is cut off the moment the new one logs in. Drafts still unsynced on the old phone can no longer be uploaded, so sync before switching.
- Lost phone → Admin uses **Sign out all devices** and issues a new code. The ledger data stays on the server.
- Deactivating a client signs them out at once and cancels any waiting code. Data is kept.

## Tokens
- Access token: JWT (HS256), 15 minutes, sent as `Authorization: Bearer <token>`.
- Refresh token: random, 30 days, stored only as a SHA-256 hash, rotates on every use.
- Every request re-checks that the account is still active.
- All login failures return the same `401 INVALID_CREDENTIALS`, so the API does not reveal which phone numbers exist. Per-IP limit: 30 requests / 15 min on `/v1/auth/*`.

## Endpoints
| Method | Path | Who | Body |
|---|---|---|---|
| POST | `/v1/auth/admin/login` | public | `{ phone, password }` |
| POST | `/v1/auth/client/login` | public | `{ email, code }` |
| POST | `/v1/auth/refresh` | public | `{ refreshToken }` |
| POST | `/v1/auth/logout` | public | `{ refreshToken }` → 204 |
| POST | `/v1/auth/admin/change-password` | admin | `{ currentPassword, newPassword }` (12+ chars) |
| POST | `/v1/admin/clients` | admin | `{ displayName, email, expiresInHours? }` → `{ client, loginCode, loginCodeExpiresAt }` |
| GET | `/v1/admin/clients?q=&active=&limit=&offset=` | admin | |
| GET | `/v1/admin/clients/:id` | admin | |
| PATCH | `/v1/admin/clients/:id` | admin | any of `displayName, email, isActive` |
| POST | `/v1/admin/clients/:id/login-code` | admin | `{ expiresInHours? }` → `{ loginCode, loginCodeExpiresAt }` |
| POST | `/v1/admin/clients/:id/sign-out` | admin | → 204 |
| GET | `/v1/client/me` | client | own profile; the ID comes from the token |

Client emails are trimmed and compared case-insensitively. The Admin's phone number is normalized to E.164; numbers without a country code are treated as Myanmar (+95): `09 123 456 789` → `+959123456789`.
Every client create/update, code issue, sign-out and every login (success or failure) is written to `audit_logs`. Codes are never logged.

## Smoke test
```bash
# Admin login
curl -s localhost:3000/v1/auth/admin/login -H 'content-type: application/json' \
  -d '{"phone":"09123456789","password":"your-admin-password"}'      # accessToken -> $A

# Create a client; the response contains loginCode
curl -s localhost:3000/v1/admin/clients -H "authorization: Bearer $A" -H 'content-type: application/json' \
  -d '{"displayName":"Ko Aung","email":"aung@example.com"}'

# Client login with that code (works once)
curl -s localhost:3000/v1/auth/client/login -H 'content-type: application/json' \
  -d '{"email":"aung@example.com","code":"123456"}'
# Using the same code again, or a wrong code -> 401 INVALID_CREDENTIALS
```

## Known limits
- Refresh-token reuse is rejected but does not revoke the whole session family.
- The audit/finalized triggers can be disabled by a database superuser; use a low-privilege DB role for the API before production.
- A 6-digit code is only safe because it is single-use, short-lived, tied to one email address, and cancelled after 5 wrong guesses.

## Plans (v0.7.0)

* Each client has a plan: **basic = 1 month**, **pro = 3 months**, stored as `clients.plan` + `clients.access_until` (migration 007).
* The Admin picks the plan when creating a client and renews from the client screen (`POST /v1/admin/clients/:id/extend {plan}`).
  Renewal adds the months to the later of today or the current end date, so paying early never loses days. Every renewal is audited.
* When `access_until` has passed: client login is refused with `PLAN_EXPIRED` (the code is checked first and is NOT used up), and
  `/v1/client/ledger/*` returns `403 PLAN_EXPIRED`. `/v1/client/me` stays open so the app can show the end date. Ledger data is kept;
  changes made on the phone stay queued and sync after the renewal.
* `REFRESH_TOKEN_TTL_DAYS` is unrelated: it is only how long a login lasts without using the app (same for everyone).
* Existing clients got basic + 1 month from the moment migration 007 ran.

## Offline plan check (v0.7.1)

The phone also enforces the plan, so "never go online" does not keep the app working:

* After every successful sync the phone stores the plan end date (`/v1/client/me`) and the time the server last answered.
* Changes are blocked (viewing still works) when:
  * the plan end date has passed (`PLAN_EXPIRED`), or the server answered `PLAN_EXPIRED`;
  * the server has not been reached for more than **7 days** (`OFFLINE_TOO_LONG`, `LedgerStore.offlineGrace`);
  * the phone clock was moved back more than 12 hours behind the latest time already seen (`CLOCK_CHANGED`).
* Going online once (or fixing the clock / renewing) unlocks it. Nothing already saved is lost.
