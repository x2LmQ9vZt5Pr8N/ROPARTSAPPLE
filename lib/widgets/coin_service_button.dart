import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/happy_hour_helper.dart';
import 'bouncing_widget.dart';

/// Exact 3D Golden Flipping Coin from ROParts.in Website.
/// Features:
/// - Perspective 3D rotation around Y-axis (Matrix4 perspective)
/// - Authentic Indian milled beaded ring and gold radial gradient
/// - Normal: Side 1 (Front): "BOOK QUICK SERVICE" / Side 2 (Back): "RO SERVICE ₹49 ONLY"
/// - Free Hour: Side 1 (Front): "FREE RO SERVICE" / Side 2 (Back): "FREE HOUR ₹0 FREE"
class CoinServiceButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool? isFreeHourOverride;

  const CoinServiceButton({
    super.key,
    required this.onTap,
    this.isFreeHourOverride,
  });

  @override
  State<CoinServiceButton> createState() => _CoinServiceButtonState();
}

class _CoinServiceButtonState extends State<CoinServiceButton> with SingleTickerProviderStateMixin {
  late final AnimationController _flipController;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 7200),
    )..repeat();

    HappyHourHelper.changeNotifier.addListener(_onHelperStateChanged);
  }

  void _onHelperStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _flipController.dispose();
    HappyHourHelper.changeNotifier.removeListener(_onHelperStateChanged);
    super.dispose();
  }

  double _getRotationAngle(double t) {
    if (t < 0.42) {
      return 0.0;
    } else if (t < 0.50) {
      final progress = (t - 0.42) / (0.50 - 0.42);
      final curved = Curves.easeInOutCubic.transform(progress);
      return curved * pi;
    } else if (t < 0.92) {
      return pi;
    } else {
      final progress = (t - 0.92) / (1.00 - 0.92);
      final curved = Curves.easeInOutCubic.transform(progress);
      return pi + (curved * pi);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isHappyHour = widget.isFreeHourOverride ?? HappyHourHelper.isHappyHourLive();

    return BouncingWidget(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _flipController,
        builder: (context, _) {
          final angle = _getRotationAngle(_flipController.value);
          final isBackFace = (angle >= pi / 2) && (angle <= 3 * pi / 2);

          return Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: isHappyHour
                      ? const Color(0xFF16A34A).withValues(alpha: 0.35)
                      : const Color(0xFFB45309).withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0016)
                ..rotateY(angle),
              child: isBackFace
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(pi),
                      child: _buildBackFace(isHappyHour),
                    )
                  : _buildFrontFace(isHappyHour),
            ),
          );
        },
      ),
    );
  }

  /// Front Face: "BOOK QUICK SERVICE" or "FREE RO SERVICE"
  Widget _buildFrontFace(bool isHappyHour) {
    return _buildCoinBase(
      isHappyHour: isHappyHour,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isHappyHour ? Icons.celebration_rounded : Icons.home_repair_service_rounded,
            size: 16,
            color: isHappyHour ? const Color(0xFF065F46) : const Color(0xFF78350F),
          ),
          const SizedBox(height: 1),
          Text(
            isHappyHour ? 'FREE' : 'BOOK',
            style: TextStyle(
              fontSize: isHappyHour ? 9.5 : 8.5,
              fontWeight: FontWeight.w900,
              color: isHappyHour ? const Color(0xFF064E3B) : const Color(0xFF78350F),
              letterSpacing: 0.7,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            isHappyHour ? 'RO' : 'QUICK',
            style: TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w900,
              color: isHappyHour ? const Color(0xFF065F46) : const Color(0xFF92400E),
              letterSpacing: 0.6,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            'SERVICE',
            style: TextStyle(
              fontSize: 7.0,
              fontWeight: FontWeight.w900,
              color: isHappyHour ? const Color(0xFF064E3B) : const Color(0xFF78350F),
              letterSpacing: 0.7,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// Back Face: "FREE ₹0" during Happy Hour vs "₹49 ONLY"
  Widget _buildBackFace(bool isHappyHour) {
    return _buildCoinBase(
      isHappyHour: isHappyHour,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            isHappyHour ? 'FREE HOUR' : 'RO SERVICE',
            style: TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w900,
              color: isHappyHour ? const Color(0xFF064E3B) : const Color(0xFF78350F),
              letterSpacing: 0.6,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),

          // Main Price: ₹0 vs ₹49
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '₹',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isHappyHour ? const Color(0xFF065F46) : const Color(0xFF78350F),
                  height: 1.0,
                ),
              ),
              Text(
                '${isHappyHour ? 0 : HappyHourHelper.currentInspectionFee}',
                style: TextStyle(
                  fontSize: isHappyHour ? 22 : 18,
                  fontWeight: FontWeight.w900,
                  color: isHappyHour ? const Color(0xFF022C22) : const Color(0xFF451A03),
                  letterSpacing: -0.6,
                  height: 1.0,
                ),
              ),
            ],
          ),

          const SizedBox(height: 1),

          // Subtitle: FREE VISIT vs ONLY
          Text(
            isHappyHour ? 'FREE' : 'ONLY',
            style: TextStyle(
              fontSize: isHappyHour ? 8.0 : 7.5,
              fontWeight: FontWeight.w900,
              color: isHappyHour ? const Color(0xFF065F46) : const Color(0xFF92400E),
              letterSpacing: 1.1,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// Shared authentic Indian coin base with milled beaded border and gloss highlight
  Widget _buildCoinBase({required Widget child, required bool isHappyHour}) {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Green Radial gradient when Free Hour is live, Gold otherwise
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.44),
          radius: 0.88,
          colors: isHappyHour
              ? const [
                  Color(0xFFECFDF5), // #ecfdf5 0%
                  Color(0xFFA7F3D0), // #a7f3d0 22%
                  Color(0xFF34D399), // #34d399 48%
                  Color(0xFF10B981), // #10b981 72%
                  Color(0xFF047857), // #047857 100%
                ]
              : const [
                  Color(0xFFFFFBEB), // #fffbeb 0%
                  Color(0xFFFEF08A), // #fef08a 22%
                  Color(0xFFFACC15), // #facc15 48%
                  Color(0xFFEAB308), // #eab308 72%
                  Color(0xFFB45309), // #b45309 100%
                ],
          stops: const [0.0, 0.22, 0.48, 0.72, 1.0],
        ),
        border: Border.all(
          color: isHappyHour ? const Color(0xFFA7F3D0) : const Color(0xFFFEF08A),
          width: 2.0,
        ),
        boxShadow: isHappyHour
            ? const [
                BoxShadow(
                  color: Color(0xFF059669),
                  spreadRadius: 1.5,
                ),
                BoxShadow(
                  color: Color(0xFF047857),
                  spreadRadius: 2.8,
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0xFFD97706),
                  spreadRadius: 1.5,
                ),
                BoxShadow(
                  color: Color(0xFF92400E),
                  spreadRadius: 2.8,
                ),
              ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Inner Milled / Beaded Ring (Indian Coin pattern)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: CustomPaint(
                painter: _CoinBeadedRingPainter(isHappyHour: isHappyHour),
              ),
            ),
          ),

          // Top Gloss Highlight Arc
          Positioned(
            top: 4,
            left: 14,
            right: 14,
            height: 14,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.65),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),

          // Face Content
          child,
        ],
      ),
    );
  }
}

/// Custom Painter for the Milled / Beaded Rim dots on Indian Coins
class _CoinBeadedRingPainter extends CustomPainter {
  final bool isHappyHour;

  _CoinBeadedRingPainter({this.isHappyHour = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isHappyHour
          ? const Color(0xFF064E3B).withValues(alpha: 0.45)
          : const Color(0xFF78350F).withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 1.5;
    const int dotCount = 28;

    for (int i = 0; i < dotCount; i++) {
      final angle = (i * 2 * pi) / dotCount;
      final x = center.dx + (radius * cos(angle));
      final y = center.dy + (radius * sin(angle));
      canvas.drawCircle(Offset(x, y), 0.9, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CoinBeadedRingPainter oldDelegate) =>
      oldDelegate.isHappyHour != isHappyHour;
}
