import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/happy_hour_helper.dart';
import 'bouncing_widget.dart';

class HappyHourBanner extends StatefulWidget {
  final VoidCallback? onTap;

  const HappyHourBanner({super.key, this.onTap});

  @override
  State<HappyHourBanner> createState() => _HappyHourBannerState();
}

class _HappyHourBannerState extends State<HappyHourBanner> {
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _syncTicker();
    // Listen to SSoT reactive updates from Redis/FCM
    HappyHourHelper.changeNotifier.addListener(_onHelperStateChanged);
  }

  void _syncTicker() {
    if (HappyHourHelper.isEnabled) {
      _countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && HappyHourHelper.isEnabled) {
          HappyHourHelper.checkAndHandleExpiration();
          setState(() {});
        }
      });
    } else {
      _countdownTimer?.cancel();
      _countdownTimer = null;
    }
  }

  void _onHelperStateChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    HappyHourHelper.changeNotifier.removeListener(_onHelperStateChanged);
    super.dispose();
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds <= 0) return '00m 00s';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    }
    return '${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
  }

  void _showTermsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 20,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text('🎉', style: TextStyle(fontSize: 20)),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Free Hour Terms & Conditions',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: Colors.grey.shade600,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTermItem(
                  icon: Icons.check_circle_rounded,
                  color: const Color(0xFF16A34A),
                  title: 'Free Quick Service Inspection',
                  desc:
                      'During active Free Hour windows, the doorstep technician checkup and visit fee is completely FREE (₹0 instead of ₹49).',
                ),
                const SizedBox(height: 12),
                _buildTermItem(
                  icon: Icons.info_outline_rounded,
                  color: const Color(0xFFD97706),
                  title: 'Standard Charges for Overhauls & Parts',
                  desc:
                      'Standard service charges will apply for complete servicing, major overhauls, repairs, or replacement spare parts & filters.',
                ),
                const SizedBox(height: 12),
                _buildTermItem(
                  icon: Icons.verified_user_outlined,
                  color: const Color(0xFF0284C7),
                  title: 'Scope & Availability',
                  desc:
                      'Valid only for domestic RO water purifiers within active operational service hubs.',
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F172A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Understood',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTermItem({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.grey.shade600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLive = HappyHourHelper.isHappyHourLive();
    final hasNext = HappyHourHelper.nextWindow != null &&
        HappyHourHelper.nextWindow!['start_time'] != null;

    // 0. If not live AND no next upcoming window exists, cleanly hide banner (0px)
    if (!HappyHourHelper.isEnabled || (!isLive && !hasNext)) {
      return const SizedBox.shrink();
    }

    final remaining = HappyHourHelper.timeUntilWindow();

    // If active window hit 0, defer expiration handling post-frame (never mutate ValueNotifier during build)
    if (isLive && remaining.inSeconds <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) HappyHourHelper.checkAndHandleExpiration();
      });
      return const SizedBox.shrink();
    }

    final timeStr = _formatDuration(remaining);

    final statusTitle = isLive ? 'Free Hour Active' : 'Next Free Hour';
    final timerLabel = isLive ? 'Ends in $timeStr' : 'Starts in $timeStr';
    final statusColor = isLive ? const Color(0xFF16A34A) : const Color(0xFFD97706);
    final fee = HappyHourHelper.currentInspectionFee;
    final btnText = isLive || fee == 0 ? 'Book Free' : 'Book ₹$fee';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: BouncingWidget(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isLive ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
              width: isLive ? 1.2 : 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isLive
                    ? const Color(0xFF16A34A).withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19.2),
            child: Stack(
              children: [
                // 1. Subtle Celebration Doodle Background
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.70,
                    child: Image.asset(
                      'assets/images/happy_hour_doodle_bg.jpg',
                      cacheWidth: 800,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                    ),
                  ),
                ),

                // 2. Foreground Content
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      // Celebration Squircle Icon Box
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isLive ? const Color(0xFFECFDF5) : const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: isLive ? const Color(0xFFA7F3D0) : const Color(0xFFFDE68A),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isLive
                                  ? const Color(0xFF10B981).withValues(alpha: 0.18)
                                  : const Color(0xFFF59E0B).withValues(alpha: 0.12),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            isLive ? '🎉' : '⏰',
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Title, Live Countdown & * T&C applied
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    statusTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFF0F172A),
                                      letterSpacing: -0.3,
                                      height: 1.15,
                                    ),
                                  ),
                                ),
                                if (isLive) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDCFCE7),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      '₹0 ONLY',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF15803D),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                // Pulsing Live Indicator Dot
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                    boxShadow: isLive
                                        ? [
                                            BoxShadow(
                                              color: statusColor.withValues(alpha: 0.6),
                                              blurRadius: 4,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    timerLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: statusColor,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            // Minimal T&C applied tag with tap to see details
                            GestureDetector(
                              onTap: () => _showTermsSheet(context),
                              child: const Text(
                                '* T&C apply',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Action Button
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          color: isLive ? const Color(0xFF16A34A) : const Color(0xFF18181B),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: isLive
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFF16A34A).withValues(alpha: 0.3),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              btnText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                              ),
                            ),
                            const SizedBox(width: 5),
                            const Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.white,
                              size: 14,
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
        ),
      ),
    );
  }
}
