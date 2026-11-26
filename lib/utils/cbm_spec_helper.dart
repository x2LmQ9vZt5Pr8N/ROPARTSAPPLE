import 'dart:convert';
import 'package:flutter/material.dart';

/// Parsed CBM lifecycle specification for a purchased or scanned spare/kit.
class CbmItemSpec {
  final String partNature;
  final bool? isConsumable;
  final int? shelfLifeLiters;
  final int? minShelfLifeLiters;
  final int? maxShelfLifeLiters;
  final double? warrantyYears;
  final double? minWarrantyYears;
  final double? maxWarrantyYears;
  final int? shelfLifeMonths;
  final String? natureLabel;
  final String? primaryRatingLabel;
  final String? shortBadge;

  const CbmItemSpec({
    required this.partNature,
    this.isConsumable,
    this.shelfLifeLiters,
    this.minShelfLifeLiters,
    this.maxShelfLifeLiters,
    this.warrantyYears,
    this.minWarrantyYears,
    this.maxWarrantyYears,
    this.shelfLifeMonths,
    this.natureLabel,
    this.primaryRatingLabel,
    this.shortBadge,
  });

  bool get hasSpec => primaryRatingLabel != null && primaryRatingLabel!.trim().isNotEmpty;

  Color get pillBackground {
    switch (partNature) {
      case 'CONSUMABLE':
        return const Color(0xFFE0F2FE);
      case 'NON_CONSUMABLE':
        return const Color(0xFFDCFCE7);
      case 'MIXED_KIT':
      case 'HYBRID':
        return const Color(0xFFF0FDFA);
      default:
        return const Color(0xFFF1F5F9);
    }
  }

  Color get pillForeground {
    switch (partNature) {
      case 'CONSUMABLE':
        return const Color(0xFF0369A1);
      case 'NON_CONSUMABLE':
        return const Color(0xFF15803D);
      case 'MIXED_KIT':
      case 'HYBRID':
        return const Color(0xFF0F766E);
      default:
        return const Color(0xFF475569);
    }
  }

  IconData get icon {
    if (partNature == 'CONSUMABLE') return Icons.water_drop_outlined;
    if (partNature == 'NON_CONSUMABLE') return Icons.verified_user_outlined;
    return Icons.inventory_2_outlined;
  }
}

/// Aggregated billing & spares summary for one service visit.
class VisitPurchaseSummary {
  final int ordersCount;
  final int itemsCount;
  final double baseMrpTotal;
  final double discountAmount;
  final double sparesPaidTotal;
  final List<String> couponCodes;
  final List<String> orderNumbers;
  final int consumableCount;
  final int nonConsumableCount;

  const VisitPurchaseSummary({
    required this.ordersCount,
    required this.itemsCount,
    required this.baseMrpTotal,
    required this.discountAmount,
    required this.sparesPaidTotal,
    required this.couponCodes,
    required this.orderNumbers,
    required this.consumableCount,
    required this.nonConsumableCount,
  });
}

