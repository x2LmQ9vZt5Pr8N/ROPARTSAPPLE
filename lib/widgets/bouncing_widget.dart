import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BouncingWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scaleFactor;
  final bool enableHaptic;

  const BouncingWidget({
    super.key,
    required this.child,
    this.onTap,
    this.scaleFactor = 0.94,
    this.enableHaptic = true,
  });

  @override
  State<BouncingWidget> createState() => _BouncingWidgetState();
}

class _BouncingWidgetState extends State<BouncingWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 70),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.scaleFactor,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutQuad,
        reverseCurve: Curves.easeOutBack,
      ),
    );
    _opacityAnimation = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutQuad,
        reverseCurve: Curves.easeOut,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    if (widget.onTap != null) {
      if (widget.enableHaptic) {
        HapticFeedback.lightImpact();
      }
      _controller.forward();
    }
  }

  void _onTapCancel() {
    if (widget.onTap != null) {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _onTapDown,
      onTapCancel: _onTapCancel,
      onTap: widget.onTap != null
          ? () {
              // Immediately trigger action without artificial animation delay
              widget.onTap!();
              _controller.reverse();
            }
          : null,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final scale = _scaleAnimation.value;
          final opacity = _opacityAnimation.value;
          if (scale == 1.0 && opacity == 1.0) {
            return widget.child;
          }
          return Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}
