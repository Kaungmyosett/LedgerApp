import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { ZodError } from 'zod';
import { HttpError } from '../util/errors.js';
import { databaseError, diagnosticOperation, errorCode, recordDiagnostic } from '../diagnostics.js';

export const asyncHandler =
  (fn: (req: Request, res: Response, next: NextFunction) => Promise<unknown>): RequestHandler =>
  (req, res, next) => {
    fn(req, res, next).catch(next);
  };

export function notFound(_req: Request, res: Response): void {
  res.status(404).json({ error: 'NOT_FOUND' });
}

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
  if (err instanceof HttpError) {
    res.locals.diagnosticRecorded = true;
    recordDiagnostic({
      category: _req.auth?.role === 'client' ? 'client' : 'server',
      source: 'server', operation: diagnosticOperation(_req.originalUrl.split('?')[0]!),
      code: errorCode(err) ?? 'HTTP_' + err.status, status: err.status,
      ...(_req.auth?.role === 'client' ? { clientId: _req.auth.id } : {})
    });
    res.status(err.status).json({ error: err.code, message: err.message, details: err.details });
    return;
  }
  if (err instanceof ZodError) {
    res.status(400).json({
      error: 'VALIDATION_ERROR',
      details: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message }))
    });
    return;
  }
  if (typeof err === 'object' && err !== null && (err as { type?: string }).type === 'entity.parse.failed') {
    res.status(400).json({ error: 'INVALID_JSON' });
    return;
  }
  res.locals.diagnosticRecorded = true;
  recordDiagnostic({
    category: databaseError(err) ? 'database' : 'server',
    source: 'server', operation: diagnosticOperation(_req.originalUrl.split('?')[0]!),
    code: errorCode(err) ?? 'INTERNAL_SERVER_ERROR', status: 500,
    ...(_req.auth?.role === 'client' ? { clientId: _req.auth.id } : {})
  });
  console.error(err);
  res.status(500).json({ error: 'INTERNAL_SERVER_ERROR' });
}
