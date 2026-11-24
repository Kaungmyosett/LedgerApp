import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';

/** 6-digit one-time login code, e.g. "042917". Uses a cryptographically secure generator. */
export function generateLoginCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

/** Keyed hash bound to the client, so the same digits give a different hash for every client. */
export function hashLoginCode(secret: string, clientId: string, code: string): string {
  return createHmac('sha256', secret).update(`${clientId}:${code}`).digest('hex');
}

export function hashesEqual(a: string, b: string): boolean {
  const x = Buffer.from(a, 'hex');
  const y = Buffer.from(b, 'hex');
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Accepts "123456", "123 456", "123-456". Returns null unless exactly 6 digits remain. */
export function cleanLoginCode(input: string): string | null {
  const digits = input.replace(/[\s-]/g, '');
  return /^\d{6}$/.test(digits) ? digits : null;
}
