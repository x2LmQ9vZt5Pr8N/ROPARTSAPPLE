import 'package:flutter/material.dart';
import '../models/maintenance_kit.dart';
import 'bouncing_widget.dart';
import 'catalog_network_image.dart';

class MaintenanceKitsSection extends StatelessWidget {
  final List<MaintenanceKit> kits;
  final Function(MaintenanceKit kit) onKitSelect;
  final VoidCallback? onCompareKits;

  const MaintenanceKitsSection({
    super.key,
    required this.kits,
    required this.onKitSelect,
    this.onCompareKits,
  });

  @override
  Widget build(BuildContext context) {
    if (kits.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Section Header matching ROParts.in Web App
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // # ALL-IN-ONE Pill Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '# ALL-IN-ONE',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 0.3,
                    height: 1.1,
                  ),
                ),
              ),

              const SizedBox(height: 6),

              // Title: RO Maintenance Kits
              const Text(
                'RO Maintenance Kits',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),

              const SizedBox(height: 3),

              // Subtitle: Complete service kits. Save up to 45%.
              const Text(
                'Complete service kits. Save up to 45%.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                  letterSpacing: -0.2,
                ),
              ),

              const SizedBox(height: 6),

              // Action Link: Compare Kits >
              BouncingWidget(
                onTap: onCompareKits ?? () {},
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Compare Kits',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0284C7),
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 11.5,
                      color: Color(0xFF0284C7),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 2. 2-Column Uniform Minimal Grid of Maintenance Kits
        Builder(
          builder: (context) {
            final double textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(0.9, 1.25);
            final double cardExtent = 238.0 + (textScale > 1.0 ? (textScale - 1.0) * 60.0 : 0.0);

            return GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: cardExtent,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: kits.length,
              itemBuilder: (context, index) {
                final kit = kits[index];
                return _MaintenanceKitCard(
                  kit: kit,
                  onTap: () => onKitSelect(kit),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _MaintenanceKitCard extends StatelessWidget {
  final MaintenanceKit kit;
  final VoidCallback onTap;

  const _MaintenanceKitCard({
    required this.kit,
    required this.onTap,
  });

  String _compactSpecLine() {
    final cleanBadge = kit.badge
        .replaceFirst(RegExp(r'^Kit\s*•\s*', caseSensitive: false), '')
        .trim();
    if (kit.items.isNotEmpty) {
      final partsLabel = '${kit.items.length} Parts';
      return cleanBadge.isNotEmpty ? '$partsLabel • $cleanBadge' : partsLabel;
    }
    if (cleanBadge.isNotEmpty && cleanBadge.toLowerCase() != 'kit') {
      return cleanBadge;
    }
    if (kit.desc.trim().isNotEmpty) {
      return kit.desc.trim();
    }
    return 'Complete RO Service Kit';
  }

  @override
  Widget build(BuildContext context) {
    return BouncingWidget(
      onTap: onTap,
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
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Clean Minimal Image Stage with single floating badge
              Container(
                height: 104,
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
                          imageUrl: kit.image,
                          cacheHeight: 200,
                          fit: BoxFit.contain,
                          fallbackIcon: Icons.home_repair_service_outlined,
                          fallbackIconSize: 34,
                        ),
                      ),
                    ),
                    if (!kit.inStock)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'OUT OF STOCK',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFB91C1C),
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      )
                    else if (kit.discountPercent > 0)
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
                            'UPTO ${kit.discountPercent}% OFF',
                            style: const TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF15803D),
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ),
                    if (kit.inStock && kit.isPopular)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'POPULAR',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFB45309),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // 2. Clean 1-line Kit Title
              Text(
                kit.title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                  height: 1.2,
                  letterSpacing: -0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),

              const SizedBox(height: 4),

              // 3. Single concise spec / parts summary line
              Text(
                _compactSpecLine(),
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF64748B),
                  height: 1.25,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              const Spacer(),

              // 4. Clean aligned Price + CTA Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '₹${kit.price}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                            letterSpacing: -0.4,
                            height: 1.05,
                          ),
                        ),
                        if (kit.effectiveMrp > kit.price)
                          Text(
                            '₹${kit.effectiveMrp}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF94A3B8),
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: kit.inStock ? const Color(0xFF0284C7) : const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          kit.inStock ? 'View Kit' : 'Out of Stock',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: kit.inStock ? Colors.white : const Color(0xFFB91C1C),
                          ),
                        ),
                        if (kit.inStock) ...[
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 12,
                            color: Colors.white,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
