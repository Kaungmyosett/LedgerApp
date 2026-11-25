import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { isPgError, pool, withTransaction, type Db } from '../db.js';
import { writeAudit } from '../audit.js';
import { generateLoginCode, hashLoginCode } from '../auth/otp.js';
import { revokeAllSessions } from '../auth/session.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';
import { HttpError } from '../util/errors.js';
import { normalizeEmail } from '../util/phone.js';

// Admin-only. The Admin creates client accounts and issues their login codes.
export const adminClientsRouter = Router();
adminClientsRouter.use(requireAuth('admin'));

const SELECT_CLIENT = `
  SELECT c.id, c.display_name, c.email, c.is_active, c.created_at, c.updated_at, c.last_login_at, c.plan, c.access_until, c.test_access_until,
         (SELECT k.expires_at FROM client_login_codes k
           WHERE k.client_id = c.id AND k.used_at IS NULL AND k.revoked_at IS NULL AND k.expires_at > now()
           LIMIT 1) AS login_code_expires_at
    FROM clients c`;

interface ClientRow {
  id: string;
  display_name: string;
  email: string | null;
  is_active: boolean;
  created_at: Date;
  updated_at: Date;
  last_login_at: Date | null;
  login_code_expires_at: Date | null;
  plan: 'basic' | 'pro' | null;
  access_until: Date | null;
  test_access_until: Date | null;
}

/** basic = 1 month, pro = 3 months. */
export const PLAN_INTERVAL = { basic: '1 month', pro: '3 months' } as const;
const planField = z.enum(['basic', 'pro']);

function toDto(r: ClientRow) {
  return {
    id: r.id,
    displayName: r.display_name,
    email: r.email,
    isActive: r.is_active,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    lastLoginAt: r.last_login_at,
    // Whether a code is waiting to be used. The code itself can never be read back.
    loginCodeExpiresAt: r.login_code_expires_at,
    plan: r.plan,
    accessUntil: config.ENABLE_TEST_EXPIRY_EDIT === 'true' ? r.test_access_until ?? r.access_until : r.access_until,
    testExpiryEnabled: config.ENABLE_TEST_EXPIRY_EDIT === 'true',
    testAccessUntil: config.ENABLE_TEST_EXPIRY_EDIT === 'true' ? r.test_access_until : null,
    regularAccessUntil: r.access_until
  };
}

async function loadClient(db: Db, id: string, lock = false): Promise<ClientRow | undefined> {
  const { rows } = await db.query<ClientRow>(`${SELECT_CLIENT} WHERE c.id = $1${lock ? ' FOR UPDATE OF c' : ''}`, [id]);
  return rows[0];
}

/** Revokes any unused code, stores a new one (hash only) and returns the plain code once. */
async function issueLoginCode(db: Db, clientId: string, adminId: string, ttlHours: number) {
  const code = generateLoginCode();
  const expiresAt = new Date(Date.now() + ttlHours * 3_600_000);
  await db.query(
    `UPDATE client_login_codes SET revoked_at = now()
      WHERE client_id = $1 AND used_at IS NULL AND revoked_at IS NULL`,
    [clientId]
  );
  await db.query(
    `INSERT INTO client_login_codes (client_id, code_hash, expires_at, created_by_admin_id)
     VALUES ($1, $2, $3, $4)`,
    [clientId, hashLoginCode(config.JWT_SECRET, clientId, code), expiresAt, adminId]
  );
  // A fresh code also clears a lockout caused by earlier wrong guesses.
  await db.query('UPDATE clients SET failed_login_count = 0, locked_until = NULL WHERE id = $1', [clientId]);
  await writeAudit(db, {
    actorType: 'admin',
    actorId: adminId,
    action: 'client.login_code_issued',
    entityType: 'client',
    entityId: clientId,
    after: { expiresAt: expiresAt.toISOString() } // never the code itself
  });
  return { code, expiresAt };
}

