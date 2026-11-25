import { Router } from 'express';
import { pool } from '../db.js';
import { recordDiagnostic } from '../diagnostics.js';
import { applyBatch, syncBodySchema } from '../ledger/ops.js';
import { loadSnapshot } from '../ledger/snapshot.js';
import { asyncHandler } from '../middleware/errors.js';

// Mounted under /v1/client/ledger after requireAuth('client').
// The client id ALWAYS comes from the verified token (req.auth.id): a client can only ever touch its own ledger.
export const ledgerRouter = Router();

// Full copy of the client's ledger. The app replaces its local copy with this after a successful sync.
ledgerRouter.get(
  '/snapshot',
  asyncHandler(async (req, res) => {
    res.json(await loadSnapshot(pool, req.auth!.id));
  })
);

// Applies queued offline operations in order. Each has a client-generated id, so re-sending is always safe.
ledgerRouter.post(
  '/sync',
  asyncHandler(async (req, res) => {
    const { ops } = syncBodySchema.parse(req.body);
    const clientId = req.auth!.id;
    const results = await applyBatch(clientId, ops);
    const codes = new Set(results.filter((result) => result.status === 'error').map((result) => result.code));
    for (const code of [...codes].slice(0, 10)) {
      if (code) recordDiagnostic({ category: 'client', source: 'server', operation: '/v1/client/ledger/sync', code, clientId });
    }
    res.json({ results });
  })
);