class CbmSpecHelper {
  static double _toDouble(dynamic raw) {
    if (raw == null) return 0.0;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString().trim()) ?? 0.0;
  }

  static int? _toPositiveIntOrNull(dynamic raw) {
    if (raw == null) return null;
    final parsed = raw is num ? raw.toDouble() : double.tryParse(raw.toString().trim());
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed.round();
  }

  static double? _toPositiveDoubleOrNull(dynamic raw) {
    if (raw == null) return null;
    final parsed = raw is num ? raw.toDouble() : double.tryParse(raw.toString().trim());
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed;
  }

  /// Formats integer quantity using Indian comma grouping (e.g. 6,000 or 1,25,000).
  static String formatIndianInt(int value) {
    final absStr = value.abs().toString();
    if (absStr.length <= 3) return '${value < 0 ? '-' : ''}$absStr';
    final lastThree = absStr.substring(absStr.length - 3);
    final rest = absStr.substring(0, absStr.length - 3);
    final pairs = <String>[];
    for (int i = rest.length; i > 0; i -= 2) {
      final start = (i - 2) < 0 ? 0 : (i - 2);
      pairs.insert(0, rest.substring(start, i));
    }
    return '${value < 0 ? '-' : ''}${pairs.join(',')},$lastThree';
  }

  static String formatLiters(int liters) => '${formatIndianInt(liters)} Liters';

  static String formatYears(double years) {
    final rounded = years == years.roundToDouble() ? years.round() : years;
    return rounded == 1 ? '1 Year' : '$rounded Years';
  }

  static List<Map<String, dynamic>> extractChildComponents(Map<String, dynamic> item) {
    final raw = item['components'] ??
        item['components_breakdown'] ??
        item['rawComponents'] ??
        item['items'];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is List) {
          return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  /// Hides internal pouch packaging & complimentary entries from the paid customer component list.
  static bool isCustomerVisiblePaidComponent(Map<String, dynamic> comp) {
    final sku = (comp['sku'] ?? comp['product_sku'] ?? '').toString().toUpperCase();
    final name = (comp['item_name'] ?? comp['name'] ?? comp['product_name'] ?? '').toString().toLowerCase();
    return !sku.contains('POUCH') &&
        !name.contains('pouch') &&
        comp['is_packaging'] != true &&
        comp['is_complimentary'] != true;
  }

  /// Extracts sealed free spares included inside a kit pouch (`free_spares` / `free_spares_snapshot` / complimentary children).
  static List<Map<String, dynamic>> extractFreeSpares(Map<String, dynamic> item) {
    dynamic raw = item['free_spares'] ??
        item['freeSpares'] ??
        item['free_spares_snapshot'] ??
        item['free_spares_spec'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        raw = json.decode(raw);
      } catch (_) {}
    }

    final result = <Map<String, dynamic>>[];
    final seenKeys = <String>{};
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        result.add(m);
        final key = (m['component_qr'] ?? m['qr'] ?? m['sku'] ?? m['product_sku'] ?? '')
            .toString()
            .trim()
            .toUpperCase();
        if (key.isNotEmpty) seenKeys.add(key);
      }
    }

    for (final child in extractChildComponents(item)) {
      if (child['is_complimentary'] != true) continue;
      final key = (child['component_qr'] ?? child['qr'] ?? child['sku'] ?? child['product_sku'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      if (key.isNotEmpty && seenKeys.contains(key)) continue;
      if (key.isNotEmpty) seenKeys.add(key);
      result.add(child);
    }

    return result;
  }

  /// Resolves authentic CBM Consumable vs Non-Consumable specs for an item or kit.
  /// Never invents hardcoded `12M Warranty` when CBM fields are absent.
  static CbmItemSpec resolveItemSpec(Map<String, dynamic> item) {
    int? liters = _toPositiveIntOrNull(item['shelf_life_liters']);
    int? minLiters = _toPositiveIntOrNull(item['min_shelf_life_liters']) ?? liters;
    int? maxLiters = _toPositiveIntOrNull(item['max_shelf_life_liters']) ?? liters;
    double? years = _toPositiveDoubleOrNull(item['warranty_years']);
    double? minYears = _toPositiveDoubleOrNull(item['min_warranty_years']) ?? years;
    double? maxYears = _toPositiveDoubleOrNull(item['max_warranty_years']) ?? years;
    int? months = _toPositiveIntOrNull(item['shelf_life_months']);

    final rawNature = (item['part_nature'] ?? '').toString().trim().toUpperCase();
    final rawIsConsumable = item['is_consumable'] is bool ? item['is_consumable'] as bool : null;

    // Fallback kit derivation from child components if parent metrics weren't pre-populated
    if (liters == null && years == null && months == null) {
      final children = extractChildComponents(item);
      if (children.isNotEmpty) {
        final cLiters = <int>[];
        final cYears = <double>[];
        final cMonths = <int>[];
        bool hasCons = false;
        bool hasHw = false;
        for (final child in children) {
          final cSpec = resolveItemSpec(child);
          if (cSpec.shelfLifeLiters != null) cLiters.add(cSpec.shelfLifeLiters!);
          if (cSpec.warrantyYears != null) cYears.add(cSpec.warrantyYears!);
          if (cSpec.shelfLifeMonths != null) cMonths.add(cSpec.shelfLifeMonths!);
          if (cSpec.partNature == 'CONSUMABLE') hasCons = true;
          if (cSpec.partNature == 'NON_CONSUMABLE') hasHw = true;
        }
        if (cLiters.isNotEmpty) {
          cLiters.sort();
          minLiters = cLiters.first;
          maxLiters = cLiters.last;
          liters = maxLiters;
        }
        if (cYears.isNotEmpty) {
          cYears.sort();
          minYears = cYears.first;
          maxYears = cYears.last;
          years = maxYears;
        }
        if (cMonths.isNotEmpty) {
          cMonths.sort();
          months = cMonths.last;
        }
        if (hasCons && hasHw && rawNature.isEmpty) {
          return _buildResolvedSpec(
            partNature: 'MIXED_KIT',
            isConsumable: null,
            liters: liters,
            minLiters: minLiters,
            maxLiters: maxLiters,
            years: years,
            minYears: minYears,
            maxYears: maxYears,
            months: months,
            serverLabel: item['cbm_spec_label']?.toString(),
            serverBadge: item['short_badge']?.toString(),
          );
        }
      }
    }

    String partNature = rawNature;
    bool? isConsumable = rawIsConsumable;
    if (partNature.isEmpty || partNature == 'UNSPECIFIED') {
      if (liters != null && years == null) {
        partNature = 'CONSUMABLE';
        isConsumable = true;
      } else if (years != null && liters == null) {
        partNature = 'NON_CONSUMABLE';
        isConsumable = false;
      } else if (liters != null && years != null) {
        partNature = 'HYBRID';
      } else if (months != null) {
        partNature = 'CONSUMABLE';
        isConsumable = true;
      } else if (isConsumable == true) {
        partNature = 'CONSUMABLE';
      } else if (isConsumable == false) {
        partNature = 'NON_CONSUMABLE';
      } else {
        partNature = 'UNSPECIFIED';
      }
    }

    return _buildResolvedSpec(
      partNature: partNature,
      isConsumable: isConsumable,
      liters: liters,
      minLiters: minLiters,
      maxLiters: maxLiters,
      years: years,
      minYears: minYears,
      maxYears: maxYears,
      months: months,
      serverLabel: item['cbm_spec_label']?.toString(),
      serverBadge: item['short_badge']?.toString(),
    );
  }

  static CbmItemSpec _buildResolvedSpec({
    required String partNature,
    bool? isConsumable,
    int? liters,
    int? minLiters,
    int? maxLiters,
    double? years,
    double? minYears,
    double? maxYears,
    int? months,
    String? serverLabel,
    String? serverBadge,
  }) {
    String? natureLabel;
    switch (partNature) {
      case 'CONSUMABLE':
        natureLabel = 'Consumable';
        break;
      case 'NON_CONSUMABLE':
        natureLabel = 'Non-Consumable';
        break;
      case 'MIXED_KIT':
        natureLabel = 'Kit (Mixed)';
        break;
      case 'HYBRID':
        natureLabel = 'Consumable & Hardware';
        break;
      default:
        natureLabel = null;
    }

    final parts = <String>[];
    if (maxLiters != null) {
      if (minLiters != null && minLiters != maxLiters) {
        parts.add('${formatIndianInt(minLiters)}-${formatLiters(maxLiters)} Life');
      } else {
        parts.add('${formatLiters(maxLiters)} Life');
      }
    } else if (months != null) {
      parts.add('$months Months Life');
    }

    if (maxYears != null) {
      if (minYears != null && minYears != maxYears) {
        final minStr = minYears == minYears.roundToDouble() ? '${minYears.round()}' : '$minYears';
        parts.add('$minStr-${formatYears(maxYears)} Warranty');
      } else {
        parts.add('${formatYears(maxYears)} Warranty');
      }
    }

    final cleanServerLabel = serverLabel?.trim();
    final primaryRating = parts.isNotEmpty
        ? parts.join(' • ')
        : (cleanServerLabel != null && cleanServerLabel.isNotEmpty ? cleanServerLabel : null);

    final cleanBadge = serverBadge?.trim();
    String? shortBadge = cleanBadge != null && cleanBadge.isNotEmpty ? cleanBadge : null;
    if (shortBadge == null && primaryRating != null) {
      shortBadge = natureLabel != null ? '$natureLabel • $primaryRating' : primaryRating;
    } else if (shortBadge == null && natureLabel != null) {
      shortBadge = natureLabel;
    }

    return CbmItemSpec(
      partNature: partNature,
      isConsumable: isConsumable,
      shelfLifeLiters: liters,
      minShelfLifeLiters: minLiters,
      maxShelfLifeLiters: maxLiters,
      warrantyYears: years,
      minWarrantyYears: minYears,
      maxWarrantyYears: maxYears,
      shelfLifeMonths: months,
      natureLabel: natureLabel,
      primaryRatingLabel: primaryRating,
      shortBadge: shortBadge,
    );
  }

  /// Flattens itemized spares/kits from a visit's purchase orders.
  static List<Map<String, dynamic>> extractPurchasedItems(List<Map<String, dynamic>> purchases) {
    final allItems = <Map<String, dynamic>>[];
    for (final p in purchases) {
      final rawItems = p['items'];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is Map) allItems.add(Map<String, dynamic>.from(it));
        }
      } else if (rawItems is String && rawItems.trim().isNotEmpty) {
        try {
          final decoded = json.decode(rawItems);
          if (decoded is List) {
            for (final it in decoded) {
              if (it is Map) allItems.add(Map<String, dynamic>.from(it));
            }
          }
        } catch (_) {}
      }
    }
    return allItems;
  }

  /// Summarizes MRP, discounts, paid spares total, and CBM nature counts for a single job.
  static VisitPurchaseSummary summarizePurchases(List<Map<String, dynamic>> purchases) {
    double baseMrpTotal = 0.0;
    double discountTotal = 0.0;
    double paidTotal = 0.0;
    final coupons = <String>{};
    final orderNums = <String>{};
    int consumableCount = 0;
    int nonConsumableCount = 0;

    final items = extractPurchasedItems(purchases);
    for (final it in items) {
      final spec = resolveItemSpec(it);
      if (spec.partNature == 'CONSUMABLE') {
        consumableCount++;
      } else if (spec.partNature == 'NON_CONSUMABLE') {
        nonConsumableCount++;
      }
    }

    for (final p in purchases) {
      final net = _toDouble(p['net_payable'] ?? p['amount']);
      final mrp = _toDouble(p['base_mrp_total'] ?? p['total_mrp']);
      final disc = _toDouble(p['discount_amount']);
      paidTotal += net;
      baseMrpTotal += mrp > 0 ? mrp : (net + disc);
      discountTotal += disc;
      final coupon = (p['coupon_code'] ?? '').toString().trim().toUpperCase();
      if (coupon.isNotEmpty) coupons.add(coupon);
      final orderNum = (p['order_number'] ?? '').toString().trim();
      if (orderNum.isNotEmpty) orderNums.add(orderNum);
    }

    return VisitPurchaseSummary(
      ordersCount: purchases.length,
      itemsCount: items.length,
      baseMrpTotal: baseMrpTotal,
      discountAmount: discountTotal,
      sparesPaidTotal: paidTotal,
      couponCodes: coupons.toList(),
      orderNumbers: orderNums.toList(),
      consumableCount: consumableCount,
      nonConsumableCount: nonConsumableCount,
    );
  }
}

