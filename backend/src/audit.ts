import type { Db } from './db.js';

export interface AuditEntry {
  actorType: 'admin' | 'client' | 'system';
  actorId?: string | null;
  action: string;
  entityType: string;
  entityId?: string | null;
  before?: unknown;
  after?: unknown;
}

/** Write inside the same transaction as the change it describes. Never pass password hashes. */
export async function writeAudit(db: Db, e: AuditEntry): Promise<void> {
  await db.query(
    `INSERT INTO audit_logs (actor_type, actor_id, action, entity_type, entity_id, before_data, after_data)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      e.actorType,
      e.actorId ?? null,
      e.action,
      e.entityType,
      e.entityId ?? null,
      e.before === undefined ? null : JSON.stringify(e.before),
      e.after === undefined ? null : JSON.stringify(e.after)
    ]
  );
}
