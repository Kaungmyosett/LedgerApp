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

### Diagnostics and test expiry

* `GET /v1/admin/diagnostics` reads recent server, client, database and network events, plus login outcomes from the audit log. Use `category` to filter. Runtime events are buffered in the running process and login outcomes are retained by PostgreSQL. The dashboard receives status codes and operation names without request payloads, SQL, or credentials.
* `POST /v1/client/diagnostics` accepts up to 20 sanitized events from the authenticated client. The server assigns the client identity. The app uploads buffered connection issues after it reconnects.
* `POST /v1/admin/clients/:clientId/shorten` takes `{ "accessUntil": "<ISO timestamp>" }` and changes the regular expiry to an earlier date and time. The server audits the change. An active test override remains effective until restored or disabled.

* `PATCH /v1/admin/clients/:clientId/test-expiry` takes `{ "accessUntil": "<ISO timestamp>" }` or `{ "accessUntil": null }` to restore the regular expiry. Migration 011 adds the override. Set `ENABLE_TEST_EXPIRY_EDIT=true` on the API during testing. With the flag off, the override is ignored by client login and sync, and the Admin controls are hidden.

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
6. Server checks blocked numbers at sync time and records blocked stakes in the ledger log. Voucher create and edit results include saved and rejected fields, so an all-blocked operation can be acknowledged without writing a voucher. The blocked log uses the submitted timestamp when available. A client can remove its own log entry with blocked.log.delete and its blockedOpId and num. The server preserves an audit record of the removal.
7. In one database transaction: insert the idempotency receipt, entry header and lines. Unique `(client_id, client_local_id)` prevents duplicate vouchers.
8. A retry with the same idempotency key returns the original result rather than inserting a second voucher.
9. Mark the local operation `synced` only after the server confirms success. Keep rejected operations visible for user action.
10. If server and local data conflict, never overwrite silently. Return a conflict requiring explicit resolution.

## Client privacy
Client endpoints are scoped from the authenticated account on the server. The app must not be able to request another client's records by changing a URL or request body.

## Ledger sync (v0.6)

All under `/v1/client/ledger`, Client token only; the client id always comes from the token.

* `GET /snapshot` — the whole ledger: `users, entries (active only), blockedNumbers, drawResults, coverVouchers, finalizedRecords, debtEntries, blockedLog`.
* `POST /sync` — body `{ "ops": [ ... ] }` (max 200). Operations run **in order**, each in its own transaction under a per-client advisory lock. Answer: `{ "results": [ {opId, status: "ok"|"error", code?, message?, data?} ] }`.

Operations (each has a client-generated `opId`, and entity ids are client-generated UUIDs): `user.create/update/delete`, `entry.create/update/delete`, `blocked.set`, `draw.save/delete`, `cover.create/delete`, `finalize`, `finalized.delete`, `debt.record`.

`debt.record` takes `id`, `userId`, `date`, `kind` (`debt` or `repayment`), and a positive `amount`. A repayment cannot create a negative balance on any report date. Debt items are entered separately from settlement and are retained after a commission user is deleted.

Commission users have a `settlementSchedule` of `daily` (default) or `weekly`. Legacy user updates that omit it preserve the saved value. Finalizing a weekly user posts the signed net to the debt journal with the finalized record ID, date and morning/evening session. The snapshot supplies the magnitude and a `debt` or `repayment` direction so older clients can still calculate the balance. A non-null `session` identifies an automatic posting. A negative net reduces that user's balance and can leave a credit owed by the dealer. Deleting the finalized record withdraws its linked journal entry. Manual debt and repayment entries are retained.

Finalized records include `covered` and `eaten`. Each frozen amount is split by the settled users’ stake on that number. Rounding remainders are assigned by largest fractional share, with user IDs as the tie-breaker. These amounts are reported alongside the finalized net.


Rules the app relies on:

1. **Idempotent.** The result of every opId (ok or error) is stored in `sync_receipts`; sending it again returns the stored result and changes nothing. A lost response or a killed app is therefore safe.
2. **Server is authoritative.** Cover plans, settlement amounts and finalize records are recomputed on the server with the same code that is tested against the HTML. The app's local copy is only a preview.
3. **After each sync the app downloads the snapshot** and replaces its local base copy, then re-applies operations still waiting in the queue.
4. **Errors are final.** An `error` result (blocked number, already finalized, user not found, …) is not retried; the app shows it in a "rejected changes" list.
5. Finalized vouchers are frozen; history rows and draw results can be deleted (soft delete + audit log entry).

### Version 1 draw sessions

Migration 012 assigns sessions to existing open vouchers and adds the blocked-number log. Vouchers and cover vouchers accept a session on creation. Older clients that omit it are classified by the voucher timestamp using the Yangon 13:00 cutoff. Finalize and cover calculation are scoped to the selected date and session.

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
