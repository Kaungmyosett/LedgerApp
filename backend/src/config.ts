import 'dotenv/config';
import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  DATABASE_URL: z.string().min(1),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET must be at least 32 characters'),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),
  MAX_FAILED_LOGINS: z.coerce.number().int().positive().default(5),
  LOCKOUT_MINUTES: z.coerce.number().int().positive().default(15),
  LOGIN_CODE_TTL_HOURS: z.coerce.number().int().min(1).max(168).default(24),
  ENABLE_TEST_EXPIRY_EDIT: z.enum(['true', 'false']).default('false'),
  TRUST_PROXY: z.coerce.number().int().min(0).default(0)
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  console.error('Invalid environment configuration:');
  for (const issue of parsed.error.issues) {
    console.error(` - ${issue.path.join('.')}: ${issue.message}`);
  }
  process.exit(1);
}
if (parsed.data.NODE_ENV === 'production' && parsed.data.JWT_SECRET.includes('replace-with')) {
  console.error('Refusing to start in production with the example JWT_SECRET.');
  process.exit(1);
}

export const config = parsed.data;
