import 'dart:math';

/// Shared customer phone, ID, UPI VPA, and reference ID helpers.
/// Eliminates length-based substring slicing bugs across auth, cart, and API calls.
class PhoneNormalizer {
  PhoneNormalizer._();

  static final Random _random = Random();
  static int _refCounter = 0;

  static final RegExp _upiVpaPattern = RegExp(
    r'^[a-zA-Z0-9._\-]{2,256}@[a-zA-Z0-9]{2,64}$',
  );

  /// Extracts digits and returns the trailing 10 digits when available.
  static String cleanPhone10(String? raw) {
    final digits = (raw ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  /// Canonical backend customer ID (`c-XXXXXXXXXX`) when phone digits exist.
  static String toCustomerId(String? raw) {
    final trimmed = (raw ?? '').trim();
    final digits = cleanPhone10(trimmed);
    if (digits.isNotEmpty) {
      return 'c-$digits';
    }
    if (trimmed.startsWith('c-') && trimmed.length > 2) {
      return trimmed;
    }
    return '';
  }

  /// Displays `+91 XXXXXXXXXX` without double-prefixing `+91` or `91`.
  static String formatIndianPhone(String? raw) {
    final trimmed = (raw ?? '').trim();
    final digits = cleanPhone10(trimmed);
    if (digits.length == 10) {
      return '+91 $digits';
    }
    if (trimmed.startsWith('+91')) {
      return trimmed;
    }
    return digits.isNotEmpty ? '+91 $digits' : trimmed;
  }

  /// Validates syntactic UPI VPA format (`handle@psp`).
  static bool isValidUpiVpaFormat(String? vpa) {
    final cleaned = (vpa ?? '').trim();
    if (cleaned.isEmpty || cleaned.contains(' ')) return false;
    return _upiVpaPattern.hasMatch(cleaned);
  }

  /// Generates collision-resistant client reference IDs (no 6-digit ms truncation).
  static String generateUniqueRef(String prefix) {
    _refCounter = (_refCounter + 1) % 10000;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final suffix = _random.nextInt(9000) + 1000;
    final counter = _refCounter.toString().padLeft(4, '0');
    return '$prefix-$ts-$counter$suffix';
  }
}
