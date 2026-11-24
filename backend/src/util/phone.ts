/**
 * Normalize a phone number to E.164. Numbers without a country code are
 * assumed to be Myanmar (+95). Returns null when the input is not a plausible number.
 */
export function normalizePhone(input: string): string | null {
  let s = input.trim().replace(/[\s\-().]/g, '');
  if (s === '') return null;
  if (s.startsWith('00')) s = '+' + s.slice(2);

  if (s.startsWith('+950')) {
    s = '+95' + s.slice(4); // +95 09xxxxxxx -> +959xxxxxxx (stray trunk zero)
  } else if (s.startsWith('+')) {
    // already international
  } else if (s.startsWith('0')) {
    s = '+95' + s.slice(1); // 09xxxxxxxxx
  } else if (s.startsWith('95')) {
    s = '+' + s; // 959xxxxxxxxx
  } else if (s.startsWith('9')) {
    s = '+95' + s; // 9xxxxxxxxx
  } else {
    return null;
  }
  return /^\+[1-9][0-9]{7,14}$/.test(s) ? s : null;
}

// Practical email check (same rule in the app: mobile/lib/util/email.dart):
//   local part: letters, digits and . _ % + - ; no leading/trailing/double dot; max 64
//   domain: labels of letters/digits/hyphen (not at the ends), at least one dot, top-level domain of 2+ letters
const EMAIL_RE = /^[a-z0-9_%+-]+(?:\.[a-z0-9_%+-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$/;

export function normalizeEmail(input: string): string | null {
  const s = String(input ?? '').trim().toLowerCase();
  if (s.length > 254 || !EMAIL_RE.test(s)) return null;
  if (s.split('@')[0]!.length > 64) return null;
  return s;
}
