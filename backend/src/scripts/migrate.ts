import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { pool } from '../db.js';

// Works from both src/scripts (tsx) and dist/scripts (compiled): ../../../database
const dir = fileURLToPath(new URL('../../../database/', import.meta.url));

async function main(): Promise<void> {
  await pool.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`);

  const files = (await readdir(dir)).filter((f) => /^\d+_.+\.sql$/.test(f)).sort();
  const applied = new Set((await pool.query<{ filename: string }>('SELECT filename FROM schema_migrations')).rows.map((r) => r.filename));

  // If 001 was applied by hand with psql (per the old README), record it instead of re-running it.
  if (applied.size === 0) {
    const exists = await pool.query(`SELECT to_regclass('public.admin_accounts') AS t`);
    if (exists.rows[0]?.t && files[0]) {
      await pool.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [files[0]]);
      applied.add(files[0]);
      console.log(`Recorded ${files[0]} as already applied.`);
    }
  }

  for (const file of files) {
    if (applied.has(file)) continue;
    console.log(`Applying ${file} ...`);
    await pool.query(await readFile(dir + file, 'utf8')); // each file manages its own BEGIN/COMMIT
    await pool.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [file]);
  }
  console.log('Migrations up to date.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
