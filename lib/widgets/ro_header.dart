import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';

class RoHeader extends StatelessWidget {
  final CartState cartState;
  final VoidCallback onSearchTap;
  final VoidCallback onCartTap;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onQrScanTap;
  final VoidCallback? onOffersTap;
  final VoidCallback? onPincodeTap;
  final VoidCallback? onProfileTap;

  const RoHeader({
    super.key,
    required this.cartState,
    required this.onSearchTap,
    required this.onCartTap,
    this.onNotificationTap,
    this.onQrScanTap,
    this.onOffersTap,
    this.onPincodeTap,
    this.onProfileTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.94),
            border: const Border(
              bottom: BorderSide(color: AppTheme.borderLight, width: 0.6),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 1. Left Column: Logo on top, Pincode & City below
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/ropartslogo.png',
                      height: 23,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 2),
                    BouncingWidget(
                      onTap: onPincodeTap ?? () {},
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.location_on_rounded,
                            size: 11,
                            color: AppTheme.appleBlue,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              cartState.activeAddress != null
                                  ? '${cartState.activeAddress!.tag}: ${cartState.deliveryPincode} • ${cartState.deliveryCity}'
                                  : '${cartState.deliveryPincode} • ${cartState.deliveryCity}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF475569),
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 1),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 12,
                            color: Color(0xFF94A3B8),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 2. Right Actions: Search Magnifying Glass (🔍), QR Scanner (📷), Cart (🛒)
              _buildIconButton(
                icon: Icons.search_rounded,
                onTap: onSearchTap,
                tooltip: 'Search',
              ),
              if (onQrScanTap != null) ...[
                const SizedBox(width: 4),
                _buildIconButton(
                  icon: Icons.qr_code_scanner_rounded,
                  onTap: onQrScanTap,
                  tooltip: 'Scan Part / Kit QR',
                  accentColor: const Color(0xFF0284C7),
                  bgColor: const Color(0xFFEFF6FF),
                ),
              ] else if (onNotificationTap != null) ...[
                const SizedBox(width: 4),
                _buildIconButton(
                  icon: Icons.notifications_none_rounded,
                  onTap: onNotificationTap,
                  tooltip: 'Notifications',
                ),
              ],
              const SizedBox(width: 4),
              _buildCartButton(
                onTap: onCartTap,
                itemCount: cartState.itemCount,
              ),
              if (onProfileTap != null) ...[
                const SizedBox(width: 4),
                _buildIconButton(
                  icon: cartState.isLoggedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                  onTap: onProfileTap,
                  tooltip: cartState.isLoggedIn ? cartState.userName : 'Login with WhatsApp',
                  accentColor: cartState.isLoggedIn ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
                  bgColor: cartState.isLoggedIn ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    VoidCallback? onTap,
    String? tooltip,
    Color? accentColor,
    Color? bgColor,
  }) {
    return BouncingWidget(
      onTap: onTap ?? () {},
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor ?? AppTheme.cardSurface.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: accentColor != null ? Border.all(color: const Color(0xFFBAE6FD), width: 1.2) : null,
        ),
        child: Icon(
          icon,
          size: 19,
          color: accentColor ?? AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildCartButton({
    required VoidCallback onTap,
    required int itemCount,
  }) {
    return BouncingWidget(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.cardSurface.withValues(alpha: 0.85),
          shape: BoxShape.circle,
        ),
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            const Icon(
              Icons.shopping_bag_outlined,
              size: 19,
              color: AppTheme.textPrimary,
            ),
            if (itemCount > 0)
              Positioned(
                top: -2,
                right: -2,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: CurvedAnimation(parent: anim, curve: Curves.elasticOut),
                    child: child,
                  ),
                  child: Container(
                    key: ValueKey<int>(itemCount),
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppTheme.appleBlue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '$itemCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
