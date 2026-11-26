import 'package:flutter/material.dart';
import '../state/service_tracking_state.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';

class TechnicianTrackingBar extends StatelessWidget {
  final ServiceTrackingState serviceState;
  final CartState? cartState;
  final VoidCallback onTap;

  const TechnicianTrackingBar({
    super.key,
    required this.serviceState,
    this.cartState,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: serviceState,
      builder: (context, _) {
        final state = serviceState;
        final isCompleted = state.isCompleted;

        // Strict Authentication Gate: Never display tracking bar to logged-out users
        if (cartState != null && !cartState!.isLoggedIn) {
          return const SizedBox.shrink();
        }

        // When service is completed or no active booking, hide badge completely from Home page
        if (isCompleted || !state.hasActiveBooking) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: BouncingWidget(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 10,
                    spreadRadius: 0,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Scooter Icon: Black & white, without border and background
                  Icon(
                    state.isInService
                        ? Icons.engineering_rounded
                        : Icons.moped_rounded,
                    color: Colors.black,
                    size: 24,
                  ),
                  const SizedBox(width: 10),

                  // Middle Text: Status Display (rider name, quick inspect, etc. removed)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          state.statusDisplay,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        if (state.shouldShowOtp && state.arrivalOtp != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'OTP: ${state.arrivalOtp}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(width: 10),

                  // Track button: simple track / hub link with underline
                  Text(
                    state.isInService ? 'Open Hub →' : 'Track →',
                    style: const TextStyle(
                      color: Color(0xFF0284C7),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
