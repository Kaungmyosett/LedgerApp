import { pool, isPgError, withTransaction } from '../db.js';
import { writeAudit } from '../audit.js';
import { hashPassword } from '../auth/password.js';
import { normalizePhone } from '../util/phone.js';

// Usage: ADMIN_NAME="Owner" ADMIN_PHONE="09xxxxxxxxx" ADMIN_PASSWORD="..." npm run create-admin
async function main(): Promise<void> {
  const name = process.env.ADMIN_NAME?.trim();
  const phone = normalizePhone(process.env.ADMIN_PHONE ?? '');
  const password = process.env.ADMIN_PASSWORD ?? '';
  if (!name) throw new Error('ADMIN_NAME is required');
  if (!phone) throw new Error('ADMIN_PHONE is missing or not a valid phone number');
  if (password.length < 12) throw new Error('ADMIN_PASSWORD must be at least 12 characters');

  const hash = await hashPassword(password);
  try {
    const id = await withTransaction(async (db) => {
      const { rows } = await db.query<{ id: string }>(
        'INSERT INTO admin_accounts (display_name, phone_e164, password_hash) VALUES ($1, $2, $3) RETURNING id',
        [name, phone, hash]
      );
      await writeAudit(db, {
        actorType: 'system',
        action: 'admin.create',
        entityType: 'admin',
        entityId: rows[0]!.id,
        after: { displayName: name, phone }
      });
      return rows[0]!.id;
    });
    console.log(`Admin created: ${id} (${phone})`);
  } catch (e) {
    if (isPgError(e) && e.code === '23505') {
      throw new Error('An admin account already exists. Only one Admin is allowed.');
    }
    throw e;
  }
}

main()
  .catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
