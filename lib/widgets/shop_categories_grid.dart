import 'package:flutter/material.dart';
import '../models/catalog_snapshot.dart';
import '../models/product.dart';
import 'bouncing_widget.dart';
import 'catalog_network_image.dart';

class ShopCategoriesGrid extends StatelessWidget {
  final List<CatalogCategory> categories;
  final List<Product> products;
  final Function(String categoryId) onCategorySelect;

  const ShopCategoriesGrid({
    super.key,
    required this.categories,
    this.products = const [],
    required this.onCategorySelect,
  });

  static IconData _resolveCategoryIcon(String iconName) {
    switch (iconName.trim().toLowerCase()) {
      case 'filter_alt':
        return Icons.filter_alt_outlined;
      case 'layers':
        return Icons.layers_outlined;
      case 'settings_input_component':
        return Icons.settings_input_component_outlined;
      case 'bolt':
        return Icons.bolt_rounded;
      case 'home_repair_service':
        return Icons.home_repair_service_outlined;
      case 'plumbing':
        return Icons.plumbing_rounded;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  String _priceHintForCategory(CatalogCategory cat) {
    final matching = products.where((p) {
      if (p.categorySlugs.contains(cat.slug) || p.categoryId == cat.slug) {
        return true;
      }
      if (cat.slug == 'service-kits' && p.isKit) return true;
      return false;
    }).toList();

    if (matching.isNotEmpty) {
      int minPrice = matching.first.sellingPrice;
      for (final p in matching) {
        if (p.sellingPrice > 0 && p.sellingPrice < minPrice) {
          minPrice = p.sellingPrice;
        }
      }
      return 'Starting from ₹$minPrice';
    }
    return cat.subtitle.isNotEmpty ? cat.subtitle : 'Genuine CBM Spares';
  }

  @override
  Widget build(BuildContext context) {
    final homeCats = categories.where((c) => c.onlineVisible && c.homeVisible).toList();
    final visibleCats = homeCats.isNotEmpty
        ? homeCats
        : categories.where((c) => c.onlineVisible).toList();
    if (visibleCats.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Title: "Shop RO Spare Parts" (Matches Web App Reference) + Pan-India Online Badge
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Shop RO Spare Parts',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFA7F3D0)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.local_shipping_outlined,
                      size: 12,
                      color: Color(0xFF047857),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Pan-India Courier',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF047857),
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 2-Column Responsive Category Card Grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double cardWidth = (constraints.maxWidth - 12) / 2;
              final double textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3);
              final double targetCardHeight = 238.0 + ((textScale - 1.0) * 60.0);
              final double childAspectRatio = (cardWidth / targetCardHeight).clamp(0.60, 0.80);

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: childAspectRatio,
                ),
                itemCount: visibleCats.length,
                itemBuilder: (context, index) {
                  final cat = visibleCats[index];
                  final hint = _priceHintForCategory(cat);
                  return BouncingWidget(
                    onTap: () => onCategorySelect(cat.slug),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: const Color(0xFFE2E8F0),
                          width: 0.8,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Product / Category Image Area (S3 or crisp vector icon)
                          Expanded(
                            child: Container(
                              width: double.infinity,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(17.2),
                                ),
                              ),
                              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                              child: Center(
                                child: CatalogNetworkImage(
                                  imageUrl: cat.imageUrl,
                                  fit: BoxFit.contain,
                                  fallbackIcon: _resolveCategoryIcon(cat.iconName),
                                  fallbackIconSize: 42,
                                  fallbackIconColor: const Color(0xFF0284C7),
                                ),
                              ),
                            ),
                          ),

                          // Information & "Shop →" Action
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Category Title
                                Text(
                                  cat.name,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1D1D1F),
                                    letterSpacing: -0.3,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),

                                // Starting Price or Subtitle (Apple Blue)
                                Text(
                                  hint,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0071E3),
                                    letterSpacing: -0.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),

                                // "Shop →" Pill Link
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Shop',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFFEA580C),
                                        ),
                                      ),
                                      SizedBox(width: 4),
                                      Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 13,
                                        color: Color(0xFFEA580C),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
