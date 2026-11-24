import { pool, withTransaction } from '../db.js';
import { writeAudit } from '../audit.js';
import { hashPassword } from '../auth/password.js';
import { revokeAllSessions } from '../auth/session.js';
import { normalizePhone } from '../util/phone.js';

// Forgot the Admin password, or the account is locked after wrong tries? Run on the server computer:
//   ADMIN_PASSWORD="new-password-12+chars" npm run reset-admin-password
// Optionally also change the login phone:  ADMIN_PHONE="09xxxxxxxxx"
// Unlocks the account and signs the Admin out of all devices. Client accounts and ledgers are not touched.
async function main(): Promise<void> {
  const password = process.env.ADMIN_PASSWORD ?? '';
  if (password.length < 12) throw new Error('ADMIN_PASSWORD must be at least 12 characters');
  const rawPhone = process.env.ADMIN_PHONE?.trim();
  const phone = rawPhone ? normalizePhone(rawPhone) : null;
  if (rawPhone && !phone) throw new Error('ADMIN_PHONE is not a valid phone number');

  const hash = await hashPassword(password);
  const admin = await withTransaction(async (db) => {
    const { rows } = await db.query<{ id: string; phone_e164: string }>(
      `UPDATE admin_accounts
          SET password_hash = $1, phone_e164 = COALESCE($2, phone_e164), failed_login_count = 0, locked_until = NULL,
              is_active = TRUE, password_changed_at = now()
        RETURNING id, phone_e164`,
      [hash, phone]
    );
    if (!rows[0]) throw new Error('No Admin account yet. Create one with: npm run create-admin');
    await revokeAllSessions(db, 'admin', rows[0].id);
    await writeAudit(db, { actorType: 'system', action: 'admin.password_reset', entityType: 'admin', entityId: rows[0].id, after: { phone: rows[0].phone_e164 } });
    return rows[0];
  });
  console.log(`Admin password reset and account unlocked. Log in with phone ${admin.phone_e164}.`);
}

main()
  .catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
