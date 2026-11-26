import 'dart:math' as math;

/// Immutable paise-exact price breakdown for doorstep spares checkout.
class DoorstepPriceBreakdown {
  final int mrpPaise;
  final int freeSparesPaise;
  final int maxDiscountPaise;
  final int effectiveDiscountPaise;
  final int netPayablePaise;

  const DoorstepPriceBreakdown({
    required this.mrpPaise,
    this.freeSparesPaise = 0,
    required this.maxDiscountPaise,
    required this.effectiveDiscountPaise,
    required this.netPayablePaise,
  });

  double get totalMrp => mrpPaise / 100.0;
  double get freeSparesMrp => freeSparesPaise / 100.0;
  double get maxDiscountAllowed => maxDiscountPaise / 100.0;
  double get effectiveDiscount => effectiveDiscountPaise / 100.0;
  double get netPayable => netPayablePaise / 100.0;

  bool get isZeroComplimentary =>
      mrpPaise == 0 && freeSparesPaise > 0 && netPayablePaise == 0;

  /// Razorpay INR orders require at least ₹1.00 (100 paise) unless settling ₹0 complimentary kit spares.
  bool get isBelowGatewayMinimum =>
      mrpPaise > 0 && netPayablePaise < DoorstepPricing.minGatewayPayablePaise;
}

class DoorstepFreeItemInput {
  final String? sku;
  final bool isKit;
  final double mrp;
  final int quantity;
  final List<Map<String, dynamic>> freeSpares;
  final bool sealedFreeSpares;
  final bool isExplicitComplimentary;

  const DoorstepFreeItemInput({
    this.sku,
    required this.isKit,
    required this.mrp,
    this.quantity = 1,
    this.freeSpares = const [],
    this.sealedFreeSpares = false,
    this.isExplicitComplimentary = false,
  });
}

class DoorstepFreeAllocation {
  final Set<int> complimentaryIndices;
  final double billableMrp;
  final double freeSparesMrp;

  const DoorstepFreeAllocation({
    required this.complimentaryIndices,
    required this.billableMrp,
    required this.freeSparesMrp,
  });

  bool isItemComplimentary(int index) => complimentaryIndices.contains(index);
}

/// Shared doorstep pricing & formatting calculator aligned with customer MRP = SUM(products).
class DoorstepPricing {
  static const int maxDiscountPercent = 85;
  static const int minGatewayPayablePaise = 100;

  /// Allocates kit-coupled complimentary free spares quotas across scanned bill items.
  static DoorstepFreeAllocation allocateFreeKitSpares(List<DoorstepFreeItemInput> items) {
    final quotaBySku = <String, int>{};
    for (final entry in items) {
      if (!entry.isKit || entry.sealedFreeSpares) continue;
      final kitQty = math.max(1, entry.quantity);
      for (final spare in entry.freeSpares) {
        final s = (spare['sku'] ?? spare['product_sku'] ?? '').toString().trim().toUpperCase();
        if (s.isEmpty) continue;
        final rawQ = int.tryParse((spare['qty'] ?? spare['quantity'] ?? '1').toString()) ?? 1;
        final q = rawQ > 0 ? rawQ : 1;
        quotaBySku[s] = (quotaBySku[s] ?? 0) + (q * kitQty);
      }
    }

    final complimentaryIndices = <int>{};
    int billablePaise = 0;
    int freePaise = 0;

    for (int i = 0; i < items.length; i++) {
      final entry = items[i];
      final lineQty = math.max(1, entry.quantity);
      final unitPaise = toPaise(entry.mrp);
      if (entry.isKit) {
        billablePaise += unitPaise * lineQty;
        continue;
      }

      final cleanSku = (entry.sku ?? '').trim().toUpperCase();
      final remQuota = cleanSku.isNotEmpty ? (quotaBySku[cleanSku] ?? 0) : 0;
      if (remQuota > 0) {
        final freeCount = math.min(lineQty, remQuota);
        final paidCount = lineQty - freeCount;
        quotaBySku[cleanSku] = remQuota - freeCount;
        freePaise += unitPaise * freeCount;
        billablePaise += unitPaise * paidCount;
        complimentaryIndices.add(i);
      } else if (entry.isExplicitComplimentary) {
        freePaise += unitPaise * lineQty;
        complimentaryIndices.add(i);
      } else {
        billablePaise += unitPaise * lineQty;
      }
    }

    return DoorstepFreeAllocation(
      complimentaryIndices: complimentaryIndices,
      billableMrp: billablePaise / 100.0,
      freeSparesMrp: freePaise / 100.0,
    );
  }

  /// Converts a rupee amount to non-negative whole paise.
  static int toPaise(double rupees) {
    if (!rupees.isFinite || rupees <= 0) return 0;
    return (rupees * 100).round();
  }

  /// Calculates breakdown using floored 85% max discount matching backend `floor2`.
  static DoorstepPriceBreakdown calculate({
    required double totalMrp,
    double couponDiscount = 0.0,
    double freeSparesMrp = 0.0,
  }) {
    final int mrpPaise = toPaise(totalMrp);
    final int freeSparesPaise = toPaise(freeSparesMrp);
    // Use integer truncation so frontend matches server Math.floor(mrp * 0.85 * 100).
    final int maxDiscountPaise = (mrpPaise * maxDiscountPercent) ~/ 100;
    final int requestedDiscountPaise = toPaise(couponDiscount);
    final int effectiveDiscountPaise = math.min(
      requestedDiscountPaise,
      math.min(maxDiscountPaise, mrpPaise),
    );
    final int netPayablePaise = math.max(
      0,
      mrpPaise - effectiveDiscountPaise,
    );

    return DoorstepPriceBreakdown(
      mrpPaise: mrpPaise,
      freeSparesPaise: freeSparesPaise,
      maxDiscountPaise: maxDiscountPaise,
      effectiveDiscountPaise: effectiveDiscountPaise,
      netPayablePaise: netPayablePaise,
    );
  }

  /// Formats rupee values without dropping fractional paise (e.g. 2 -> "2", 0.40 -> "0.40").
  static String formatRupees(double amount) {
    if (!amount.isFinite || amount <= 0) return '0';
    final int paise = (amount * 100).round();
    if (paise % 100 == 0) {
      return (paise ~/ 100).toString();
    }
    return (paise / 100.0).toStringAsFixed(2);
  }

  /// Explains gateway ₹1.00 minimum clearly when a valid coupon leaves sub-₹1 payable.
  static String belowGatewayMinimumMessage(double payable) {
    return 'Minimum ₹1.00 required for online payment (currently ₹${payable.toStringAsFixed(2)}). Remove coupon or add another item.';
  }
}