const emailField = z
  .string()
  .max(300)
  .transform((v, ctx) => {
    const e = normalizeEmail(v);
    if (!e) ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Invalid email address' });
    return e ?? '';
  });
const idParam = z.string().uuid();
const ttlField = z.number().int().min(1).max(168).optional();

const createSchema = z
  .object({ displayName: z.string().trim().min(1).max(100), email: emailField, plan: planField.default('basic'), expiresInHours: ttlField })
  .strict();
const updateSchema = z
  .object({ displayName: z.string().trim().min(1).max(100), email: emailField, isActive: z.boolean() })
  .partial()
  .strict()
  .refine((v) => Object.keys(v).length > 0, { message: 'No fields to update' });
const codeSchema = z.object({ expiresInHours: ttlField }).strict();

function mapDbError(e: unknown): never {
  if (isPgError(e) && e.code === '23505') {
    throw new HttpError(409, 'CLIENT_ALREADY_EXISTS', 'A client with this email already exists.');
  }
  throw e;
}

/** The client that already uses [email] (active or not), other than [exceptId]. Emails compare case-insensitively (CITEXT). */
async function emailOwner(db: Db, email: string, exceptId?: string): Promise<{ id: string; display_name: string } | undefined> {
  const { rows } = await db.query<{ id: string; display_name: string }>(
    'SELECT id, display_name FROM clients WHERE email = $1 AND ($2::uuid IS NULL OR id <> $2::uuid) LIMIT 1',
    [email, exceptId ?? null]
  );
  return rows[0];
}

function alreadyUsed(name: string): never {
  throw new HttpError(409, 'CLIENT_ALREADY_EXISTS', `This email is already used by client "${name}".`);
}

// Create a client account and its first login code. The code is shown to the Admin ONCE.
adminClientsRouter.post(
  '/',
  asyncHandler(async (req, res) => {
    const body = createSchema.parse(req.body);
    const adminId = req.auth!.id;
    try {
      const out = await withTransaction(async (db) => {
        // Clear answer before the INSERT; the UNIQUE index still guards against two Admins racing.
        const owner = await emailOwner(db, body.email);
        if (owner) alreadyUsed(owner.display_name);
        const { rows } = await db.query<{ id: string }>(
          `INSERT INTO clients (display_name, email, created_by_admin_id, plan, access_until)
           VALUES ($1, $2, $3, $4, now() + $5::interval) RETURNING id`,
          [body.displayName, body.email, adminId, body.plan, PLAN_INTERVAL[body.plan]]
        );
        const id = rows[0]!.id;
        const issued = await issueLoginCode(db, id, adminId, body.expiresInHours ?? config.LOGIN_CODE_TTL_HOURS);
        const client = toDto((await loadClient(db, id))!);
        await writeAudit(db, {
          actorType: 'admin',
          actorId: adminId,
          action: 'client.create',
          entityType: 'client',
          entityId: id,
          after: client
        });
        return { client, loginCode: issued.code, loginCodeExpiresAt: issued.expiresAt };
      });
      res.status(201).json(out);
    } catch (e) {
      mapDbError(e);
    }
  })
);

adminClientsRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    const query = z
      .object({
        q: z.string().trim().max(100).optional(),
        active: z.enum(['true', 'false']).optional(),
        limit: z.coerce.number().int().min(1).max(200).default(50),
        offset: z.coerce.number().int().min(0).default(0)
      })
      .parse(req.query);

    const where: string[] = [];
    const values: unknown[] = [];
    if (query.q) {
      values.push('%' + query.q.replace(/[\\%_]/g, '\\$&') + '%');
      where.push(`(c.display_name ILIKE $${values.length} OR c.email ILIKE $${values.length})`);
    }
    if (query.active) {
      values.push(query.active === 'true');
      where.push(`c.is_active = $${values.length}`);
    }
    values.push(query.limit, query.offset);
    const { rows } = await pool.query<ClientRow>(
      `${SELECT_CLIENT}
       ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY c.created_at DESC LIMIT $${values.length - 1} OFFSET $${values.length}`,
      values
    );
    res.json({ clients: rows.map(toDto), limit: query.limit, offset: query.offset });
  })
);

