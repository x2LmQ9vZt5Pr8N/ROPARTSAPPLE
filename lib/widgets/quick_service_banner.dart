import 'package:flutter/material.dart';
import 'bouncing_widget.dart';

class QuickServiceBanner extends StatelessWidget {
  final VoidCallback onTap;

  const QuickServiceBanner({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: BouncingWidget(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0x14000000),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19.4),
            child: AspectRatio(
              aspectRatio: 1774 / 887,
              child: Image.asset(
                'assets/images/srvice-page.webp',
                cacheWidth: 800,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Image.asset(
                    'assets/images/srvice-page.png',
                    cacheWidth: 800,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Image.asset(
                        'assets/images/ro-service-banner.png',
                        cacheWidth: 800,
                        fit: BoxFit.cover,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
