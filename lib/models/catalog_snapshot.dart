import 'maintenance_kit.dart';
import 'product.dart';

class CatalogCategory {
  final String slug;
  final String name;
  final String subtitle;
  final String iconName;
  final String imageUrl;
  final int sortOrder;
  final bool onlineVisible;
  final bool homeVisible;

  const CatalogCategory({
    required this.slug,
    required this.name,
    this.subtitle = '',
    this.iconName = 'category',
    this.imageUrl = '',
    this.sortOrder = 100,
    this.onlineVisible = true,
    this.homeVisible = true,
  });

  factory CatalogCategory.fromJson(Map<String, dynamic> json) {
    final slug = (json['slug'] ?? json['category_id'] ?? '').toString().trim().toLowerCase();
    return CatalogCategory(
      slug: slug,
      name: (json['name'] ?? slug).toString().trim(),
      subtitle: (json['subtitle'] ?? '').toString().trim(),
      iconName: (json['icon_name'] ?? 'category').toString().trim(),
      imageUrl: (json['image_url'] ?? '').toString().trim(),
      sortOrder: int.tryParse((json['sort_order'] ?? '100').toString()) ?? 100,
      onlineVisible: json['online_visible'] != false,
      homeVisible: json['home_visible'] != false,
    );
  }
}

class CatalogSnapshot {
  final String catalogRef;
  final int catalogSeq;
  final List<CatalogCategory> categories;
  final List<Product> products;
  final List<MaintenanceKit> kits;
  final Map<String, dynamic>? cbmHighlights;
  final DateTime fetchedAt;

  const CatalogSnapshot({
    required this.catalogRef,
    required this.catalogSeq,
    required this.categories,
    required this.products,
    required this.kits,
    this.cbmHighlights,
    required this.fetchedAt,
  });

  factory CatalogSnapshot.empty() => CatalogSnapshot(
        catalogRef: '',
        catalogSeq: 0,
        categories: const [],
        products: const [],
        kits: const [],
        cbmHighlights: null,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  List<Product> get allBrowseItems => [
        ...products,
        ...kits.map((k) => k.toProduct()),
      ];

  factory CatalogSnapshot.fromJson(Map<String, dynamic> json, {DateTime? fetchedAt}) {
    final rawCats = (json['categories'] is List) ? (json['categories'] as List) : const [];
    final categories = rawCats
        .whereType<Map>()
        .map((c) => CatalogCategory.fromJson(Map<String, dynamic>.from(c)))
        .where((c) => c.slug.isNotEmpty)
        .toList();

    final rawProds = (json['products'] is List) ? (json['products'] as List) : const [];
    final products = rawProds
        .whereType<Map>()
        .map((p) => Product.fromJson(Map<String, dynamic>.from(p)))
        .where((p) => p.sku.isNotEmpty)
        .toList();

    final rawKits = (json['kits'] is List) ? (json['kits'] as List) : const [];
    final kits = rawKits
        .whereType<Map>()
        .map((k) => MaintenanceKit.fromJson(Map<String, dynamic>.from(k)))
        .where((k) => k.id.isNotEmpty)
        .toList();

    return CatalogSnapshot(
      catalogRef: (json['catalog_ref'] ?? '').toString().trim(),
      catalogSeq: int.tryParse((json['catalog_seq'] ?? '0').toString()) ?? 0,
      categories: categories,
      products: products,
      kits: kits,
      cbmHighlights: json['cbm_highlights'] is Map
          ? Map<String, dynamic>.from(json['cbm_highlights'] as Map)
          : null,
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }
}

