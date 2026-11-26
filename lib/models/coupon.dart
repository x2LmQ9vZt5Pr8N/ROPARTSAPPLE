enum CouponDiscountType {
  percentage,
  flatAmount,
}

class Coupon {
  final String code;
  final String title;
  final String description;
  final CouponDiscountType type;
  final double discountValue;
  final double minOrderValue;
  final double? maxDiscount;
  final bool isExhausted;
  final int perUserLimit;
  final int userUsedCount;

  const Coupon({
    required this.code,
    required this.title,
    required this.description,
    required this.type,
    required this.discountValue,
    this.minOrderValue = 0,
    this.maxDiscount,
    this.isExhausted = false,
    this.perUserLimit = 1,
    this.userUsedCount = 0,
  });

  static double _toDouble(dynamic val, [double fallback = 0.0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? fallback;
  }

  static int _toInt(dynamic val, [int fallback = 0]) {
    if (val == null) return fallback;
    if (val is int) return val;
    if (val is num) return val.toInt();
    return int.tryParse(val.toString()) ?? fallback;
  }

  factory Coupon.fromJson(Map<String, dynamic> json) {
    final rawType = (json['discount_type'] ?? 'PERCENTAGE').toString().trim().toUpperCase();
    final type = rawType == 'PERCENTAGE'
        ? CouponDiscountType.percentage
        : CouponDiscountType.flatAmount;
    final val = _toDouble(json['discount_value']);
    final code = (json['code'] ?? '').toString().trim().toUpperCase();
    final desc = (json['description'] ?? '').toString().trim();
    final defaultTitle = type == CouponDiscountType.percentage
        ? '${val.toStringAsFixed(val.truncateToDouble() == val ? 0 : 1)}% OFF'
        : 'Flat ₹${val.toStringAsFixed(0)} OFF';

    return Coupon(
      code: code,
      title: defaultTitle,
      description: desc.isNotEmpty ? desc : defaultTitle,
      type: type,
      discountValue: val,
      minOrderValue: _toDouble(json['min_order_value']),
      maxDiscount: json['max_discount_cap'] != null ? _toDouble(json['max_discount_cap']) : null,
      isExhausted: json['is_exhausted'] == true,
      perUserLimit: _toInt(json['per_user_limit'], 1),
      userUsedCount: _toInt(json['user_used_count'], 0),
    );
  }

  /// Calculates estimated discount given the cart subtotal in Rupees (authoritative check always runs on server)
  int calculateDiscount(int subtotal) {
    if (subtotal < minOrderValue) return 0;

    double calculated;
    if (type == CouponDiscountType.percentage) {
      calculated = (subtotal * discountValue) / 100.0;
      if (maxDiscount != null && calculated > maxDiscount!) {
        calculated = maxDiscount!;
      }
    } else {
      calculated = discountValue;
      if (calculated > subtotal) {
        calculated = subtotal.toDouble();
      }
    }

    return calculated.round();
  }
}
