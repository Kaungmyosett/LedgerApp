import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { config } from './config.js';
import { pool } from './db.js';
import { errorHandler, notFound } from './middleware/errors.js';
import { adminClientsRouter } from './routes/adminClients.js';
import { authRouter } from './routes/auth.js';
import { clientRouter } from './routes/client.js';

export function createApp() {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.TRUST_PROXY);
  app.use(helmet());
  app.use(express.json({ limit: '2mb' }));

  app.get('/health', async (_req, res) => {
    try {
      await pool.query('SELECT 1');
      res.json({ ok: true, service: '2d-ledger-api', database: 'connected' });
    } catch {
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
  app.use('/v1/admin/clients', adminClientsRouter);
  app.use('/v1/client', clientRouter);

  app.use(notFound);
  app.use(errorHandler);
  return app;
}