/// Shared Customer UI card displaying complimentary spares sealed inside a kit pouch (₹0 FREE).
class SealedFreeSparesBox extends StatelessWidget {
  final List<Map<String, dynamic>> freeSpares;
  final EdgeInsetsGeometry margin;
  final String title;

  const SealedFreeSparesBox({
    super.key,
    required this.freeSpares,
    this.margin = const EdgeInsets.only(top: 8),
    this.title = '🎁 SEALED FREE SPARES INSIDE POUCH (₹0 FREE)',
  });

  @override
  Widget build(BuildContext context) {
    if (freeSpares.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFA7F3D0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: Color(0xFF047857),
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          ...freeSpares.map((sp) {
            final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
            final safeQty = q > 0 ? q : 1;
            final spName = (sp['name'] ?? sp['product_name'] ?? sp['short_description'] ?? sp['sku'] ?? 'Free Spare').toString();
            final uMrp = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
            final explicitLine = double.tryParse((sp['line_mrp'] ?? '').toString());
            final worth = explicitLine ?? (safeQty * uMrp);
            return Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  const Icon(Icons.card_giftcard_rounded, size: 14, color: Color(0xFF059669)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${safeQty}x $spName',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF065F46)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    worth > 0 ? 'Worth ₹${CbmSpecHelper.formatIndianInt(worth.round())} FREE' : 'FREE',
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

