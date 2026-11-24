import pg from 'pg';
import { config } from './config.js';

export const pool = new pg.Pool({ connectionString: config.DATABASE_URL, max: 10 });

/** Minimal query interface satisfied by both Pool and PoolClient. */
export interface Db {
  query<R extends pg.QueryResultRow = any>(text: string, params?: unknown[]): Promise<pg.QueryResult<R>>;
}

export async function withTransaction<T>(fn: (db: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* ignore rollback failure; original error matters more */
    }
    throw err;
  } finally {
    client.release();
  }
}

export function isPgError(e: unknown): e is { code: string; constraint?: string } {
  return typeof e === 'object' && e !== null && 'code' in e && typeof (e as { code: unknown }).code === 'string';
}
