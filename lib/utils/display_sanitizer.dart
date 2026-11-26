/// Privacy & UI helpers ensuring internal staff/customer/visit identifiers
/// (such as `ro-8431801834`, `c-9876543210`, or raw 10-digit phones) are never
/// surfaced in customer-facing text.
class DisplaySanitizer {
  DisplaySanitizer._();

  static final RegExp _internalIdRegex = RegExp(r'^(?:ro|c)-\d+$', caseSensitive: false);
  static final RegExp _rawPhoneRegex = RegExp(r'^\+?\d{10,13}$');
  static final RegExp _inlineParenIdRegex = RegExp(r'\s*\((?:ro|c)-\d+\)', caseSensitive: false);
  static final RegExp _inlineTokenIdRegex = RegExp(r'\b(?:ro|c)-\d+\b', caseSensitive: false);

  static bool isInternalOrPhoneId(String? raw) {
    if (raw == null) return false;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return false;
    return _internalIdRegex.hasMatch(trimmed) || _rawPhoneRegex.hasMatch(trimmed);
  }

  static String technicianName(
    String? raw, {
    String fallback = 'Assigned Technician',
  }) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty || isInternalOrPhoneId(trimmed)) {
      return fallback;
    }
    return trimmed;
  }

  static String sanitizeErrorMessage(
    String? raw, {
    String fallback = 'Unable to verify item right now. Please retry.',
  }) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return fallback;
    final stripped = trimmed
        .replaceAll(_inlineParenIdRegex, '')
        .replaceAll(_inlineTokenIdRegex, 'assigned technician')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return stripped.isEmpty ? fallback : stripped;
  }
}

