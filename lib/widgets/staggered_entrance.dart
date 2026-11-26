import 'dart:async';
import 'package:flutter/material.dart';

/// Lightweight staggered slide & fade entrance animation for feed sections and cards.
/// Provides a fluid, luxury cascading reveal without blocking user interactions.
class StaggeredEntrance extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration delayStep;
  final Duration duration;
  final double verticalOffset;

  const StaggeredEntrance({
    super.key,
    required this.child,
    this.index = 0,
    this.delayStep = const Duration(milliseconds: 35),
    this.duration = const Duration(milliseconds: 320),
    this.verticalOffset = 18.0,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(curve);
    _slideAnimation = Tween<Offset>(
      begin: Offset(0, widget.verticalOffset / 100),
      end: Offset.zero,
    ).animate(curve);

    final delay = widget.delayStep * widget.index;
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(delay, () {
        if (mounted) {
          _controller.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: widget.child,
      ),
    );
  }
}
