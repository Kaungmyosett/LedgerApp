import { createHash, randomBytes } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { config } from '../config.js';

export type Role = 'admin' | 'client';
const ISSUER = '2d-ledger-api';

export function signAccessToken(accountId: string, role: Role, sessionVersion: number): string {
  return jwt.sign({ role, sv: sessionVersion }, config.JWT_SECRET, {
    algorithm: 'HS256',
    subject: accountId,
    issuer: ISSUER,
    expiresIn: config.ACCESS_TOKEN_TTL_SECONDS
  });
}

export function verifyAccessToken(token: string): { id: string; role: Role; sv: number } | null {
  try {
    const p = jwt.verify(token, config.JWT_SECRET, { algorithms: ['HS256'], issuer: ISSUER });
    if (typeof p === 'string' || typeof p.sub !== 'string') return null;
    if (p.role !== 'admin' && p.role !== 'client') return null;
    if (typeof p.sv !== 'number') return null;
    return { id: p.sub, role: p.role, sv: p.sv };
  } catch {
    return null;
  }
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export function generateRefreshToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: hashToken(token) };
}
