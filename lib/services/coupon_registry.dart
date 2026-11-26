/// Utility for normalizing scanned QR/URL/text coupon payloads.
/// All promotional rules, eligibility, and discounts come strictly from backend DB APIs.
class CouponRegistry {
  /// Extracts a clean uppercase coupon code from a raw QR payload, deep link URL, or typed string.
  static String? normalizeScannedCode(String rawInput) {
    var cleaned = rawInput.trim();
    if (cleaned.isEmpty) return null;

    final uri = Uri.tryParse(cleaned);
    if (uri != null && uri.queryParameters.containsKey('code')) {
      cleaned = uri.queryParameters['code']!;
    } else if (uri != null && uri.queryParameters.containsKey('coupon')) {
      cleaned = uri.queryParameters['coupon']!;
    } else if (cleaned.toUpperCase().startsWith('COUPON:')) {
      cleaned = cleaned.substring(7).trim();
    } else if (cleaned.toUpperCase().startsWith('VOUCHER:')) {
      cleaned = cleaned.substring(8).trim();
    } else if (cleaned.toUpperCase().startsWith('PROMO:')) {
      cleaned = cleaned.substring(6).trim();
    }

    final upper = cleaned.toUpperCase();
    if (upper.isEmpty || upper.length > 40) return null;
    if (!RegExp(r'^[A-Z0-9_-]+$').hasMatch(upper)) return null;
    return upper;
  }

  /// Returns true if raw QR/barcode payload explicitly carries a coupon/voucher prefix or query param.
  static bool isExplicitCouponPayload(String rawInput) {
    final cleaned = rawInput.trim();
    if (cleaned.isEmpty) return false;
    final upper = cleaned.toUpperCase();
    if (upper.startsWith('COUPON:') ||
        upper.startsWith('VOUCHER:') ||
        upper.startsWith('PROMO:')) {
      return true;
    }
    final uri = Uri.tryParse(cleaned);
    return uri != null &&
        (uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('coupon'));
  }
}
