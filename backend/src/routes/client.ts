import { Router } from 'express';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';
import { HttpError } from '../util/errors.js';
import { ledgerRouter } from './ledger.js';

export const clientRouter = Router();
clientRouter.use(requireAuth('client'));
// The ledger needs an active plan (basic = 1 month, pro = 3 months). /me stays open so the app can show the end date.
const requireActivePlan = asyncHandler(async (req, _res, next) => {
  const { rows } = await pool.query<{ ok: boolean | null }>('SELECT access_until > now() AS ok FROM clients WHERE id = $1', [req.auth!.id]);
  if (!rows[0]?.ok) throw new HttpError(403, 'PLAN_EXPIRED', 'Your plan has ended. Please contact the Admin to renew.');
  next();
});
clientRouter.use('/ledger', requireActivePlan, ledgerRouter);

// The client ID always comes from the verified token (req.auth.id), never from the URL or body.
// Every ledger route added later must also filter by req.auth.id (client_id) so clients can
// never see each other's data.
clientRouter.get(
  '/me',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query('SELECT id, display_name, email, plan, access_until FROM clients WHERE id = $1', [req.auth!.id]);
    const r = rows[0];
    if (!r) throw new HttpError(404, 'CLIENT_NOT_FOUND', 'Client not found.');
    res.json({ id: r.id, displayName: r.display_name, email: r.email, plan: r.plan, accessUntil: r.access_until });
  })
);
