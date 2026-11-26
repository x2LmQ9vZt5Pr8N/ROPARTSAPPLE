import 'dart:ui';
import 'package:flutter/material.dart';

class AppTheme {
  // Apple Design System Tokens
  static const Color canvas = Color(0xFFFBFBFD); // Apple light background
  static const Color surface = Color(0xFFFFFFFF);
  static const Color cardSurface = Color(0xFFF5F5F7); // Apple secondary grouping
  static const Color cardSurfaceElevated = Color(0xFFFFFFFF);

  static const Color appleBlue = Color(0xFF0071E3); // Apple action blue
  static const Color primary = appleBlue;
  static const Color primaryDark = Color(0xFF0051A8);
  static const Color primaryLight = Color(0xFFE8F2FD);
  static const Color primarySurface = Color(0xFFF0F9FF);

  static const Color textPrimary = Color(0xFF1D1D1F); // Deep Obsidian
  static const Color textSecondary = Color(0xFF86868B); // Muted SF subtext
  static const Color textTertiary = Color(0xFFA1A1A6);

  static const Color borderLight = Color(0xFFE5E5EA); // Hairline separator
  static const Color borderSubtle = Color(0x14000000); // 8% black

  static const Color appleGreen = Color(0xFF34C759); // Apple Success
  static const Color appleRed = Color(0xFFFF3B30); // Apple Discount / Alert
  static const Color goldCoin = Color(0xFFF59E0B); // Amber 500
  static const Color goldDark = Color(0xFFD97706);
  static const Color goldLight = Color(0xFFFEF3C7);

  // Backward-compatible design aliases
  static const Color slateBorder = borderLight;
  static const Color navyDark = textPrimary;
  static const Color textMuted = textSecondary;
  static const Color textDark = textPrimary;
  static const Color greenSuccess = appleGreen;
  static const Color discountRed = appleRed;

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: appleBlue,
        primary: appleBlue,
        secondary: goldCoin,
        surface: surface,
      ),
      scaffoldBackgroundColor: canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
        ),
        titleLarge: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          color: textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        bodyLarge: TextStyle(
          color: textPrimary,
          fontSize: 14,
          letterSpacing: -0.1,
        ),
        bodyMedium: TextStyle(
          color: textSecondary,
          fontSize: 13,
          letterSpacing: -0.1,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        constraints: BoxConstraints(maxWidth: 540),
        showDragHandle: false,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PremiumPageTransitionsBuilder(),
          TargetPlatform.iOS: PremiumPageTransitionsBuilder(),
          TargetPlatform.windows: PremiumPageTransitionsBuilder(),
          TargetPlatform.macOS: PremiumPageTransitionsBuilder(),
          TargetPlatform.linux: PremiumPageTransitionsBuilder(),
          TargetPlatform.fuchsia: PremiumPageTransitionsBuilder(),
        },
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: appleBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}

/// Ultra-smooth Apple-grade fluid page transition builder.
/// Subtly slides in (8%) with cubic deceleration, fade, and slight background scale (0.96).
class PremiumPageTransitionsBuilder extends PageTransitionsBuilder {
  const PremiumPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final slideIn = Tween<Offset>(
      begin: const Offset(0.08, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    final fadeIn = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOut),
    ));

    final secondaryScale = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
    ));

    final secondaryOpacity = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
    ));

    return SlideTransition(
      position: slideIn,
      child: FadeTransition(
        opacity: fadeIn,
        child: ScaleTransition(
          scale: secondaryScale,
          child: FadeTransition(
            opacity: secondaryOpacity,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// App-wide elastic bouncy scroll behavior with multi-device mouse/touchpad drag support.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
