import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/product.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';
import 'catalog_network_image.dart';

class ProductCard extends StatefulWidget {
  final Product product;
  final CartState cartState;
  final VoidCallback onTap;

  const ProductCard({
    super.key,
    required this.product,
    required this.cartState,
    required this.onTap,
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  bool _justAdded = false;

  @override
  Widget build(BuildContext context) {
    final currencyFormatter = NumberFormat.decimalPattern('en_IN');
    final formattedPrice = currencyFormatter.format(widget.product.sellingPrice);
    final formattedMrp = currencyFormatter.format(widget.product.mrp);

    return BouncingWidget(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xFFE2E8F0),
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Clean Minimal Image Stage + Discount / Status Badge
            Container(
              height: 98,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: CatalogNetworkImage(
                        imageUrl: widget.product.image,
                        cacheHeight: 200,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  if (widget.product.discountPercent > 0)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'UPTO ${widget.product.discountPercent}% OFF',
                          style: const TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF15803D),
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // 2. Clean 2-Line Product Name
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 31),
              child: Text(
                widget.product.name,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                  height: 1.22,
                  letterSpacing: -0.2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            const SizedBox(height: 4),

            // 3. Single Clean Metadata Line (Trust + Factory Direct Price)
            Row(
              children: [
                const Icon(Icons.star_rounded, size: 12.5, color: Color(0xFFF59E0B)),
                const SizedBox(width: 2),
                Text(
                  widget.product.reviewsCount > 0
                      ? '(${widget.product.reviewsCount})'
                      : 'CBM Verified',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Flexible(
                  child: Text(
                    'Factory Direct Price',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: Color(0xFF15803D),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),

            const Spacer(),

            // 4. Clean Price Row (Price + Crossed MRP)
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '₹$formattedPrice',
                  style: const TextStyle(
                    fontSize: 15.0,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.4,
                  ),
                ),
                if (widget.product.mrp > widget.product.sellingPrice) ...[
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '₹$formattedMrp',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF94A3B8),
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 7),

            // 5. Full-Width Action Button
            SizedBox(
              width: double.infinity,
              height: 34,
              child: ElevatedButton(
                onPressed: () {
                  if (!widget.product.inStock || !widget.product.onlineSellingEnabled) {
                    widget.onTap();
                    return;
                  }
                  HapticFeedback.lightImpact();
                  final added = widget.cartState.addToCart(widget.product);
                  if (!added) return;
                  setState(() => _justAdded = true);
                  Future.delayed(const Duration(milliseconds: 900), () {
                    if (mounted) setState(() => _justAdded = false);
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${widget.product.name} added to cart'),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: !widget.product.inStock
                      ? const Color(0xFFFEF2F2)
                      : (!widget.product.onlineSellingEnabled
                          ? const Color(0xFFF1F5F9)
                          : (_justAdded ? const Color(0xFF16A34A) : const Color(0xFF0284C7))),
                  foregroundColor: !widget.product.inStock
                      ? const Color(0xFFB91C1C)
                      : (!widget.product.onlineSellingEnabled
                          ? const Color(0xFF334155)
                          : Colors.white),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  padding: EdgeInsets.zero,
                ),
                child: !widget.product.inStock
                    ? const Text(
                        'Out of Stock',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      )
                    : (!widget.product.onlineSellingEnabled
                        ? const Text(
                            'View Details',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          )
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            child: _justAdded
                                ? const Row(
                                    key: ValueKey('added'),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.check_circle_rounded, size: 14, color: Colors.white),
                                      SizedBox(width: 5),
                                      Text(
                                        'ADDED ✓',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -0.2,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  )
                                : const Row(
                                    key: ValueKey('add'),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_shopping_cart_rounded, size: 14, color: Colors.white),
                                      SizedBox(width: 5),
                                      Text(
                                        'Add to Cart',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                          )),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
