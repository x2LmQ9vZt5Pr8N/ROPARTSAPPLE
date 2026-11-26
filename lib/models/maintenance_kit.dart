import 'product.dart';

class MaintenanceKit {
  final String id;
  final String recipeId;
  final String badge;
  final String title;
  final String desc;
  final String detailedDescription;
  final List<String> items;
  final List<Map<String, dynamic>> components;
  final List<Map<String, dynamic>> freeSpares;
  final double freeSparesValue;
  final int price;
  final int mrp;
  final String image;
  final List<String> galleryUrls;
  final bool isPopular;
  final bool inStock;
  final bool isActive;
  final bool onlineSellingEnabled;
  final bool codEnabled;
  final List<String> categorySlugs;
  final List<String> keyFeatures;
  final List<ProductComparison> comparisons;
  final Map<String, String> specs;
  final List<String> compatibility;
  final String youtubeVideoUrl;
  final String cbmSpecLabel;

  const MaintenanceKit({
    required this.id,
    this.recipeId = '',
    required this.badge,
    required this.title,
    required this.desc,
    this.detailedDescription = '',
    required this.items,
    this.components = const [],
    this.freeSpares = const [],
    this.freeSparesValue = 0.0,
    required this.price,
    this.mrp = 0,
    required this.image,
    this.galleryUrls = const [],
    this.isPopular = false,
    this.inStock = true,
    this.isActive = true,
    this.onlineSellingEnabled = true,
    this.codEnabled = true,
    this.categorySlugs = const [],
    this.keyFeatures = const [],
    this.comparisons = const [],
    this.specs = const {},
    this.compatibility = const [],
    this.youtubeVideoUrl = '',
    this.cbmSpecLabel = '',
  });

  int get effectiveMrp => mrp >= price ? mrp : price;

  int get discountPercent {
    final m = effectiveMrp;
    if (m <= price || m <= 0) return 0;
    return (((m - price) / m) * 100).round();
  }

