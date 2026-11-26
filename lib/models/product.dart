class ProductComparison {
  final String feature;
  final String roparts;
  final String localMarket;

  const ProductComparison({
    required this.feature,
    required this.roparts,
    required this.localMarket,
  });

  factory ProductComparison.fromJson(Map<String, dynamic> json) {
    return ProductComparison(
      feature: (json['title'] ?? json['feature'] ?? 'Quality Standard').toString().trim(),
      roparts: (json['roparts'] ?? '').toString().trim(),
      localMarket: (json['local'] ?? json['localMarket'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'title': feature,
        'roparts': roparts,
        'local': localMarket,
      };
}

class Product {
  final String id;
  final String sku;
  final String name;
  final String slug;
  final String brand;
  final int sellingPrice; // In rupees
  final int mrp; // In rupees
  final double rating;
  final int reviewsCount;
  final String image;
  final List<String> galleryUrls;
  final String shortDescription;
  final String detailedDescription;
  final List<String> keyFeatures;
  final String lifeInLiters;
  final String lifeDuration;
  final List<ProductComparison> comparisons;
  final String youtubeVideoUrl;
  final String youtubeVideoTitle;
  final Map<String, String> specifications;
  final List<String> compatibility;
  final bool isFeatured;
  final bool isBestseller;
  final String categoryId;
  final List<String> categorySlugs;
  final String categoryName;
  final String segment; // domestic, commercial, industrial
  final int maxDiscountAllowed; // CBM Guardrail: maximum discount allowed
  final bool inStock;
  final bool isActive;
  final bool onlineSellingEnabled;
  final bool codEnabled;
  final String itemType; // PRODUCT or KIT
  final List<Map<String, dynamic>> kitComponents;
  final List<Map<String, dynamic>> freeSpares;
  final double freeSparesValue;
  final List<String> badges;
  final String cbmSpecLabel;
  final String unit;
  final String unitMode;

  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.slug,
    required this.brand,
    required this.sellingPrice,
    required this.mrp,
    this.rating = 4.9,
    this.reviewsCount = 0,
    required this.image,
    this.galleryUrls = const [],
    required this.shortDescription,
    this.detailedDescription = '',
    this.keyFeatures = const [],
    this.lifeInLiters = 'Genuine CBM Part',
    this.lifeDuration = 'Standard Service Cycle',
    this.comparisons = const [],
    this.youtubeVideoUrl = '',
    this.youtubeVideoTitle = 'Genuine DropPurity Spares: Quality & Purifier Compatibility',
    this.specifications = const {},
    this.compatibility = const [],
    this.isFeatured = false,
    this.isBestseller = false,
    required this.categoryId,
    this.categorySlugs = const [],
    this.categoryName = 'RO Spares',
    this.segment = 'domestic',
    this.maxDiscountAllowed = 0,
    this.inStock = true,
    this.isActive = true,
    this.onlineSellingEnabled = true,
    this.codEnabled = true,
    this.itemType = 'PRODUCT',
    this.kitComponents = const [],
    this.freeSpares = const [],
    this.freeSparesValue = 0.0,
    this.badges = const [],
    this.cbmSpecLabel = '',
    this.unit = 'PCS',
    this.unitMode = 'AUTO',
  });

  bool get isKit => itemType.toUpperCase() == 'KIT';

  Product copyWith({
    String? name,
    int? sellingPrice,
    int? mrp,
    int? maxDiscountAllowed,
    bool? inStock,
    bool? isActive,
    bool? onlineSellingEnabled,
    bool? codEnabled,
  }) {
    return Product(
      id: id,
      sku: sku,
      name: name ?? this.name,
      slug: slug,
      brand: brand,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      mrp: mrp ?? this.mrp,
      rating: rating,
      reviewsCount: reviewsCount,
      image: image,
      galleryUrls: galleryUrls,
      shortDescription: shortDescription,
      detailedDescription: detailedDescription,
      keyFeatures: keyFeatures,
      lifeInLiters: lifeInLiters,
      lifeDuration: lifeDuration,
      comparisons: comparisons,
      youtubeVideoUrl: youtubeVideoUrl,
      youtubeVideoTitle: youtubeVideoTitle,
      specifications: specifications,
      compatibility: compatibility,
      isFeatured: isFeatured,
      isBestseller: isBestseller,
      categoryId: categoryId,
      categorySlugs: categorySlugs,
      categoryName: categoryName,
      segment: segment,
      maxDiscountAllowed: maxDiscountAllowed ?? this.maxDiscountAllowed,
      inStock: inStock ?? this.inStock,
      isActive: isActive ?? this.isActive,
      onlineSellingEnabled: onlineSellingEnabled ?? this.onlineSellingEnabled,
      codEnabled: codEnabled ?? this.codEnabled,
      itemType: itemType,
      kitComponents: kitComponents,
      freeSpares: freeSpares,
      freeSparesValue: freeSparesValue,
      badges: badges,
      cbmSpecLabel: cbmSpecLabel,
    );
  }

  String get effectiveDetailedDescription {
    if (detailedDescription.trim().isNotEmpty) return detailedDescription;
    if (shortDescription.trim().isNotEmpty) return shortDescription;
    return 'Genuine DropPurity CBM certified replacement component tested for food-grade purity and reliable purifier operation.';
  }

  List<String> get effectiveKeyFeatures {
    if (keyFeatures.isNotEmpty) return keyFeatures;
    return [
      if (cbmSpecLabel.trim().isNotEmpty) 'Rated Specification: $cbmSpecLabel',
      'Direct CBM Factory Catalog Authentic SKU ($sku)',
      'Quality-tested for universal compatibility & zero leakage',
    ];
  }

  List<ProductComparison> get effectiveComparisons {
    return comparisons;
  }

  int get discountPercent {
    if (mrp <= sellingPrice || mrp <= 0) return 0;
    return (((mrp - sellingPrice) / mrp) * 100).round();
  }

  static String _formatThousands(num v) {
    final s = v.round().toString();
    if (s.length <= 3) return s;
    final buf = StringBuffer();
    int count = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      buf.write(s[i]);
      count++;
      if (i > 0 && count == 3) {
        buf.write(',');
      } else if (i > 0 && count > 3 && (count - 3) % 2 == 0) {
        buf.write(',');
      }
    }
    return buf.toString().split('').reversed.join();
  }

  factory Product.fromJson(Map<String, dynamic> json) {
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
    final maxDisc = (double.tryParse((json['max_discount_allowed'] ?? '0').toString()) ?? 0).round();

    final rawSlugs = (json['app_category_slugs'] is List)
        ? (json['app_category_slugs'] as List)
            .map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];

    final skuStr = (json['sku'] ?? json['product_sku'] ?? json['recipe_id'] ?? json['id'] ?? '').toString().trim();
    final rawType = (json['type'] ?? '').toString().trim().toUpperCase();
    final itemType = rawType == 'KIT' ? 'KIT' : 'PRODUCT';

    String catId = rawSlugs.isNotEmpty ? rawSlugs.first : '';
    if (catId.isEmpty) {
      if (itemType == 'KIT') {
        catId = 'service-kits';
      } else {
        final combined = '${json['app_category_name'] ?? ''} ${json['category'] ?? ''} $skuStr ${json['name'] ?? ''}'.toUpperCase();
        if (combined.contains('MEMBRANE')) {
          catId = 'membranes';
        } else if (combined.contains('PUMP')) {
          catId = 'pumps';
        } else if (combined.contains('SMPS') || combined.contains('POWER') || combined.contains('ADAPTER')) {
          catId = 'smps-power';
        } else if (combined.contains('FILTER') || combined.contains('CARB') || combined.contains('SEDI')) {
          catId = 'filters';
        } else {
          catId = 'fittings-valves';
        }
      }
    }

    final gallery = (json['gallery_urls'] is List)
        ? (json['gallery_urls'] as List)
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];
    final primaryImgRaw = (json['image_url'] ?? '').toString().trim();
    final resolvedImg = primaryImgRaw.isNotEmpty
        ? primaryImgRaw
        : (gallery.isNotEmpty ? gallery.first : '');

    final features = (json['key_features'] is List)
        ? (json['key_features'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final compModels = (json['compatible_models'] is List)
        ? (json['compatible_models'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final badgeList = (json['badges'] is List)
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

    final compList = <ProductComparison>[];
    if (json['comparisons'] is List) {
      for (final entry in (json['comparisons'] as List)) {
        if (entry is Map) {
          compList.add(ProductComparison.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }

    final kitComps = <Map<String, dynamic>>[];
    final rawBreak = json['components_breakdown'] ?? json['components'] ?? json['bom_spec'];
    if (rawBreak is List) {
      for (final c in rawBreak) {
        if (c is Map) kitComps.add(Map<String, dynamic>.from(c));
      }
    }

    final freeSparesList = <Map<String, dynamic>>[];
    double computedFreeVal = 0.0;
    final rawFree = json['free_spares'] ?? json['free_spares_spec'] ?? json['free_spares_snapshot'];
    if (rawFree is List) {
      for (final f in rawFree) {
        if (f is Map) {
          final fm = Map<String, dynamic>.from(f);
          freeSparesList.add(fm);
          final q = int.tryParse((fm['qty'] ?? fm['quantity'] ?? '1').toString()) ?? 1;
          final u = double.tryParse((fm['unit_mrp'] ?? fm['mrp'] ?? '0').toString()) ?? 0.0;
          final line = double.tryParse((fm['line_mrp'] ?? '').toString());
          computedFreeVal += line ?? (u * (q > 0 ? q : 1));
        }
      }
    }
    final explicitFreeVal = double.tryParse((json['free_spares_value'] ?? json['free_spares_mrp'] ?? '').toString());
    final resolvedFreeVal = (explicitFreeVal != null && explicitFreeVal > 0)
        ? explicitFreeVal
        : computedFreeVal;

    final litersNum = num.tryParse(json['shelf_life_liters']?.toString() ?? '');
    final warrantyNum = num.tryParse(json['warranty_years']?.toString() ?? '');
    final monthsNum = num.tryParse(json['shelf_life_months']?.toString() ?? '');
    final cbmLabel = (json['cbm_spec_label'] ?? '').toString().trim();

    String lifeLitersText = 'CBM Certified';
    String lifeDurationText = 'Standard Cycle';
    if (litersNum != null && litersNum > 0) {
      lifeLitersText = '${_formatThousands(litersNum)} Liters';
    } else if (cbmLabel.isNotEmpty) {
      lifeLitersText = cbmLabel;
    }
    if (warrantyNum != null && warrantyNum > 0) {
      final cleanYr = warrantyNum == warrantyNum.roundToDouble()
          ? warrantyNum.toInt().toString()
          : warrantyNum.toStringAsFixed(1);
      lifeDurationText = cleanYr == '1' ? '1 Year Warranty' : '$cleanYr Years Warranty';
    } else if (monthsNum != null && monthsNum > 0) {
      lifeDurationText = '${monthsNum.toInt()} Months Life';
    } else if ((json['short_badge'] ?? '').toString().trim().isNotEmpty) {
      lifeDurationText = json['short_badge'].toString().trim();
    }

    final shortDesc = (json['short_description'] ?? json['description'] ?? '').toString().trim();
    final detailDesc = (json['detailed_description'] ?? '').toString().trim();
    final catName = (json['app_category_name'] ?? json['category'] ?? 'RO Spares').toString().trim();
    final ytUrl = (json['youtube_video_url'] ?? '').toString().trim();
    final segmentVal = (json['category'] ?? 'domestic').toString().trim().toLowerCase();
    final parsedRating = double.tryParse((json['rating'] ?? '4.9').toString()) ?? 4.9;
    final parsedReviews = int.tryParse((json['reviews_count'] ?? '0').toString()) ?? 0;

    final isActiveVal = json['is_active'] != false;
    final inStockVal = isActiveVal &&
        json['in_stock'] != false &&
        (json['stock_status'] ?? '').toString().trim().toUpperCase() != 'OUT_OF_STOCK';

    return Product(
      id: (json['id'] ?? skuStr).toString().trim(),
      sku: skuStr,
      name: (json['name'] ?? json['title'] ?? json['product_name'] ?? skuStr).toString().trim(),
      slug: skuStr.toLowerCase().replaceAll('_', '-'),
      brand: 'Drop Purity Parts',
      sellingPrice: selling,
      mrp: mrpVal,
      rating: parsedRating,
      reviewsCount: parsedReviews,
      image: resolvedImg,
      galleryUrls: gallery,
      shortDescription: shortDesc.isNotEmpty ? shortDesc : '100% Genuine CBM Certified RO Part',
      detailedDescription: detailDesc,
      keyFeatures: features,
      lifeInLiters: lifeLitersText,
      lifeDuration: lifeDurationText,
      comparisons: compList,
      youtubeVideoUrl: ytUrl,
      youtubeVideoTitle: 'Genuine DropPurity Spares: Product Walkthrough',
      specifications: specsMap,
      compatibility: compModels,
      isFeatured: true,
      isBestseller: badgeList.contains('BESTSELLER'),
      categoryId: catId,
      categorySlugs: rawSlugs,
      categoryName: catName,
      segment: segmentVal,
      maxDiscountAllowed: maxDisc,
      inStock: inStockVal,
      isActive: isActiveVal,
      onlineSellingEnabled: inStockVal && json['online_selling_enabled'] != false,
      codEnabled: json['cod_enabled'] != false,
      itemType: itemType,
      kitComponents: kitComps,
      freeSpares: freeSparesList,
      freeSparesValue: resolvedFreeVal,
      badges: badgeList,
      cbmSpecLabel: cbmLabel,
      unit: (json['unit'] ?? 'PCS').toString().trim().toUpperCase(),
      unitMode: (json['unit_mode'] ?? 'AUTO').toString().trim().toUpperCase(),
    );
  }
}
