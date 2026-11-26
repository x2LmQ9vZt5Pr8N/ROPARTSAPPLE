import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runtime Web gate & official app download helper.
class WebAppDownloadConfig {
  WebAppDownloadConfig._();

  @visibleForTesting
  static bool? debugIsWebOverride;

  static bool get isWeb => debugIsWebOverride ?? kIsWeb;

  static const String appDownloadUrl = String.fromEnvironment(
    'ROPARTS_APP_DOWNLOAD_URL',
    defaultValue: 'https://www.roparts.in/get-app',
  );

  static Future<void> launchAppDownload(BuildContext context) async {
    final uri = Uri.parse(appDownloadUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (_) {}

    try {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Visit roparts.in/get-app to install the official ROParts App.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

/// Reusable Apple-style glassy card prompting web visitors to continue in the mobile app.
class WebAppDownloadGateCard extends StatelessWidget {
  final String badge;
  final String title;
  final String subtitle;
  final List<String> bullets;
  final String buttonLabel;
  final VoidCallback onDownloadTap;

  const WebAppDownloadGateCard({
    super.key,
    required this.badge,
    required this.title,
    required this.subtitle,
    this.bullets = const [],
    this.buttonLabel = 'Download ROParts App (Get 80% Off)',
    required this.onDownloadTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF0F9FF)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBAE6FD), width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x100284C7),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFDCFCE7),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFF86EFAC)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_offer_rounded, size: 12, color: Color(0xFF15803D)),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    badge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF15803D),
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2FE),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.phone_android_rounded,
                  color: Color(0xFF0284C7),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF475569),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (bullets.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...bullets.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF16A34A)),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: onDownloadTap,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(
                buttonLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a compact modal bottom sheet prompting Web users to download the mobile app.
Future<void> showWebAppDownloadSheet(
  BuildContext context, {
  String badge = 'APP EXCLUSIVE • UP TO 80% OFF',
  String title = 'Download ROParts App to Continue',
  String subtitle =
      'Get up to 80% off, scan genuine spare-part QR seals, and unlock instant app checkout.',
  List<String> bullets = const [
    'Up to 80% discount on genuine RO parts',
    'Built-in QR & hologram authenticity scanner',
    'One-tap GPay / PhonePe / Paytm UPI checkout',
  ],
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            WebAppDownloadGateCard(
              badge: badge,
              title: title,
              subtitle: subtitle,
              bullets: bullets,
              onDownloadTap: () => WebAppDownloadConfig.launchAppDownload(ctx),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Continue Browsing Web',
                style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
