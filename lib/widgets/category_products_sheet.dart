import 'package:flutter/material.dart';
import '../models/catalog_snapshot.dart';
import '../models/maintenance_kit.dart';
import '../models/product.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';
import 'product_card.dart';

class CategoryProductsSheet extends StatefulWidget {
  final String initialCategoryId;
  final CartState cartState;
  final List<CatalogCategory> categories;
  final List<Product>? products;
  final List<MaintenanceKit> kits;
  final Function(Product product) onProductSelect;
  final VoidCallback onOpenCart;

  const CategoryProductsSheet({
    super.key,
    required this.initialCategoryId,
    required this.cartState,
    this.categories = const [],
    this.products,
    this.kits = const [],
    required this.onProductSelect,
    required this.onOpenCart,
  });

  @override
  State<CategoryProductsSheet> createState() => _CategoryProductsSheetState();
}

class _CategoryProductsSheetState extends State<CategoryProductsSheet> {
  late String _selectedCategoryId;

  List<Map<String, String>> get _categories {
    final tabs = <Map<String, String>>[
      {
        'id': 'all',
        'label': 'All Spares',
        'subtitle': 'All active CBM spare parts & service kits',
      },
    ];
    final seen = <String>{'all'};
    for (final cat in widget.categories) {
      if (!cat.onlineVisible || cat.slug.isEmpty || seen.contains(cat.slug)) continue;
      seen.add(cat.slug);
      tabs.add({
        'id': cat.slug,
        'label': cat.name,
        'subtitle': cat.subtitle.isNotEmpty
            ? cat.subtitle
            : 'Factory-direct genuine ${cat.name}',
      });
    }
    if (widget.kits.isNotEmpty && !seen.contains('service-kits')) {
      tabs.add({
        'id': 'service-kits',
        'label': 'Service Kits',
        'subtitle': 'Complete multi-stage RO maintenance bundles',
      });
    }
    return tabs;
  }

  @override
  void initState() {
    super.initState();
    final initId = widget.initialCategoryId.trim().toLowerCase();
    _selectedCategoryId = initId == 'cat-kits' ? 'service-kits' : (initId.isEmpty ? 'all' : initId);
  }

  Map<String, String>? get _selectedTab {
    for (final c in _categories) {
      if (c['id'] == _selectedCategoryId) return c;
    }
    return null;
  }

  String get _currentCategoryTitle => _selectedTab?['label'] ?? 'All RO Spares';

  String get _currentCategorySubtitle =>
      _selectedTab?['subtitle'] ?? 'Factory-direct genuine spare parts for all water purifiers';

  List<Product> get _sourceProducts {
    final base = List<Product>.from(widget.products ?? const []);
    final seenIds = base.map((p) => p.sku.toUpperCase()).toSet();
    for (final k in widget.kits) {
      final kp = k.toProduct();
      if (!seenIds.contains(kp.sku.toUpperCase())) {
        seenIds.add(kp.sku.toUpperCase());
        base.add(kp);
      }
    }
    return base;
  }

  List<Product> get _filteredProducts {
    final source = _sourceProducts;
    if (_selectedCategoryId == 'all') {
      return source;
    }
    if (_selectedCategoryId == 'service-kits') {
      return source
          .where((p) =>
              p.isKit ||
              p.categorySlugs.contains('service-kits') ||
              p.categoryId == 'service-kits')
          .toList();
    }
    return source
        .where((p) =>
            p.categorySlugs.contains(_selectedCategoryId) ||
            p.categoryId == _selectedCategoryId)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProducts;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
          // 1. Top Pull Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4.5,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),

          // 2. Header Bar with Back/Close button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _currentCategoryTitle,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0FDF4),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFBBF7D0)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.verified_rounded, size: 10, color: Color(0xFF16A34A)),
                                const SizedBox(width: 3),
                                Text(
                                  '${filtered.length} Spares',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF16A34A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _currentCategorySubtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE2E8F0),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF334155)),
                  ),
                ),
              ],
            ),
          ),

          // 3. Category Filter Tabs (Pills)
          SizedBox(
            height: 38,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                final isSelected = cat['id'] == _selectedCategoryId;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: BouncingWidget(
                    onTap: () => setState(() => _selectedCategoryId = cat['id']!),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF0284C7) : Colors.white,
                        borderRadius: BorderRadius.circular(19),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                          width: 1.2,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Text(
                        cat['label']!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isSelected ? Colors.white : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 10),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),

          // 4. Products Grid Area
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.inventory_2_outlined, size: 48, color: Color(0xFF94A3B8)),
                        const SizedBox(height: 10),
                        const Text(
                          'No spares found in this category',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => setState(() => _selectedCategoryId = 'all'),
                          child: const Text('View All Spares'),
                        ),
                      ],
                    ),
                  )
                : Builder(
                    builder: (context) {
                      final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(0.9, 1.15);
                      final double cardExtent = 248.0 + (textScale > 1.0 ? (textScale - 1.0) * 60.0 : 0.0);

                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
                        physics: const BouncingScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: cardExtent,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 12,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final product = filtered[index];
                          return ProductCard(
                            product: product,
                            cartState: widget.cartState,
                            onTap: () => widget.onProductSelect(product),
                          );
                        },
                      );
                    },
                  ),
          ),

          // 5. Sticky Bottom Cart Bar (if cart has items)
          AnimatedBuilder(
            animation: widget.cartState,
            builder: (context, child) {
              if (widget.cartState.itemCount == 0) return const SizedBox.shrink();

              return Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: const Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 10,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: BouncingWidget(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onOpenCart();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${widget.cartState.itemCount} ITEMS',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '₹${widget.cartState.totalAmount}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'View Cart',
                          style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      ),
    );
  }
}
