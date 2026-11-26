/// Canonical Unit-of-Measure helper for ROParts Customer App.
class ProductUnitHelper {
  ProductUnitHelper._();

  static const String unitPcs = 'PCS';
  static const String unitMeter = 'METER';

  static final RegExp _pipeNameOrSkuRegex = RegExp(
    r'(?:^|[^a-z0-9])(pipes?|tubings?|tube)(?:$|[^a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _pipeSkuRegex = RegExp(
    r'(?:^|[-_])(PIPE|TUBING)(?:[-_]|$)',
    caseSensitive: false,
  );
  static final RegExp _nonPipeFittingOrToolRegex = RegExp(
    r'\b(cutters?|clamps?|clips?|brackets?|holders?|spanners?|wrench(?:es)?|elbows?|tees?|unions?|connectors?|couplers?|adapt[eo]rs?|valves?|cocks?|nipples?|plugs?|caps?|joints?|quartz|lamps?|bulbs?|testers?|tds|gauges?|meters?)\b',
    caseSensitive: false,
  );

  static String normalizeUnitMode(dynamic raw) {
    final clean = (raw ?? '').toString().trim().toUpperCase();
    if (clean.isEmpty || clean == 'AUTO') return 'AUTO';
    if (const {'METER', 'METERS', 'METRE', 'METRES', 'M', 'MTR', 'MTRS'}.contains(clean)) {
      return unitMeter;
    }
    if (const {'PCS', 'PC', 'PIECE', 'PIECES', 'UNIT', 'UNITS'}.contains(clean)) {
      return unitPcs;
    }
    return 'AUTO';
  }

  static bool isPipeLikeProduct({
    String? sku,
    String? name,
    String? shortDescription,
  }) {
    final cleanSku = (sku ?? '').trim().toUpperCase();
    final combinedName = [name, shortDescription]
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (cleanSku.isEmpty && combinedName.isEmpty) return false;
    if (_nonPipeFittingOrToolRegex.hasMatch(combinedName)) return false;
    return _pipeSkuRegex.hasMatch(cleanSku) || _pipeNameOrSkuRegex.hasMatch(combinedName);
  }

  static String resolveUnit(
    dynamic item, {
    String? sku,
    String? name,
  }) {
    final map = item is Map ? item : const <String, dynamic>{};
    final catalogMeta = map['catalog_meta'] is Map ? map['catalog_meta'] as Map : const <String, dynamic>{};

    final mode = normalizeUnitMode(map['unit_mode'] ?? catalogMeta['unit_mode']);
    if (mode == unitMeter || mode == unitPcs) return mode;

    final rawExplicit = (map['unit'] ?? map['unit_label'] ?? catalogMeta['unit'] ?? '').toString().trim().toUpperCase();
    if (const {'METER', 'METERS', 'METRE', 'METRES', 'M', 'MTR', 'MTRS'}.contains(rawExplicit)) {
      return unitMeter;
    }

    final resolvedSku = (sku ?? map['product_sku'] ?? map['sku'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    final resolvedName = (name ?? map['product_name'] ?? map['name'] ?? '').toString().trim();
    final shortDesc = (map['short_description'] ?? '').toString().trim();
    if (isPipeLikeProduct(sku: resolvedSku, name: resolvedName, shortDescription: shortDesc)) {
      return unitMeter;
    }
    return unitPcs;
  }

  static String formatBomOrFreeName(Map<String, dynamic> comp, {int multiplier = 1}) {
    final rawQty = int.tryParse((comp['qty'] ?? comp['quantity'] ?? '1').toString()) ?? 1;
    final totalQty = (rawQty > 0 ? rawQty : 1) * (multiplier > 0 ? multiplier : 1);
    final label = (comp['name'] ?? comp['product_name'] ?? comp['sku'] ?? comp['product_sku'] ?? 'Item').toString();
    if (resolveUnit(comp) == unitMeter) {
      return '$totalQty meter × $label';
    }
    return '$totalQty× $label';
  }
}
