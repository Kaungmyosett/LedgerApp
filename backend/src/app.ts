import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { config } from './config.js';
import { pool } from './db.js';
import { errorHandler, notFound } from './middleware/errors.js';
import { adminClientsRouter } from './routes/adminClients.js';
import { authRouter } from './routes/auth.js';
import { clientRouter } from './routes/client.js';
import { diagnosticOperation, errorCode, recordDiagnostic } from './diagnostics.js';
import { adminDiagnosticsRouter } from './routes/diagnostics.js';

export function createApp() {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.TRUST_PROXY);
  app.use(helmet());
  app.use((req, res, next) => {
    const operation = diagnosticOperation(req.path);
    req.once('aborted', () => recordDiagnostic({
      category: 'network', source: 'server', operation, code: 'REQUEST_ABORTED'
    }));
    res.once('finish', () => {
      if (res.statusCode < 400 || res.locals.diagnosticRecorded || operation === 'other') return;
      recordDiagnostic({
        category: res.statusCode < 500 && req.auth?.role === 'client' ? 'client' : 'server',
        source: 'server', operation, code: 'HTTP_' + res.statusCode, status: res.statusCode,
        ...(req.auth?.role === 'client' ? { clientId: req.auth.id } : {})
      });
    });
    next();
  });
  app.use(express.json({ limit: '2mb' }));

  app.get('/health', async (_req, res) => {
    try {
      await pool.query('SELECT 1');
      res.json({ ok: true, service: '2d-ledger-api', database: 'connected' });
    } catch (error) {
      res.locals.diagnosticRecorded = true;
      recordDiagnostic({ category: 'database', source: 'server', operation: '/health', code: errorCode(error) ?? 'DATABASE_UNAVAILABLE', status: 503 });
      res.status(503).json({ ok: false, service: '2d-ledger-api', database: 'unavailable' });
    }
  });

  app.get('/v1', (_req, res) => {
    res.json({ name: '2D Ledger API', version: '0.7.0', status: 'auth-and-ledger' });
  });

  // Per-IP throttle on every auth endpoint, on top of per-account lockout.
  const authLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 30,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'RATE_LIMITED' }
  });

  app.use('/v1/auth', authLimiter, authRouter);
  app.use('/v1/admin/diagnostics', adminDiagnosticsRouter);
  app.use('/v1/admin/clients', adminClientsRouter);
  app.use('/v1/client', clientRouter);

  app.use(notFound);
  app.use(errorHandler);
  return app;
}