// Lets the form say "already used" before saving. ?email=...&exceptId=<client being edited>
adminClientsRouter.get(
  '/email-check',
  asyncHandler(async (req, res) => {
    const q = z.object({ email: z.string().max(300), exceptId: idParam.optional() }).parse(req.query);
    const email = normalizeEmail(q.email);
    if (!email) return void res.json({ valid: false, available: false });
    const owner = await emailOwner(pool, email, q.exceptId);
    res.json({ valid: true, available: !owner, ...(owner ? { usedBy: owner.display_name } : {}) });
  })
);

adminClientsRouter.get(
  '/:clientId',
  asyncHandler(async (req, res) => {
    const row = await loadClient(pool, idParam.parse(req.params.clientId));
    if (!row) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
    res.json(toDto(row));
  })
);

const FIELD_TO_COLUMN = { displayName: 'display_name', email: 'email', isActive: 'is_active' } as const;

adminClientsRouter.patch(
  '/:clientId',
  asyncHandler(async (req, res) => {
    const clientId = idParam.parse(req.params.clientId);
    const body = updateSchema.parse(req.body);
    const adminId = req.auth!.id;

    const sets: string[] = [];
    const values: unknown[] = [];
    for (const key of Object.keys(FIELD_TO_COLUMN) as (keyof typeof FIELD_TO_COLUMN)[]) {
      if (body[key] !== undefined) {
        values.push(body[key]);
        sets.push(`${FIELD_TO_COLUMN[key]} = $${values.length}`);
      }
    }
    values.push(clientId);
    if (body.email) {
      const owner = await emailOwner(pool, body.email, clientId);
      if (owner) alreadyUsed(owner.display_name);
    }

    try {
      const dto = await withTransaction(async (db) => {
        const before = await loadClient(db, clientId, true);
        if (!before) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
        await db.query(`UPDATE clients SET ${sets.join(', ')} WHERE id = $${values.length}`, values);
        if (body.isActive === false) {
          await revokeAllSessions(db, 'client', clientId);
          await db.query(
            `UPDATE client_login_codes SET revoked_at = now()
              WHERE client_id = $1 AND used_at IS NULL AND revoked_at IS NULL`,
            [clientId]
          );
        }
        const after = toDto((await loadClient(db, clientId))!);
        await writeAudit(db, {
          actorType: 'admin',
          actorId: adminId,
          action: 'client.update',
          entityType: 'client',
          entityId: clientId,
          before: toDto(before),
          after
        });
        return after;
      });
      res.json(dto);
    } catch (e) {
      mapDbError(e);
    }
  })
);

// Issue a new login code (new phone, lost phone, expired code). Replaces any unused code.
// When the client uses the new code, their old phone is signed out (one phone per client).
adminClientsRouter.post(
  '/:clientId/login-code',
  asyncHandler(async (req, res) => {
    const clientId = idParam.parse(req.params.clientId);
    const body = codeSchema.parse(req.body ?? {});
    const adminId = req.auth!.id;
    const out = await withTransaction(async (db) => {
      const client = await loadClient(db, clientId, true);
      if (!client) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
      if (!client.is_active) throw new HttpError(409, 'CLIENT_INACTIVE', 'Reactivate the client before issuing a code.');
      const issued = await issueLoginCode(db, clientId, adminId, body.expiresInHours ?? config.LOGIN_CODE_TTL_HOURS);
      return { loginCode: issued.code, loginCodeExpiresAt: issued.expiresAt };
    });
    res.json(out);
  })
);

