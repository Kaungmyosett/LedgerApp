import { randomUUID } from 'node:crypto';

export interface Diagnostic {
  id: string;
  at: string;
  category: 'server' | 'client' | 'database' | 'network' | 'login';
  source: 'server' | 'client' | 'admin';
  operation: string;
  code: string;
  status?: number;
  clientId?: string;
}

const recent: Diagnostic[] = [];

export function recordDiagnostic(event: Omit<Diagnostic, 'id' | 'at'> & { at?: string }) {
  recent.push({ id: randomUUID(), at: new Date().toISOString(), ...event });
  if (recent.length > 250) recent.shift();
}

export function recentDiagnostics() {
  return [...recent];
}

export function errorCode(error: unknown): string | undefined {
  if (error == null || typeof error !== 'object' || !('code' in error)) return undefined;
  return typeof error.code === 'string' && /^[A-Z0-9_]{1,48}$/.test(error.code)
    ? error.code
    : undefined;
}

export function databaseError(error: unknown): boolean {
  const code = errorCode(error);
  return code != null && (/^[0-9A-Z]{5}$/.test(code) ||
    ['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'EAI_AGAIN'].includes(code));
}

// Operation names come from a fixed allowlist. Never give diagnostics raw URLs,
// SQL statements, exception messages, request headers or payloads.
export function diagnosticOperation(path: string): string {
  if (/^\/v1\/admin\/clients\/[0-9a-f-]{36}(?:\/(?:extend|shorten|test-expiry|sign-out|login-code))?$/i.test(path)) {
    return path.replace(/[0-9a-f-]{36}/i, ':id');
  }
  const known = [
    '/health', '/v1/admin/clients', '/v1/admin/diagnostics',
    '/v1/client/me', '/v1/client/diagnostics',
    '/v1/client/ledger/snapshot', '/v1/client/ledger/sync',
    '/v1/auth/admin/login', '/v1/auth/client/login',
    '/v1/auth/admin/change-password', '/v1/auth/refresh', '/v1/auth/logout',
  ];
  return known.includes(path) ? path : 'other';
}
