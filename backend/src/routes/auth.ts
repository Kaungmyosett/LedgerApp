import { Router, type Request } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { pool, withTransaction } from '../db.js';
import { writeAudit } from '../audit.js';
import { cleanLoginCode, hashLoginCode, hashesEqual } from '../auth/otp.js';
import { dummyHash, hashPassword, verifyPassword } from '../auth/password.js';
import { ACCOUNT_TABLE, issueSession, revokeAllSessions } from '../auth/session.js';
import { hashToken, type Role } from '../auth/tokens.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';
import { HttpError } from '../util/errors.js';
import { normalizeEmail, normalizePhone } from '../util/phone.js';

export const authRouter = Router();

const adminLoginSchema = z.object({ phone: z.string().min(1).max(40), password: z.string().min(1).max(200) }).strict();
// Clients have no password: email + the 6-digit code the Admin gave them.
const clientLoginSchema = z.object({ email: z.string().min(1).max(254), code: z.string().min(1).max(20) }).strict();
const refreshSchema = z.object({ refreshToken: z.string().min(20).max(200) }).strict();
const adminChangePasswordSchema = z
  .object({
    currentPassword: z.string().min(1).max(200),
    newPassword: z.string().min(12, 'Password must be at least 12 characters').max(128)
  })
  .strict();

const GENERIC_LOGIN_ERROR = 'Invalid credentials, or too many failed attempts. Try again later.';

async function registerFailure(role: Role, accountId: string): Promise<boolean> {
  const { rows } = await pool.query<{ locked: boolean }>(
    `UPDATE ${ACCOUNT_TABLE[role]} SET
       failed_login_count = CASE WHEN locked_until IS NOT NULL AND locked_until <= now()
                                 THEN 1 ELSE failed_login_count + 1 END,
       locked_until = CASE
         WHEN locked_until IS NOT NULL AND locked_until <= now() THEN NULL
         WHEN failed_login_count + 1 >= $2 THEN now() + make_interval(mins => $3)
         ELSE locked_until END
     WHERE id = $1
     RETURNING (locked_until IS NOT NULL AND locked_until > now()) AS locked`,
    [accountId, config.MAX_FAILED_LOGINS, config.LOCKOUT_MINUTES]
  );
  return rows[0]?.locked ?? false;
}

// ---------------------------------------------------------------------------
// Admin: phone + password
// ---------------------------------------------------------------------------
interface AdminRow {
  id: string;
  display_name: string;
  password_hash: string;
  is_active: boolean;
  locked: boolean;
}

authRouter.post(
  '/admin/login',
  asyncHandler(async (req, res) => {
    const body = adminLoginSchema.parse(req.body);
    const phone = normalizePhone(body.phone);
    const account = phone
      ? (
          await pool.query<AdminRow>(
            `SELECT id, display_name, password_hash, is_active,
                    (locked_until IS NOT NULL AND locked_until > now()) AS locked
               FROM admin_accounts WHERE phone_e164 = $1`,
            [phone]
          )
        ).rows[0]
      : undefined;

    // Always do one Argon2 verification so unknown accounts cost the same time as known ones.
    const ok = await verifyPassword(account?.password_hash ?? (await dummyHash), body.password);

    if (!account || !ok || !account.is_active || account.locked) {
      let nowLocked = false;
      if (account && !ok && account.is_active && !account.locked) nowLocked = await registerFailure('admin', account.id);
      await writeAudit(pool, {
        actorType: 'system',
        action: 'auth.login_failed',
        entityType: 'admin',
        entityId: account?.id ?? null,
        after: { ip: req.ip, lockedNow: nowLocked, wasLocked: account?.locked ?? false }
      });
      throw new HttpError(401, 'INVALID_CREDENTIALS', GENERIC_LOGIN_ERROR);
    }

    const result = await withTransaction(async (db) => {
      await db.query(
        `UPDATE admin_accounts SET failed_login_count = 0, locked_until = NULL, last_login_at = now() WHERE id = $1`,
        [account.id]
      );
      const session = await issueSession(db, 'admin', account.id, req.get('user-agent'));
      await writeAudit(db, {
        actorType: 'admin',
        actorId: account.id,
        action: 'auth.login',
        entityType: 'admin',
        entityId: account.id,
        after: { ip: req.ip }
      });
      return { role: 'admin' as const, account: { id: account.id, displayName: account.display_name }, ...session };
    });
    res.json(result);
  })
);

// ---------------------------------------------------------------------------
// Client: email + one-time code issued by the Admin
// ---------------------------------------------------------------------------
interface ClientRow {
  id: string;
  display_name: string;
  is_active: boolean;
  locked: boolean;
  expired: boolean;
}

const ZERO_UUID = '00000000-0000-0000-0000-000000000000';
const DUMMY_HASH = hashLoginCode(config.JWT_SECRET, ZERO_UUID, 'no-such-code');

