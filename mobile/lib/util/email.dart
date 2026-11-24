// Same rule as the server (backend/src/util/phone.ts normalizeEmail).
final _emailRe = RegExp(r'^[a-z0-9_%+-]+(?:\.[a-z0-9_%+-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$');

/// Lower-cased, trimmed email, or null when the format is not valid.
String? normalizeEmail(String input) {
  final s = input.trim().toLowerCase();
  if (s.length > 254 || !_emailRe.hasMatch(s)) return null;
  if (s.split('@').first.length > 64) return null;
  return s;
}
