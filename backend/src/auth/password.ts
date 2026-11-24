import argon2 from 'argon2';

// OWASP-recommended Argon2id parameters (19 MiB, 2 iterations, 1 lane).
const OPTIONS = { type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 } as const;

export function hashPassword(plain: string): Promise<string> {
  return argon2.hash(plain, OPTIONS);
}

export async function verifyPassword(hash: string, plain: string): Promise<boolean> {
  try {
    return await argon2.verify(hash, plain);
  } catch {
    return false;
  }
}

/** Verified against when an account does not exist, so response time does not reveal it. */
export const dummyHash: Promise<string> = hashPassword('not-a-real-password-for-timing');
