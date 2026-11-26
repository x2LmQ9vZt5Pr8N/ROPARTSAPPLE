import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/product.dart';
import '../state/cart_state.dart';
import '../utils/unit_helper.dart';
import 'bouncing_widget.dart';
import 'catalog_network_image.dart';

class ProductDetailSheet extends StatelessWidget {
  final Product product;
  final CartState cartState;

  const ProductDetailSheet({
    super.key,
    required this.product,
    required this.cartState,
  });

  Future<void> _openYouTubeVideo(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Opening video: $url'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cartState,
      builder: (context, child) {
        final qty = cartState.getQuantity(product.id);

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
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
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),

              // 2. Top Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.verified_rounded, size: 13, color: Color(0xFF0284C7)),
                          const SizedBox(width: 4),
                          Text(
                            product.brand.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0284C7),
                              letterSpacing: 0.3,
                            ),
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
                          color: Color(0xFFF1F5F9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE2E8F0)),

              // 3. Scrollable Detailed Content
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  children: [
                    // Product Image Box (Supports multi-photo S3 gallery swipe)
                    Builder(
                      builder: (context) {
                        final images = product.galleryUrls.isNotEmpty
                            ? product.galleryUrls
                            : (product.image.trim().isNotEmpty ? [product.image.trim()] : const <String>[]);
                        return Container(
                          height: 220,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(19),
                            child: images.length > 1
                                ? Stack(
                                    children: [
                                      PageView.builder(
                                        itemCount: images.length,
                                        itemBuilder: (ctx, idx) => Center(
                                          child: CatalogNetworkImage(
                                            imageUrl: images[idx],
                                            fit: BoxFit.contain,
                                            fallbackIconSize: 80,
                                            fallbackIconColor: const Color(0xFF0284C7),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        right: 10,
                                        bottom: 10,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.6),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            '${images.length} photos • Swipe',
                                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : Center(
                                    child: CatalogNetworkImage(
                                      imageUrl: images.isNotEmpty ? images.first : null,
                                      fit: BoxFit.contain,
                                      fallbackIconSize: 80,
                                      fallbackIconColor: const Color(0xFF0284C7),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),

                    // Title & In-Stock Status
                    Text(
                      product.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.4,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 8),

                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded, size: 14, color: Color(0xFFD97706)),
                              const SizedBox(width: 4),
                              Text(
                                '${product.rating}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF92400E),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          product.reviewsCount > 0
                              ? '${product.reviewsCount} verified buyers'
                              : 'CBM Certified Genuine Spare',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: product.onlineSellingEnabled
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF0284C7),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              product.onlineSellingEnabled
                                  ? 'In Stock (Online Store)'
                                  : 'Technician Visit / Service Supply Only',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: product.onlineSellingEnabled
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF0284C7),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Price & Savings Box
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            !product.isKit &&
                                    ProductUnitHelper.resolveUnit({
                                      'sku': product.sku,
                                      'name': product.name,
                                      'short_description': product.shortDescription,
                                      'unit': product.unit,
                                      'unit_mode': product.unitMode,
                                    }) == ProductUnitHelper.unitMeter
                                ? '₹${product.mrp} / meter'
                                : '₹${product.mrp}',
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.6,
                            ),
                          ),
                          const Text(
                            'MRP',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF64748B),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0F2FE),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Coupons apply at Checkout',
                              style: TextStyle(
                                color: Color(0xFF0369A1),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),

                    // 4. LIFE IN LITERS (Lifespan Card)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.water_drop_rounded, color: Color(0xFF16A34A), size: 28),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'CERTIFIED PURIFICATION LIFE',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF15803D),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${product.lifeInLiters} • ${product.lifeDuration}',
                                  style: const TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF0F172A),
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  'Rated for 25–30 Liters daily purification (standard family of 4). Zero TDS rejection loss across life cycle.',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF334155),
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 4b. INCLUDED KIT BOM COMPONENTS (Live CBM Recipe Parts)
                    if (product.kitComponents.isNotEmpty) ...[
                      const Text(
                        'Included Genuine Components',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          children: product.kitComponents.map((comp) {
                            final csku = (comp['sku'] ?? comp['product_sku'] ?? '').toString();
                            final cmrp = comp['unit_mrp'] ?? comp['mrp'];
                            final cspec = (comp['short_badge'] ?? comp['cbm_spec_label'] ?? '').toString();
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFFE2E8F0)),
                                    ),
                                    child: CatalogNetworkImage(
                                      imageUrl: comp['image_url']?.toString(),
                                      fit: BoxFit.contain,
                                      fallbackIconSize: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ProductUnitHelper.formatBomOrFreeName(comp),
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                        if (csku.isNotEmpty || cspec.isNotEmpty)
                                          Text(
                                            [csku, if (cspec.isNotEmpty) cspec].where((s) => s.isNotEmpty).join(' • '),
                                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (cmrp != null)
                                    Text(
                                      '₹${num.tryParse(cmrp.toString())?.round() ?? cmrp}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF334155),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // 4c. COMPLIMENTARY FREE SPARES INCLUDED OUTSIDE POUCH (KIT COUPLED)
                    if (product.freeSpares.isNotEmpty) ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Sealed Free Spares Included',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          if (product.freeSparesValue > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: const Color(0xFF86EFAC)),
                              ),
                              child: Text(
                                'Worth ₹${product.freeSparesValue.round()} FREE',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF15803D),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFBBF7D0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ...product.freeSpares.map((comp) {
                              final csku = (comp['sku'] ?? comp['product_sku'] ?? '').toString();
                              final cmrp = comp['line_mrp'] ?? comp['unit_mrp'] ?? comp['mrp'];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.card_giftcard_rounded, color: Color(0xFF16A34A), size: 18),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            ProductUnitHelper.formatBomOrFreeName(comp),
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF0F172A),
                                            ),
                                          ),
                                          if (csku.isNotEmpty)
                                            Text(
                                              '$csku • Sealed inside pouch (FREE Online & Doorstep)',
                                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF15803D)),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        if (cmrp != null && (num.tryParse(cmrp.toString()) ?? 0) > 0)
                                          Text(
                                            '₹${num.tryParse(cmrp.toString())?.round() ?? cmrp}',
                                            style: const TextStyle(
                                              fontSize: 10.5,
                                              color: Color(0xFF64748B),
                                              decoration: TextDecoration.lineThrough,
                                            ),
                                          ),
                                        const Text(
                                          'FREE',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFF15803D),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // 5. IN-DEPTH DETAILED DESCRIPTION
                    const Text(
                      'Detailed Product Engineering & Overview',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        product.effectiveDetailedDescription,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF334155),
                          height: 1.5,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 6. KEY FEATURES (Bullet Points)
                    const Text(
                      'Key Engineered Features',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: product.effectiveKeyFeatures.map((feat) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF0284C7), size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  feat,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1E293B),
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )).toList(),
                      ),
                    ),
                    const SizedBox(height: 22),

                    // 7. HOW OUR PRODUCT IS BETTER THAN LOCAL PRODUCTS
                    if (product.effectiveComparisons.isNotEmpty) ...[
                      const Row(
                        children: [
                          Icon(Icons.verified_user_rounded, color: Color(0xFF16A34A), size: 22),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Why ROParts Beats Local Copies',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Why using certified spares protects your family health & purifier warranty:',
                        style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 12),

                      ...product.effectiveComparisons.map((c) => Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.02),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.feature.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF64748B),
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Genuine ROParts Card
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFDCFCE7)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: RichText(
                                      text: TextSpan(
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF14532D), height: 1.35),
                                        children: [
                                          const TextSpan(text: 'ROParts Genuine: ', style: TextStyle(fontWeight: FontWeight.w900)),
                                          TextSpan(text: c.roparts),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),

                            // Local Market Copy Card
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFFEE2E2)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.cancel_rounded, color: Color(0xFFDC2626), size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: RichText(
                                      text: TextSpan(
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF7F1D1D), height: 1.35),
                                        children: [
                                          const TextSpan(text: 'Local Market: ', style: TextStyle(fontWeight: FontWeight.w900)),
                                          TextSpan(text: c.localMarket),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      )),
                      const SizedBox(height: 20),
                    ],

                    // 8. YOUTUBE VIDEO CARD (only when admin configures a YouTube URL)
                    if (product.youtubeVideoUrl.trim().isNotEmpty) ...[
                      const Row(
                        children: [
                          Icon(Icons.smart_display_rounded, color: Color(0xFFFF0000), size: 22),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Watch Lab Testing & Teardown Video',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Watch live pressure burst, TDS rejection & interior material inspection:',
                        style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 12),
                      BouncingWidget(
                        onTap: () => _openYouTubeVideo(context, product.youtubeVideoUrl),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            children: [
                              // Thumbnail Preview
                              SizedBox(
                                height: 180,
                                width: double.infinity,
                                child: Opacity(
                                  opacity: 0.45,
                                  child: CatalogNetworkImage(
                                    imageUrl: product.image,
                                    fit: BoxFit.cover,
                                    fallbackIcon: Icons.videocam_rounded,
                                    fallbackIconSize: 64,
                                    fallbackIconColor: Colors.white24,
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.85),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Top Tag
                              Positioned(
                                top: 12,
                                left: 14,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF0000),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
                                      SizedBox(width: 4),
                                      Text(
                                        'YOUTUBE DEMO',
                                        style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // Center Play Icon
                              Positioned.fill(
                                child: Center(
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF0000),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFFFF0000).withValues(alpha: 0.6),
                                          blurRadius: 18,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
                                  ),
                                ),
                              ),
                              // Bottom Title & Duration
                              Positioned(
                                bottom: 12,
                                left: 14,
                                right: 14,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            product.youtubeVideoTitle,
                                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          const Text(
                                            'Tap to watch teardown lab video on YouTube',
                                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.8),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text('VIDEO', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                    ],

                    // 9. TRUST GUARANTEE PILL STRIP
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.shield_rounded, color: Color(0xFF0284C7), size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'ROParts Genuine Trust Commitments',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _buildTrustPill('ISO 9001', 'Tested Lab'),
                              const SizedBox(width: 8),
                              _buildTrustPill('1-Yr Warranty', 'Direct Swap'),
                              const SizedBox(width: 8),
                              _buildTrustPill('BPA-Free', 'Food Safe'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 10. TECHNICAL SPECIFICATIONS TABLE
                    if (product.specifications.isNotEmpty) ...[
                      const Text(
                        'Technical Specifications',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Column(
                            children: product.specifications.entries.map((e) {
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: Color(0xFFE2E8F0), width: 0.6),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        e.key,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF64748B),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        e.value,
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // 11. COMPATIBLE MACHINES
                    if (product.compatibility.isNotEmpty) ...[
                      const Text(
                        'Universal Compatibility',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: product.compatibility.map((m) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                            child: Text(
                              m,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF334155),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),

              // 12. STICKY BOTTOM ACTION BAR
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    top: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: !product.inStock
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFFECACA)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.remove_shopping_cart_outlined, size: 18, color: Color(0xFFB91C1C)),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Currently Out of Stock',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFFB91C1C),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : !product.onlineSellingEnabled
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFCBD5E1)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.handyman_outlined, size: 18, color: Color(0xFF0284C7)),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Installed by Technician During Visit (Not sold online)',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            if (qty > 0) ...[
                              Container(
                                height: 46,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: const Color(0xFFCBD5E1)),
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.remove, size: 16, color: Color(0xFF0F172A)),
                                      onPressed: () => cartState.decrementQuantity(product),
                                    ),
                                    Text(
                                      '$qty in cart',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add, size: 16, color: Color(0xFF0284C7)),
                                      onPressed: () => cartState.addToCart(product),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: SizedBox(
                                height: 46,
                                child: ElevatedButton(
                                  onPressed: () {
                                    if (qty == 0) cartState.addToCart(product);
                                    Navigator.pop(context);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0284C7),
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: Text(
                                    qty == 0 ? 'ADD TO CART • ₹${product.mrp}' : 'DONE',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _buildTrustPill(String title, String subtitle) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0284C7)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
