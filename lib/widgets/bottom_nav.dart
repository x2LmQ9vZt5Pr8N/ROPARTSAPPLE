import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'coin_service_button.dart';
import 'bouncing_widget.dart';

class RoBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int index) onTabSelected;
  final VoidCallback onServiceBookTap;
  final VoidCallback onMenuTap;

  const RoBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.onServiceBookTap,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    const barHeight = 62.0;
    const coinDiameter = 70.0;
    const coinOverlap = 22.0; // Extends smoothly above the bar without being cropped

    return SizedBox(
      height: barHeight + coinOverlap + bottomPadding,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // 1. Frosted Glass Bottom Navigation Bar (Clipped for backdrop blur)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: barHeight + bottomPadding,
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    border: const Border(
                      top: BorderSide(color: AppTheme.borderLight, width: 0.5),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: barHeight,
                      child: Row(
                        children: [
                          // 1. Home Tab
                          Expanded(
                            child: BouncingWidget(
                              onTap: () => onTabSelected(0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    currentIndex == 0 ? Icons.home_rounded : Icons.home_outlined,
                                    color: currentIndex == 0 ? AppTheme.appleBlue : AppTheme.textSecondary,
                                    size: 24,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Home',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: currentIndex == 0 ? FontWeight.w700 : FontWeight.w500,
                                      color: currentIndex == 0 ? AppTheme.appleBlue : AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Reserved gap for the center coin
                          const SizedBox(width: coinDiameter + 12),

                          // 3. Menu Tab (Hamburger icon matching Web App reference)
                          Expanded(
                            child: BouncingWidget(
                              onTap: onMenuTap,
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.menu,
                                    color: Color(0xFF334155),
                                    size: 22,
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'Menu',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF334155),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 2. Center 3D Golden Service Coin (Full Circle, Uncropped, fully tappable)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: CoinServiceButton(onTap: onServiceBookTap),
            ),
          ),
        ],
      ),
    );
  }
}