  factory MaintenanceKit.fromJson(Map<String, dynamic> json) {
    final rid = (json['recipe_id'] ?? json['id'] ?? json['sku'] ?? '').toString().trim();
    final sellingRaw = double.tryParse(
          (json['online_selling_price'] ?? json['selling_price'] ?? json['mrp'] ?? json['base_mrp'] ?? '0').toString(),
        ) ??
        0;
    final mrpRaw = double.tryParse(
          (json['mrp'] ?? json['base_mrp'] ?? json['kit_mrp'] ?? '0').toString(),
        ) ??
        0;
    final selling = sellingRaw.round() > 0 ? sellingRaw.round() : mrpRaw.round();
    final mrpVal = mrpRaw.round() > 0 ? mrpRaw.round() : selling;

    final rawBreak = json['components_breakdown'] ?? json['components'] ?? json['bom_spec'];
    final compList = <Map<String, dynamic>>[];
    final itemNames = <String>[];
    if (rawBreak is List) {
      for (final c in rawBreak) {
        if (c is Map) {
          final m = Map<String, dynamic>.from(c);
          compList.add(m);
          final name = (m['name'] ?? m['product_name'] ?? m['sku'] ?? '').toString().trim();
          final qty = int.tryParse((m['qty'] ?? '1').toString()) ?? 1;
          if (name.isNotEmpty) {
            itemNames.add(qty > 1 ? '$qty× $name' : name);
          }
        }
      }
    }

    final freeSparesRaw = json['free_spares'] ?? json['free_spares_spec'] ?? json['free_spares_snapshot'];
    final freeSparesList = <Map<String, dynamic>>[];
    double computedFreeValue = 0.0;
    if (freeSparesRaw is List) {
      for (final f in freeSparesRaw) {
        if (f is Map) {
          final fm = Map<String, dynamic>.from(f);
          freeSparesList.add(fm);
          final q = int.tryParse((fm['qty'] ?? fm['quantity'] ?? '1').toString()) ?? 1;
          final u = double.tryParse((fm['unit_mrp'] ?? fm['mrp'] ?? '0').toString()) ?? 0.0;
          final line = double.tryParse((fm['line_mrp'] ?? '').toString());
          computedFreeValue += line ?? (u * (q > 0 ? q : 1));
        }
      }
    }
    final explicitFreeVal = double.tryParse((json['free_spares_value'] ?? json['free_spares_mrp'] ?? '').toString());
    final resolvedFreeValue = (explicitFreeVal != null && explicitFreeVal > 0)
        ? explicitFreeVal
        : computedFreeValue;

    final gallery = (json['gallery_urls'] is List)
        ? (json['gallery_urls'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    final primaryImg = (json['image_url'] ?? '').toString().trim();
    final resolvedImg = primaryImg.isNotEmpty ? primaryImg : (gallery.isNotEmpty ? gallery.first : '');

    final slugs = (json['app_category_slugs'] is List)
        ? (json['app_category_slugs'] as List).map((e) => e.toString().trim().toLowerCase()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final features = (json['key_features'] is List)
        ? (json['key_features'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final compat = (json['compatible_models'] is List)
        ? (json['compatible_models'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final badges = (json['badges'] is List)
        ? (json['badges'] as List).map((e) => e.toString().trim().toUpperCase()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final specsMap = <String, String>{};
    if (json['specs'] is Map) {
      (json['specs'] as Map).forEach((k, v) {
        final key = k.toString().trim();
        final val = v?.toString().trim() ?? '';
        if (key.isNotEmpty && val.isNotEmpty) specsMap[key] = val;
      });
    }

    final comparisonsList = <ProductComparison>[];
    if (json['comparisons'] is List) {
      for (final entry in (json['comparisons'] as List)) {
        if (entry is Map) {
          comparisonsList.add(ProductComparison.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }

    final cbmSpec = (json['cbm_spec_label'] ?? '').toString().trim();
    final shortBadge = (json['short_badge'] ?? '').toString().trim();
    final badgeText = shortBadge.isNotEmpty
        ? shortBadge
        : (cbmSpec.isNotEmpty ? cbmSpec : '${itemNames.isEmpty ? 'MULTI-STAGE' : '${itemNames.length}-PART'} KIT');

    final isActiveVal = json['is_active'] != false;
    final inStockVal = isActiveVal &&
        json['in_stock'] != false &&
        (json['stock_status'] ?? '').toString().trim().toUpperCase() != 'OUT_OF_STOCK';

    return MaintenanceKit(
      id: rid,
      recipeId: rid,
      badge: badgeText,
      title: (json['name'] ?? json['title'] ?? json['recipe_name'] ?? rid).toString().trim(),
      desc: (json['short_description'] ?? json['description'] ?? '${itemNames.length}-Component Genuine Kit').toString().trim(),
      detailedDescription: (json['detailed_description'] ?? '').toString().trim(),
      items: itemNames,
      components: compList,
      freeSpares: freeSparesList,
      freeSparesValue: resolvedFreeValue,
      price: selling,
      mrp: mrpVal,
      image: resolvedImg,
      galleryUrls: gallery,
      isPopular: badges.contains('BESTSELLER') || badges.contains('POPULAR'),
      inStock: inStockVal,
      isActive: isActiveVal,
      onlineSellingEnabled: inStockVal && json['online_selling_enabled'] != false,
      codEnabled: json['cod_enabled'] != false,
      categorySlugs: slugs.isEmpty ? const ['service-kits'] : slugs,
      keyFeatures: features,
      comparisons: comparisonsList,
      specs: specsMap,
      compatibility: compat,
      youtubeVideoUrl: (json['youtube_video_url'] ?? '').toString().trim(),
      cbmSpecLabel: cbmSpec,
    );
  }

  Product toProduct() {
    final effectiveSpecs = <String, String>{
      ...specs,
      if (badge.isNotEmpty) 'Kit Rating': badge,
      if (items.isNotEmpty) 'Included Spares': items.join(', '),
      if (freeSpares.isNotEmpty)
        'Sealed Free Spares (Inside Pouch)': freeSpares
            .map((e) => '${e['qty'] ?? 1}x ${e['name'] ?? e['sku'] ?? ''}')
            .join(', '),
    };
    return Product(
      id: id,
      sku: recipeId.isNotEmpty ? recipeId : id,
      name: title,
      slug: id.toLowerCase(),
      brand: 'DropPurity',
      sellingPrice: price,
      mrp: effectiveMrp,
      image: image,
      galleryUrls: galleryUrls,
      shortDescription: desc,
      detailedDescription: detailedDescription,
      keyFeatures: keyFeatures,
      lifeInLiters: cbmSpecLabel.isNotEmpty ? cbmSpecLabel : badge,
      lifeDuration: '${components.length} Genuine Parts Included',
      comparisons: comparisons,
      youtubeVideoUrl: youtubeVideoUrl,
      youtubeVideoTitle: 'Genuine DropPurity Kit: Overview & Installation',
      specifications: effectiveSpecs,
      compatibility: compatibility,
      categoryId: categorySlugs.isNotEmpty ? categorySlugs.first : 'service-kits',
      categorySlugs: categorySlugs,
      categoryName: 'Service Kits',
      inStock: inStock,
      isActive: isActive,
      onlineSellingEnabled: onlineSellingEnabled,
      codEnabled: codEnabled,
      itemType: 'KIT',
      kitComponents: components,
      freeSpares: freeSpares,
      freeSparesValue: freeSparesValue,
      cbmSpecLabel: cbmSpecLabel,
    );
  }
}
