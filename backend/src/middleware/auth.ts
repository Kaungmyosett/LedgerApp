import type { RequestHandler } from 'express';
import { pool } from '../db.js';
import { ACCOUNT_TABLE } from '../auth/session.js';
import { verifyAccessToken, type Role } from '../auth/tokens.js';
import { asyncHandler } from './errors.js';
import { HttpError } from '../util/errors.js';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      /** Identity resolved on the server from the access token. Never read IDs from the body. */
      auth?: { id: string; role: Role };
    }
  }
}

export function requireAuth(role: Role): RequestHandler {
  return asyncHandler(async (req, _res, next) => {
    const header = req.get('authorization') ?? '';
    const match = /^Bearer (.+)$/.exec(header);
    const claims = match ? verifyAccessToken(match[1]!) : null;
    if (!claims) throw new HttpError(401, 'UNAUTHENTICATED', 'Missing or invalid access token.');
    if (claims.role !== role) throw new HttpError(403, 'FORBIDDEN', 'This account cannot use this endpoint.');

    // A deactivated account loses access immediately, not when the token expires.
    const { rows } = await pool.query<{ is_active: boolean; session_version: number }>(
      `SELECT is_active, session_version FROM ${ACCOUNT_TABLE[claims.role]} WHERE id = $1`,
      [claims.id]
    );
    if (!rows[0]?.is_active) throw new HttpError(401, 'UNAUTHENTICATED', 'Account is not active.');
    // Signed out elsewhere (e.g. the client logged in on a new phone): this token is dead.
    if (rows[0].session_version !== claims.sv) throw new HttpError(401, 'UNAUTHENTICATED', 'Signed out. Please log in again.');

    req.auth = claims;
    next();
  });
}
