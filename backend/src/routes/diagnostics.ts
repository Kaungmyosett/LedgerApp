import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { z } from 'zod';
import { pool } from '../db.js';
import { recordDiagnostic, recentDiagnostics } from '../diagnostics.js';
import type { Diagnostic } from '../diagnostics.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';

const loginActions = ['auth.login', 'auth.login_failed', 'auth.client_login', 'auth.client_login_failed', 'auth.client_login_expired'];

export const adminDiagnosticsRouter = Router();
adminDiagnosticsRouter.get('/', requireAuth('admin'), asyncHandler(async (req, res) => {
  const { category } = z.object({
    category: z.enum(['server', 'client', 'database', 'network', 'login']).optional()
  }).parse(req.query);
  const events = recentDiagnostics();
  if (category == null || category === 'login') {
    const { rows } = await pool.query<{ id: string; action: string; actor_id: string | null; created_at: Date }>(
      'SELECT id, action, COALESCE(actor_id, entity_id) AS actor_id, created_at FROM audit_logs WHERE action = ANY($1::text[]) ORDER BY created_at DESC, id DESC LIMIT 100',
      [loginActions]
    );
    for (const row of rows) {
      const client = row.action.startsWith('auth.client_');
      events.push({
        id: 'login-' + row.id, at: row.created_at.toISOString(), category: 'login',
        source: client ? 'client' : 'admin',
        operation: client ? '/v1/auth/client/login' : '/v1/auth/admin/login',
        code: row.action.endsWith('_expired') ? 'PLAN_EXPIRED' : row.action.endsWith('_failed') ? 'LOGIN_FAILED' : 'LOGIN_OK',
        ...(client && row.actor_id ? { clientId: row.actor_id } : {})
      } satisfies Diagnostic);
    }
  }
  const filtered = events.filter((event) => category == null || event.category === category)
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at)).slice(0, 100);
  const ids = [...new Set(filtered.flatMap((event) => event.clientId ? [event.clientId] : []))];
  const { rows: clients } = ids.length === 0 ? { rows: [] } : await pool.query<{ id: string; display_name: string }>(
    'SELECT id, display_name FROM clients WHERE id = ANY($1::uuid[])', [ids]
  );
  const names = new Map(clients.map((client) => [client.id, client.display_name]));
  res.json({ events: filtered.map((event) => ({
    ...event, ...(event.clientId ? { clientName: names.get(event.clientId) } : {})
  })) });
}));

const clientEvent = z.object({
  category: z.enum(['network', 'client']),
  operation: z.enum(['/v1/client/me', '/v1/client/ledger/sync', '/v1/client/ledger/snapshot', '/v1/auth/refresh']),
  code: z.enum(['TIMEOUT', 'CONNECTION_FAILED', 'HTTP_ERROR', 'INVALID_RESPONSE']),
  status: z.number().int().min(400).max(599).optional(),
  at: z.string().datetime()
}).strict();

export const clientDiagnosticsRouter = Router();
clientDiagnosticsRouter.post('/', rateLimit({
  windowMs: 60_000, limit: 20, keyGenerator: (req) => req.auth!.id, standardHeaders: 'draft-7', legacyHeaders: false,
}), asyncHandler(async (req, res) => {
  const { events } = z.object({ events: z.array(clientEvent).min(1).max(20) }).strict().parse(req.body);
  for (const event of events) {
    // Limit how far a device with a wrong clock can move a log entry.
    const at = Date.parse(event.at);
    const now = Date.now();
    recordDiagnostic({
      ...event, at: at < now - 7 * 86400000 || at > now ? new Date(now).toISOString() : event.at,
      source: 'client', clientId: req.auth!.id
    });
  }
  res.status(204).end();
}));
