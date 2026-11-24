import type { Db } from '../db.js';
import { config } from '../config.js';
import { generateRefreshToken, signAccessToken, type Role } from './tokens.js';

export const ACCOUNT_TABLE = { admin: 'admin_accounts', client: 'clients' } as const;

export interface Session {
  accessToken: string;
  accessTokenExpiresInSeconds: number;
  refreshToken: string;
  refreshTokenExpiresAt: string;
}

export async function issueSession(db: Db, role: Role, accountId: string, userAgent?: string): Promise<Session> {
  const refresh = generateRefreshToken();
  const ver = await db.query<{ session_version: number }>(
    `SELECT session_version FROM ${ACCOUNT_TABLE[role]} WHERE id = $1`,
    [accountId]
  );
  const expiresAt = new Date(Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 86_400_000);
  await db.query(
    `INSERT INTO refresh_tokens (account_type, account_id, token_hash, user_agent, expires_at)
     VALUES ($1, $2, $3, $4, $5)`,
    [role, accountId, refresh.hash, userAgent?.slice(0, 255) ?? null, expiresAt]
  );
  return {
    accessToken: signAccessToken(accountId, role, ver.rows[0]?.session_version ?? 0),
    accessTokenExpiresInSeconds: config.ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: refresh.token,
    refreshTokenExpiresAt: expiresAt.toISOString()
  };
}

/** Signs the account out everywhere: refresh tokens are revoked and old access tokens stop working immediately. */
export async function revokeAllSessions(db: Db, role: Role, accountId: string): Promise<void> {
  await db.query(`UPDATE ${ACCOUNT_TABLE[role]} SET session_version = session_version + 1 WHERE id = $1`, [accountId]);
  await db.query(
    `UPDATE refresh_tokens SET revoked_at = now()
     WHERE account_type = $1 AND account_id = $2 AND revoked_at IS NULL`,
    [role, accountId]
  );
}