async function clientLogin(req: Request, rawEmail: string, rawCode: string) {
  const email = normalizeEmail(rawEmail);
  const code = cleanLoginCode(rawCode);

  const client = email
    ? (
        await pool.query<ClientRow>(
          `SELECT id, display_name, is_active,
                  (locked_until IS NOT NULL AND locked_until > now()) AS locked,
                  (access_until IS NULL OR access_until <= now()) AS expired
             FROM clients WHERE email = $1`,
          [email]
        )
      ).rows[0]
    : undefined;

  const usable = !!client && client.is_active && !client.locked;
  const stored = usable
    ? (
        await pool.query<{ id: string; code_hash: string }>(
          `SELECT id, code_hash FROM client_login_codes
            WHERE client_id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()`,
          [client!.id]
        )
      ).rows[0]
    : undefined;

  // Compare in constant time against a dummy when there is nothing to compare with.
  const candidate = hashLoginCode(config.JWT_SECRET, client?.id ?? ZERO_UUID, code ?? '------');
  const matches = hashesEqual(candidate, stored?.code_hash ?? DUMMY_HASH) && !!stored && code !== null;

  if (!matches) {
    let nowLocked = false;
    if (usable) {
      nowLocked = await registerFailure('client', client!.id);
      if (nowLocked) {
        // Too many wrong guesses: kill the code so it can never be brute-forced; Admin must issue a new one.
        await pool.query(
          `UPDATE client_login_codes SET revoked_at = now()
            WHERE client_id = $1 AND used_at IS NULL AND revoked_at IS NULL`,
          [client!.id]
        );
      }
    }
    await writeAudit(pool, {
      actorType: 'system',
      action: 'auth.client_login_failed',
      entityType: 'client',
      entityId: client?.id ?? null,
      after: { ip: req.ip, lockedNow: nowLocked, hadActiveCode: !!stored }
    });
    throw new HttpError(401, 'INVALID_CREDENTIALS', GENERIC_LOGIN_ERROR);
  }

  // Plan ended: refuse, but only after the code was checked (so this can't be used to probe emails),
  // and without using up the code — it works again as soon as the Admin extends the plan.
  if (client!.expired) throw new HttpError(403, 'PLAN_EXPIRED', 'Your plan has ended. Please contact the Admin to renew.');

  return withTransaction(async (db) => {
    // Single use: the UPDATE only succeeds for the first request that uses this code.
    const used = await db.query(
      `UPDATE client_login_codes SET used_at = now()
        WHERE id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()`,
      [stored!.id]
    );
    if (!used.rowCount) throw new HttpError(401, 'INVALID_CREDENTIALS', GENERIC_LOGIN_ERROR);

    await db.query(`UPDATE clients SET failed_login_count = 0, locked_until = NULL, last_login_at = now() WHERE id = $1`, [
      client!.id
    ]);
    // One phone per client: logging in here signs every other device out immediately.
    await revokeAllSessions(db, 'client', client!.id);
    const session = await issueSession(db, 'client', client!.id, req.get('user-agent'));
    await writeAudit(db, {
      actorType: 'client',
      actorId: client!.id,
      action: 'auth.client_login',
      entityType: 'client',
      entityId: client!.id,
      after: { ip: req.ip }
    });
    return { role: 'client' as const, account: { id: client!.id, displayName: client!.display_name }, ...session };
  });
}

authRouter.post(
  '/client/login',
  asyncHandler(async (req, res) => {
    const body = clientLoginSchema.parse(req.body);
    res.json(await clientLogin(req, body.email, body.code));
  })
);

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------
// Refresh tokens rotate: each use revokes the old token and issues a new pair.
authRouter.post(
  '/refresh',
  asyncHandler(async (req, res) => {
    const { refreshToken } = refreshSchema.parse(req.body);
    const hash = hashToken(refreshToken);

    const result = await withTransaction(async (db) => {
      const { rows } = await db.query<{
        id: string;
        account_type: Role;
        account_id: string;
        expires_at: Date;
        revoked_at: Date | null;
      }>(
        `SELECT id, account_type, account_id, expires_at, revoked_at
           FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE`,
        [hash]
      );
      const row = rows[0];
      if (!row || row.revoked_at || row.expires_at <= new Date()) return null;
      if (row.account_type !== 'admin' && row.account_type !== 'client') return null;

      const active = await db.query<{ is_active: boolean }>(
        `SELECT is_active FROM ${ACCOUNT_TABLE[row.account_type]} WHERE id = $1`,
        [row.account_id]
      );
      if (!active.rows[0]?.is_active) return null;

      await db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1', [row.id]);
      return issueSession(db, row.account_type, row.account_id, req.get('user-agent'));
    });

    if (!result) throw new HttpError(401, 'INVALID_REFRESH_TOKEN', 'Session expired. Please log in again.');
    res.json(result);
  })
);

authRouter.post(
  '/logout',
  asyncHandler(async (req, res) => {
    const { refreshToken } = refreshSchema.parse(req.body);
    await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL', [
      hashToken(refreshToken)
    ]);
    res.status(204).end();
  })
);

// Only the Admin has a password.
authRouter.post(
  '/admin/change-password',
  requireAuth('admin'),
  asyncHandler(async (req, res) => {
    const body = adminChangePasswordSchema.parse(req.body);
    const adminId = req.auth!.id;
    const { rows } = await pool.query<{ password_hash: string }>(
      'SELECT password_hash FROM admin_accounts WHERE id = $1',
      [adminId]
    );
    if (!rows[0] || !(await verifyPassword(rows[0].password_hash, body.currentPassword))) {
      throw new HttpError(401, 'INVALID_CREDENTIALS', 'Current password is incorrect.');
    }
    const newHash = await hashPassword(body.newPassword);
    const session = await withTransaction(async (db) => {
      await db.query('UPDATE admin_accounts SET password_hash = $2, password_changed_at = now() WHERE id = $1', [
        adminId,
        newHash
      ]);
      await revokeAllSessions(db, 'admin', adminId);
      await writeAudit(db, {
        actorType: 'admin',
        actorId: adminId,
        action: 'auth.password_changed',
        entityType: 'admin',
        entityId: adminId
      });
      return issueSession(db, 'admin', adminId, req.get('user-agent'));
    });
    res.json(session);
  })
);
