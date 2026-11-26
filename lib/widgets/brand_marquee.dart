import 'package:flutter/material.dart';
import 'bouncing_widget.dart';

class _BrandCompatibilityItem {
  final String name;
  final String logo;

  const _BrandCompatibilityItem({required this.name, required this.logo});
}

const List<_BrandCompatibilityItem> _universalBrandItems = [
  _BrandCompatibilityItem(name: 'AO Smith', logo: 'assets/brands/aosmith.png'),
  _BrandCompatibilityItem(name: 'LG Puricare', logo: 'assets/brands/lg.png'),
  _BrandCompatibilityItem(name: 'Voltas', logo: 'assets/brands/voltas.png'),
  _BrandCompatibilityItem(name: 'ZeroB', logo: 'assets/brands/zerob.png'),
  _BrandCompatibilityItem(name: 'Kent RO', logo: 'assets/brands/kent.png'),
  _BrandCompatibilityItem(name: 'Aquaguard', logo: 'assets/brands/aquaguard.png'),
  _BrandCompatibilityItem(name: 'Pureit', logo: 'assets/brands/pureit.png'),
  _BrandCompatibilityItem(name: 'Livpure', logo: 'assets/brands/livpure.png'),
  _BrandCompatibilityItem(name: 'Havells', logo: 'assets/brands/havells.png'),
  _BrandCompatibilityItem(name: 'Blue Star', logo: 'assets/brands/bluestar.png'),
  _BrandCompatibilityItem(name: 'Eureka Forbes', logo: 'assets/brands/eurekaforbes.png'),
  _BrandCompatibilityItem(name: 'All 10" Systems', logo: 'assets/brands/all-systems.png'),
];

class BrandMarquee extends StatefulWidget {
  const BrandMarquee({super.key});

  @override
  State<BrandMarquee> createState() => _BrandMarqueeState();
}

class _BrandMarqueeState extends State<BrandMarquee> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final GlobalKey _measureKey = GlobalKey();
  double _singleSetWidth = 1450.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureWidth();
    });
  }

  void _measureWidth() {
    final box = _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.size.width > 0 && mounted) {
      final measuredWidth = box.size.width;
      if ((measuredWidth - _singleSetWidth).abs() > 1) {
        setState(() {
          _singleSetWidth = measuredWidth;
          final durationSec = (_singleSetWidth / 35).clamp(20.0, 60.0);
          _controller.duration = Duration(milliseconds: (durationSec * 1000).round());
          if (!_controller.isAnimating) {
            _controller.repeat();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 14),
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: UNIVERSAL COMPATIBILITY: matching web app reference
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'UNIVERSAL COMPATIBILITY:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF334155),
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Continuous Marquee moving from Left to Right
          Builder(
            builder: (context) {
              final double marqueeHeight = 38.0 * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.25);
              return SizedBox(
                height: marqueeHeight,
                child: GestureDetector(
                  onTapDown: (_) => _controller.stop(),
                  onTapUp: (_) => _controller.repeat(),
                  onTapCancel: () => _controller.repeat(),
                  child: ClipRect(
                    child: OverflowBox(
                      minWidth: 0.0,
                      maxWidth: double.infinity,
                      minHeight: marqueeHeight,
                      maxHeight: marqueeHeight,
                      alignment: Alignment.centerLeft,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      // Moves from left to right smoothly and loops seamlessly
                      final dx = -_singleSetWidth + (_controller.value * _singleSetWidth);
                      return Transform.translate(
                        offset: Offset(dx, 0),
                        child: child,
                      );
                    },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildChipSet(key: _measureKey),
                          _buildChipSet(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChipSet({Key? key}) {
    return Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: _universalBrandItems.map((item) => _buildChip(item)).toList(),
    );
  }

  Widget _buildChip(_BrandCompatibilityItem item) {
    return BouncingWidget(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('100% Genuine spares compatible with ${item.name}'),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: const Color(0xFFE2E8F0),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Actual Company/Brand Logo
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.asset(
                item.logo,
                width: 22,
                height: 22,
                cacheWidth: 66,
                cacheHeight: 66,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: Color(0xFF0284C7),
                  );
                },
              ),
            ),
            const SizedBox(width: 7),
            // Brand Name
            Text(
              item.name,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
