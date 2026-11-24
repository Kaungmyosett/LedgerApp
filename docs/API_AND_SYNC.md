# API and offline synchronization contract

## Authentication (implemented — see AUTH.md)
- `POST /v1/auth/admin/login` — phone + password.
- `POST /v1/auth/client/login` — email + one-time code issued by the Admin (one phone per client).
- `POST /v1/admin/clients` — Admin-only; create a client (name + email) and receive its first login code.
- No public client sign-up endpoint.
- Admin password is an Argon2id hash; client login codes are stored only as keyed hashes. Never return either from APIs.

## Client data endpoints
- `GET /v1/client/me`
- `GET /v1/client/ledger?from=YYYY-MM-DD&to=YYYY-MM-DD`
- `POST /v1/client/sync`
- `POST /v1/client/ledger/:id/void` — only if product rules permit; require a reason and audit it.

## Admin endpoints
- `GET /v1/admin/clients`
- `PATCH /v1/admin/clients/:clientId`
- `GET /v1/admin/clients/:clientId/ledger`
- `POST /v1/admin/draw-results`
- `POST /v1/admin/cover-vouchers`
- `POST /v1/admin/settlements`

## Sync payload shape
Each locally created voucher receives a stable UUID before it is queued:
```json
{
  "operations": [
    {
      "idempotencyKey": "stable-uuid-created-on-device",
      "type": "ledger.entry.create",
      "clientLocalId": "stable-entry-uuid",
      "entryDate": "2026-11-15",
      "mode": "manual",
      "lines": [
        { "number": "07", "amount": "1000.00" },
        { "number": "42", "amount": "500.00" }
      ],
      "deviceCreatedAt": "2026-11-15T09:30:00+06:30"
    }
  ]
}
```

## Sync rules
1. Save locally first in a durable local database (SQLite/Drift in Flutter), status `pending`.
2. The client generates and persists `idempotencyKey` and `clientLocalId` once. Retries must reuse them.
3. Send pending operations in creation order when network returns.
4. Server derives `client_id` from the authenticated token. Ignore/reject any client ID in payload.
5. Server validates every number against `^[0-9]{2}$`, range `00`–`99`, and positive amount.
6. Server checks blocked numbers at sync time. A blocked number should return a clear per-operation rejection; do not silently drop it.
7. In one database transaction: insert the idempotency receipt, entry header and lines. Unique `(client_id, client_local_id)` prevents duplicate vouchers.
8. A retry with the same idempotency key returns the original result rather than inserting a second voucher.
9. Mark the local operation `synced` only after the server confirms success. Keep rejected operations visible for user action.
10. If server and local data conflict, never overwrite silently. Return a conflict requiring explicit resolution.

## Client privacy
Client endpoints are scoped from the authenticated account on the server. The app must not be able to request another client's records by changing a URL or request body.

## Ledger sync (v0.6)

All under `/v1/client/ledger`, Client token only; the client id always comes from the token.

* `GET /snapshot` — the whole ledger: `users, entries (active only), blockedNumbers, drawResults, coverVouchers, finalizedRecords`.
* `POST /sync` — body `{ "ops": [ ... ] }` (max 200). Operations run **in order**, each in its own transaction under a per-client advisory lock. Answer: `{ "results": [ {opId, status: "ok"|"error", code?, message?, data?} ] }`.

Operations (each has a client-generated `opId`, and entity ids are client-generated UUIDs): `user.create/update/delete`, `entry.create/update/delete`, `blocked.set`, `draw.save/delete`, `cover.create/delete`, `finalize`, `finalized.delete`.

Rules the app relies on:

1. **Idempotent.** The result of every opId (ok or error) is stored in `sync_receipts`; sending it again returns the stored result and changes nothing. A lost response or a killed app is therefore safe.
2. **Server is authoritative.** Cover plans, settlement amounts and finalize records are recomputed on the server with the same code that is tested against the HTML. The app's local copy is only a preview.
3. **After each sync the app downloads the snapshot** and replaces its local base copy, then re-applies operations still waiting in the queue.
4. **Errors are final.** An `error` result (blocked number, already finalized, user not found, …) is not retried; the app shows it in a "rejected changes" list.
5. Finalized vouchers are frozen; history rows and draw results can be deleted (soft delete + audit log entry).

## Security test: SQL injection (v0.6.5)

`backend/test/sqli.integration.test.ts` (run with `npm run test:db`, needs `TEST_DATABASE_URL`) fires classic injection payloads
(`' OR '1'='1`, `'; DROP TABLE admin_accounts; --`, UNION/stacked queries, time-based, LIKE wildcards) at:

* **Admin login** — the phone is normalized first (an injection string is not a valid phone, so the lookup never runs), and the
  lookup itself binds the value as `$1`. No bypass, the real password is still the only one that verifies, and no table is dropped.
* **Client login** — email and one-time code are bound as values, never concatenated.
* **Admin client search** — the `q` box escapes `\\ % _` before a parameterized `ILIKE`, so a typed `%` matches literally instead of
  returning every client.

Why the app is safe in general: every query uses parameterized placeholders (`$1`, `$2`, …) with `pg`, inputs are validated by zod
schemas with length limits, and no SQL is ever built by string concatenation. The test is a regression guard for that.
