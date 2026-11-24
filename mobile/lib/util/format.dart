import '../api/api_client.dart';

String describeError(Object e) {
  if (e is ApiException) {
    if (e.details.isNotEmpty) return e.details.join('\n');
    return e.message;
  }
  if (e is NetworkException) return e.toString();
  return 'Something went wrong. Please try again.';
}

/// "2026-11-19 14:05" in the phone's local time.
String formatDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// "042917" -> "042 917" for easy reading aloud.
String spaceCode(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
