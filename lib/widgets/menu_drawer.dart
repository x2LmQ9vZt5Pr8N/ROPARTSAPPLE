import 'package:flutter/material.dart';
import '../state/cart_state.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';
import 'auth_sheet.dart';

class MenuDrawerSheet extends StatelessWidget {
  final CartState cartState;
  final VoidCallback? onProfileTap;
  final VoidCallback? onCartTap;
  final VoidCallback? onOrdersTap;
  final VoidCallback? onServiceHistoryTap;
  final VoidCallback? onWarrantyVaultTap;
  final VoidCallback? onReferEarnTap;
  final VoidCallback? onKnowAboutRoTap;
  final VoidCallback? onTrackTap;
  final VoidCallback? onShippingTap;
  final VoidCallback? onRefundsTap;
  final VoidCallback? onPrivacyTap;
  final VoidCallback? onTermsTap;
  final String userName;
  final String userPhone;

  const MenuDrawerSheet({
    super.key,
    required this.cartState,
    this.onProfileTap,
    this.onCartTap,
    this.onOrdersTap,
    this.onServiceHistoryTap,
    this.onWarrantyVaultTap,
    this.onReferEarnTap,
    this.onKnowAboutRoTap,
    this.onTrackTap,
    this.onShippingTap,
    this.onRefundsTap,
    this.onPrivacyTap,
    this.onTermsTap,
    this.userName = 'Valued Customer',
    this.userPhone = '',
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.92,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Drag Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // 2. Menu Header [ Menu               X ]
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Menu',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 3. Header Divider
            const Divider(
              height: 1,
              thickness: 1,
              color: Color(0xFFF1F5F9),
            ),

            // 4. Vertical Menu Item List - Exactly in requested order
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                children: [
                  // 1. Profile / Login
                  cartState.isLoggedIn
                      ? _buildMenuCard(
                          icon: Icons.person_outline_rounded,
                          iconColor: const Color(0xFF0284C7),
                          iconBg: const Color(0xFFEFF6FF),
                          title: cartState.userName.isNotEmpty ? cartState.userName : 'My Account',
                          subtitle: '${PhoneNormalizer.formatIndianPhone(cartState.userPhone)} • Profile & account',
                          badge: 'VERIFIED',
                          badgeColor: const Color(0xFF16A34A),
                          onTap: () => _safeCloseAndRun(context, onProfileTap),
                        )
                      : _buildMenuCard(
                          icon: Icons.chat_bubble_rounded,
                          iconColor: const Color(0xFF16A34A),
                          iconBg: const Color(0xFFDCFCE7),
                          title: 'Login or Sign Up',
                          subtitle: 'Instant WhatsApp OTP verification',
                          badge: 'LOGIN',
                          badgeColor: const Color(0xFF16A34A),
                          onTap: () {
                            final nav = Navigator.of(context);
                            nav.pop();
                            if (nav.context.mounted) {
                              AuthSheet.show(nav.context, cartState: cartState);
                            }
                          },
                        ),

                  // 2. Cart
                  _buildMenuCard(
                    icon: Icons.shopping_cart_outlined,
                    iconColor: const Color(0xFFEA580C),
                    iconBg: const Color(0xFFFFEDD5),
                    title: 'Cart',
                    badge: cartState.itemCount > 0 ? '${cartState.itemCount}' : null,
                    badgeColor: const Color(0xFFEA580C),
                    subtitle: cartState.itemCount == 0
                        ? 'Your cart is currently empty'
                        : '${cartState.itemCount} items in cart • ₹${cartState.totalAmount}',
                    onTap: () => _safeCloseAndRun(context, onCartTap),
                  ),

                  // 3. Orders (Improved Order Tracking)
                  _buildMenuCard(
                    icon: Icons.inventory_2_outlined,
                    iconColor: const Color(0xFF7C3AED),
                    iconBg: const Color(0xFFF3E8FF),
                    title: 'Orders',
                    subtitle: 'View order history, nested kits & status',
                    onTap: () => _safeCloseAndRun(context, onOrdersTap),
                  ),

                  // 5. Refer and Earn
                  _buildMenuCard(
                    icon: Icons.card_giftcard_rounded,
                    iconColor: const Color(0xFF059669),
                    iconBg: const Color(0xFFECFDF5),
                    title: 'Refer and Earn',
                    badge: 'GET ₹150',
                    badgeColor: const Color(0xFF059669),
                    subtitle: 'Invite friends & get ₹150 discount',
                    onTap: () => _safeCloseAndRun(context, onReferEarnTap),
                  ),

                  // 7. Know and Learn About RO
                  _buildMenuCard(
                    icon: Icons.school_outlined,
                    iconColor: const Color(0xFF4F46E5),
                    iconBg: const Color(0xFFEEF2FF),
                    title: 'Know and Learn About RO',
                    subtitle: 'Water TDS guide, filter care & DIY guide',
                    onTap: () => _safeCloseAndRun(context, onKnowAboutRoTap),
                  ),

                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFFE2E8F0), height: 1),
                  const SizedBox(height: 12),

                  // Support & Policies Section (Symmetric 2x2 grid + flush full-width Terms row)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'HELP & LEGAL POLICIES',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF94A3B8),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  Row(
                    children: [
                      Expanded(
                        child: _buildPolicyTile(
                          icon: Icons.inventory_2_outlined,
                          title: 'Track Order',
                          onTap: () => _safeCloseAndRun(context, onTrackTap),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildPolicyTile(
                          icon: Icons.local_shipping_outlined,
                          title: 'Shipping Policy',
                          onTap: () => _safeCloseAndRun(context, onShippingTap),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildPolicyTile(
                          icon: Icons.autorenew_rounded,
                          title: '7-Day Replacement',
                          onTap: () => _safeCloseAndRun(context, onRefundsTap),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildPolicyTile(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Privacy Policy',
                          onTap: () => _safeCloseAndRun(context, onPrivacyTap),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildPolicyTile(
                    icon: Icons.description_outlined,
                    title: 'Terms & Conditions',
                    showChevron: true,
                    onTap: () => _safeCloseAndRun(context, onTermsTap),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPolicyTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool showChevron = false,
  }) {
    return BouncingWidget(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: const Color(0xFFE2E8F0), width: 0.9),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15.5, color: const Color(0xFF475569)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
            ),
            if (showChevron)
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: Color(0xFF94A3B8),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    String? badge,
    Color? badgeColor,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.5),
      child: BouncingWidget(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFFE2E8F0),
              width: 1.0,
            ),
          ),
          child: Row(
            children: [
              // Left Icon Container
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: 21,
                  color: iconColor,
                ),
              ),
              const SizedBox(width: 12),

              // Title, Badge, and Subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: badgeColor ?? const Color(0xFF0284C7),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              badge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2.5),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 6),

              const Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _safeCloseAndRun(BuildContext context, VoidCallback? callback) {
    final nav = Navigator.of(context);
    nav.pop();
    if (callback != null) {
      Future.delayed(const Duration(milliseconds: 120), () {
        if (nav.mounted) callback();
      });
    }
  }
}