// Renew / extend a plan. Adds 1 month (basic) or 3 months (pro) to whichever is later:
// today, or the current end date (so paying early never loses days).
adminClientsRouter.post(
  '/:clientId/extend',
  asyncHandler(async (req, res) => {
    const clientId = idParam.parse(req.params.clientId);
    const body = z.object({ plan: planField }).strict().parse(req.body ?? {});
    const adminId = req.auth!.id;
    const client = await withTransaction(async (db) => {
      const before = await loadClient(db, clientId, true);
      if (!before) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
      await db.query(
        `UPDATE clients SET plan = $2, access_until = GREATEST(now(), COALESCE(access_until, now())) + $3::interval WHERE id = $1`,
        [clientId, body.plan, PLAN_INTERVAL[body.plan]]
      );
      const after = (await loadClient(db, clientId))!;
      await writeAudit(db, {
        actorType: 'admin',
        actorId: adminId,
        action: 'client.extend',
        entityType: 'client',
        entityId: clientId,
        before: { plan: before.plan, accessUntil: before.access_until },
        after: { plan: after.plan, accessUntil: after.access_until }
      });
      return toDto(after);
    });
    res.json(client);
  })
);

// Move the regular expiry earlier while keeping the plan and any test override.
adminClientsRouter.post(
  '/:clientId/shorten',
  asyncHandler(async (req, res) => {
    const id = idParam.parse(req.params.clientId);
    const { accessUntil } = z.object({
      accessUntil: z.string().datetime({ offset: true }).refine((value) => Number.isFinite(Date.parse(value)))
    }).strict().parse(req.body);
    const requestedExpiry = new Date(accessUntil);
    const result = await withTransaction(async (db) => {
      const before = await loadClient(db, id, true);
      if (!before) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
      if (!before.access_until || requestedExpiry >= before.access_until) {
        throw new HttpError(409, 'EXPIRY_NOT_EARLIER', 'Choose a date and time earlier than the current regular expiry.');
      }
      await db.query('UPDATE clients SET access_until = $2 WHERE id = $1', [id, requestedExpiry]);
      const after = (await loadClient(db, id))!;
      await writeAudit(db, {
        actorType: 'admin',
        actorId: req.auth!.id,
        action: 'client.shorten',
        entityType: 'client',
        entityId: id,
        before: { accessUntil: before.access_until },
        after: { accessUntil: after.access_until }
      });
      return toDto(after);
    });
    res.json(result);
  })
);

// A reversible override for testing plan expiry without changing the paid expiry.
adminClientsRouter.patch(
  '/:clientId/test-expiry',
  asyncHandler(async (req, res) => {
    if (config.ENABLE_TEST_EXPIRY_EDIT !== 'true') {
      throw new HttpError(404, 'NOT_FOUND', 'Test expiry editing is disabled.');
    }
    const id = idParam.parse(req.params.clientId);
    const { accessUntil } = z.object({ accessUntil: z.string().datetime({ offset: true }).nullable() }).strict().parse(req.body);
    const result = await withTransaction(async (db) => {
      const client = await loadClient(db, id, true);
      if (!client) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
      await db.query('UPDATE clients SET test_access_until = $2 WHERE id = $1', [id, accessUntil]);
      const updated = (await loadClient(db, id))!;
      await writeAudit(db, {
        actorType: 'admin',
        actorId: req.auth!.id,
        action: 'client.test_expiry',
        entityType: 'client',
        entityId: id,
        before: { testAccessUntil: client.test_access_until },
        after: { testAccessUntil: updated.test_access_until }
      });
      return toDto(updated);
    });
    res.json(result);
  })
);

// Sign the client out of every device (e.g. lost phone). Their ledger data is untouched.
adminClientsRouter.post(
  '/:clientId/sign-out',
  asyncHandler(async (req, res) => {
    const clientId = idParam.parse(req.params.clientId);
    const adminId = req.auth!.id;
    await withTransaction(async (db) => {
      if (!(await loadClient(db, clientId, true))) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
      await revokeAllSessions(db, 'client', clientId);
      await writeAudit(db, {
        actorType: 'admin',
        actorId: adminId,
        action: 'client.sign_out_all',
        entityType: 'client',
        entityId: clientId
      });
    });
    res.status(204).end();
  })
);
