import 'package:flutter/material.dart';
import '../models/product.dart';
import '../state/cart_state.dart';
import '../theme/app_theme.dart';
import 'product_card.dart';

class UniversalSearchSheet extends StatefulWidget {
  final CartState cartState;
  final List<Product>? products;
  final Function(Product product) onProductSelect;

  const UniversalSearchSheet({
    super.key,
    required this.cartState,
    this.products,
    required this.onProductSelect,
  });

  @override
  State<UniversalSearchSheet> createState() => _UniversalSearchSheetState();
}

class _UniversalSearchSheetState extends State<UniversalSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  late List<Product> _catalog;
  late List<Product> _filteredProducts;

  @override
  void initState() {
    super.initState();
    _catalog = List<Product>.from(widget.products ?? const []);
    _filteredProducts = _catalog;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    final tokens = query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    setState(() {
      if (tokens.isEmpty) {
        _filteredProducts = _catalog;
      } else {
        _filteredProducts = _catalog.where((p) {
          final haystack = [
            p.name,
            p.sku,
            p.brand,
            p.shortDescription,
            ...p.compatibility,
          ].join(' ').toLowerCase();
          return tokens.every((token) => haystack.contains(token));
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.viewPaddingOf(context).bottom,
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      child: Column(
        children: [
          // Apple Pull Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0x33000000),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),

          // iOS Search Input Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.2,
                      ),
                      textAlignVertical: TextAlignVertical.center,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search parts, membranes, pumps...',
                        hintStyle: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                          letterSpacing: -0.2,
                        ),
                        prefixIcon: const Icon(Icons.search, color: AppTheme.textSecondary, size: 20),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.cancel, size: 18, color: AppTheme.textSecondary),
                                onPressed: () => _searchController.clear(),
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.appleBlue,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderLight),

          // Apple Style Quick Suggestion Pills
          if (_searchController.text.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    'RO Membrane',
                    'Booster Pump',
                    'Float Switch',
                    'Purifier Tap',
                    'FR 450',
                    'PP Spun',
                    'SMPS 24V',
                  ].map((chip) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => _searchController.text = chip,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F7),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0x14000000)),
                          ),
                          child: Text(
                            chip,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // Results Grid
          Expanded(
            child: _filteredProducts.isEmpty
                ? const Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.search_off_rounded, size: 48, color: AppTheme.textSecondary),
                          SizedBox(height: 10),
                          Text(
                            'No matching spare parts found',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: AppTheme.textPrimary,
                              letterSpacing: -0.3,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Try searching by brand or keyword like membrane, pump, tap',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : Builder(
                    builder: (context) {
                      final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(0.9, 1.15);
                      final double cardExtent = 248.0 + (textScale > 1.0 ? (textScale - 1.0) * 60.0 : 0.0);

                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: cardExtent,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                        itemCount: _filteredProducts.length,
                        itemBuilder: (context, index) {
                          final product = _filteredProducts[index];
                          return ProductCard(
                            product: product,
                            cartState: widget.cartState,
                            onTap: () {
                              Navigator.pop(context);
                              widget.onProductSelect(product);
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
