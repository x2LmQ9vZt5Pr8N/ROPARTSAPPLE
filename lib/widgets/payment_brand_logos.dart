import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Crisp custom-painted & typographic payment brand logos for Razorpay Custom UI.
/// Zero external network dependency so icons render instantaneously without flicker.
class UpiHeaderLogo extends StatelessWidget {
  final double height;

  const UpiHeaderLogo({super.key, this.height = 18});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'UPI',
              style: TextStyle(
                fontSize: height * 0.62,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: -0.4,
                color: const Color(0xFF334155),
                height: 1.0,
              ),
            ),
            const SizedBox(width: 2),
            CustomPaint(
              size: Size(height * 0.55, height * 0.65),
              painter: _UpiChevronsPainter(),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpiChevronsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pOrange = Paint()..color = const Color(0xFFFF7722);
    final pGreen = Paint()..color = const Color(0xFF138808);

    final pathOrange = Path()
      ..moveTo(size.width * 0.05, 0)
      ..lineTo(size.width * 0.58, size.height * 0.5)
      ..lineTo(size.width * 0.05, size.height)
      ..lineTo(size.width * 0.25, size.height * 0.5)
      ..close();

    final pathGreen = Path()
      ..moveTo(size.width * 0.42, 0)
      ..lineTo(size.width, size.height * 0.5)
      ..lineTo(size.width * 0.42, size.height)
      ..lineTo(size.width * 0.62, size.height * 0.5)
      ..close();

    canvas.drawPath(pathOrange, pOrange);
    canvas.drawPath(pathGreen, pGreen);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class RazorpayVerifiedShield extends StatelessWidget {
  final double size;

  const RazorpayVerifiedShield({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _RazorpayMarkPainter(),
    );
  }
}

class _RazorpayMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF072654);
    final bolt = Paint()..color = const Color(0xFF3395FF);

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width * 0.24),
    );
    canvas.drawRRect(rrect, bg);

    final path = Path()
      ..moveTo(size.width * 0.56, size.height * 0.16)
      ..lineTo(size.width * 0.26, size.height * 0.84)
      ..lineTo(size.width * 0.48, size.height * 0.84)
      ..lineTo(size.width * 0.74, size.height * 0.16)
      ..close();
    canvas.drawPath(path, bolt);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class UpiAppLogo extends StatelessWidget {
  final String packageOrId;
  final String? displayName;
  final Uint8List? iconBytes;
  final double size;

  const UpiAppLogo({
    super.key,
    required this.packageOrId,
    this.displayName,
    this.iconBytes,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    if (iconBytes != null && iconBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.memory(
          iconBytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    final key = '${packageOrId.toLowerCase()} ${(displayName ?? '').toLowerCase()}';

    if (key.contains('paisa') || key.contains('gpay') || key.contains('google pay')) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.2),
        child: CustomPaint(painter: _GoogleGPainter()),
      );
    }

    if (key.contains('phonepe')) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF5F259F),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Text(
              '\u092A\u0947',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.48,
                fontWeight: FontWeight.w800,
                height: 1.0,
              ),
            ),
          ),
        ),
      );
    }

    if (key.contains('paytm')) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFBAE6FD)),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: size * 0.26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                ),
                children: const [
                  TextSpan(text: 'Pay', style: TextStyle(color: Color(0xFF002970))),
                  TextSpan(text: 'tm', style: TextStyle(color: Color(0xFF00BAF2))),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (key.contains('amazon')) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF232F3E),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF334155)),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'a',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.46,
                    fontWeight: FontWeight.w800,
                    height: 0.85,
                  ),
                ),
                CustomPaint(
                  size: Size(size * 0.48, size * 0.14),
                  painter: _AmazonSmilePainter(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (key.contains('bhim') || key.contains('npci')) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.24),
        child: CustomPaint(painter: _UpiChevronsPainter()),
      );
    }

    if (key.contains('cred') || key.contains('dreamplug')) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF0F172A),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Text(
              'CRED',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.22,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      );
    }

    if (key.contains('whatsapp')) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF25D366),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(Icons.chat_bubble_rounded, color: Colors.white, size: size * 0.46),
      );
    }

    final initial = (displayName ?? packageOrId).trim().isNotEmpty
        ? (displayName ?? packageOrId).trim()[0].toUpperCase()
        : 'U';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Text(
            initial,
            style: TextStyle(
              color: const Color(0xFF1D4ED8),
              fontSize: size * 0.44,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = size.width * 0.21;
    final insetRect = rect.deflate(stroke / 2);

    Paint arcPaint(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Red top
    canvas.drawArc(insetRect, -2.55, 1.85, false, arcPaint(const Color(0xFFEA4335)));
    // Yellow left
    canvas.drawArc(insetRect, 2.55, 1.18, false, arcPaint(const Color(0xFFFBBC05)));
    // Green bottom
    canvas.drawArc(insetRect, 0.72, 1.83, false, arcPaint(const Color(0xFF34A853)));
    // Blue right + bar
    canvas.drawArc(insetRect, -0.05, 0.82, false, arcPaint(const Color(0xFF4285F4)));

    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.5,
        size.height * 0.42,
        size.width * 0.46,
        stroke,
      ),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AmazonSmilePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFF9900)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.55
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(size.width * 0.1, size.height * 0.2)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.95,
        size.width * 0.9,
        size.height * 0.25,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PayLaterLogo extends StatelessWidget {
  final String provider;
  final double size;

  const PayLaterLogo({super.key, required this.provider, this.size = 38});

  @override
  Widget build(BuildContext context) {
    final code = provider.toLowerCase();
    if (code.contains('amazon')) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF232F3E),
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'a',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.44,
                    fontWeight: FontWeight.w800,
                    height: 0.85,
                  ),
                ),
                CustomPaint(
                  size: Size(size * 0.46, size * 0.14),
                  painter: _AmazonSmilePainter(),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.schedule_rounded, color: const Color(0xFF1D4ED8), size: size * 0.52),
    );
  }
}

class CardNetworkBadge extends StatelessWidget {
  final String network;
  final double height;

  const CardNetworkBadge({
    super.key,
    required this.network,
    this.height = 24,
  });

  @override
  Widget build(BuildContext context) {
    final norm = network.toLowerCase().trim();
    if (norm.contains('visa')) {
      return Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Center(
          widthFactor: 1.0,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'VISA',
              style: TextStyle(
                color: const Color(0xFF1A1F71),
                fontSize: height * 0.46,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ),
      );
    }

    if (norm.contains('master')) {
      return Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Center(
          widthFactor: 1.0,
          child: CustomPaint(
            size: Size(height * 1.15, height * 0.68),
            painter: _MastercardPainter(),
          ),
        ),
      );
    }

    if (norm.contains('rupay')) {
      return Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Center(
          widthFactor: 1.0,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'RuPay',
                  style: TextStyle(
                    color: const Color(0xFF0F2B63),
                    fontSize: height * 0.42,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(width: 2),
                CustomPaint(
                  size: Size(height * 0.35, height * 0.42),
                  painter: _UpiChevronsPainter(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (norm.contains('amex') || norm.contains('american')) {
      return Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF006FCF),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          widthFactor: 1.0,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'AMEX',
              style: TextStyle(
                color: Colors.white,
                fontSize: height * 0.38,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Center(
        widthFactor: 1.0,
        child: Icon(Icons.credit_card_rounded, color: const Color(0xFF475569), size: height * 0.62),
      ),
    );
  }
}

class _MastercardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height * 0.48;
    final cy = size.height / 2;
    canvas.drawCircle(Offset(size.width * 0.36, cy), r, Paint()..color = const Color(0xFFEB001B));
    canvas.drawCircle(Offset(size.width * 0.64, cy), r, Paint()..color = const Color(0xFFF79E1B).withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class BankBrandLogo extends StatelessWidget {
  final String bankCode;
  final String bankName;
  final double size;

  const BankBrandLogo({
    super.key,
    required this.bankCode,
    required this.bankName,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final code = bankCode.toUpperCase().trim();

    if (code == 'HDFC') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.18),
        child: CustomPaint(painter: _HdfcPainter()),
      );
    }

    if (code == 'ICIC') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.14),
        child: CustomPaint(painter: _IciciPainter()),
      );
    }

    if (code == 'SBIN') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.16),
        child: CustomPaint(painter: _SbiPainter()),
      );
    }

    if (code == 'UTIB') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        padding: EdgeInsets.all(size * 0.16),
        child: CustomPaint(painter: _AxisPainter()),
      );
    }

    // Curated bank badge colors for remaining 40+ Razorpay banks
    final bgColor = _bankColorForCode(code);
    final label = _shortCodeForBank(code, bankName);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: bgColor.withValues(alpha: 0.25)),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              color: bgColor,
              fontSize: label.length >= 4 ? size * 0.24 : size * 0.28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ),
    );
  }

  static Color _bankColorForCode(String code) {
    const palette = <String, Color>{
      'YESB': Color(0xFF0051A2),
      'IDFB': Color(0xFF9D1D27),
      'FDRL': Color(0xFF004B8D),
      'CNRB': Color(0xFF0091D5),
      'BARB_R': Color(0xFFF15A22),
      'PUNB_R': Color(0xFFA20A3A),
      'UBIN': Color(0xFFDD1E25),
      'INDB': Color(0xFF98272A),
      'IOBA': Color(0xFF1A4E8A),
      'IDIB': Color(0xFF004C97),
      'MAHB': Color(0xFF0072BC),
      'CBIN': Color(0xFF0056A3),
      'KARB': Color(0xFF6B1D57),
      'KVBL': Color(0xFF007B40),
      'RATN': Color(0xFF21317D),
      'SCBL': Color(0xFF0072AA),
      'DBSS': Color(0xFFE31B23),
      'SIBL': Color(0xFF8C1919),
    };
    if (palette.containsKey(code)) return palette[code]!;
    const fallbacks = [
      Color(0xFF1D4ED8),
      Color(0xFF0369A1),
      Color(0xFF0F766E),
      Color(0xFF4338CA),
      Color(0xFF7C3AED),
      Color(0xFFB45309),
    ];
    final hash = code.codeUnits.fold<int>(0, (a, b) => a + b);
    return fallbacks[hash % fallbacks.length];
  }

  static String _shortCodeForBank(String code, String name) {
    final cleaned = code.replaceAll('_R', '').replaceAll('_C', '');
    if (cleaned.length <= 4 && cleaned.isNotEmpty) return cleaned;
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return words.take(3).map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join();
    }
    return cleaned.substring(0, cleaned.length.clamp(0, 4));
  }
}

class _HdfcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final red = Paint()..color = const Color(0xFFED232A);
    final white = Paint()..color = Colors.white;
    final navy = Paint()..color = const Color(0xFF004C8F);

    canvas.drawRect(Offset.zero & size, red);
    // White cross bars splitting the red border
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.42, 0, size.width * 0.16, size.height),
      white,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.42, size.width, size.height * 0.16),
      white,
    );
    // Inner white frame + navy square
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.22, size.height * 0.22, size.width * 0.56, size.height * 0.56),
      white,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.34, size.height * 0.34, size.width * 0.32, size.height * 0.32),
      navy,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _IciciPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final orange = Paint()..color = const Color(0xFFF37E20);
    final maroon = Paint()..color = const Color(0xFFB02A30);
    final white = Paint()..color = Colors.white;

    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, size.width * 0.48, orange);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: size.width * 0.48),
      0.4,
      2.6,
      true,
      maroon,
    );
    // Stylized 'i'
    canvas.drawCircle(Offset(size.width * 0.52, size.height * 0.30), size.width * 0.085, white);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.43, size.height * 0.44, size.width * 0.16, size.height * 0.33),
        const Radius.circular(3),
      ),
      white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SbiPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final blue = Paint()..color = const Color(0xFF00B5EF);
    final white = Paint()..color = Colors.white;

    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, size.width * 0.48, blue);
    canvas.drawCircle(center, size.width * 0.17, white);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.43, size.height * 0.50, size.width * 0.14, size.height * 0.48),
      white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AxisPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final maroon = Paint()..color = const Color(0xFF97144D);
    final white = Paint()..color = Colors.white;

    final outer = Path()
      ..moveTo(size.width * 0.5, size.height * 0.06)
      ..lineTo(size.width * 0.94, size.height * 0.90)
      ..lineTo(size.width * 0.06, size.height * 0.90)
      ..close();
    canvas.drawPath(outer, maroon);

    final inner = Path()
      ..moveTo(size.width * 0.50, size.height * 0.42)
      ..lineTo(size.width * 0.70, size.height * 0.90)
      ..lineTo(size.width * 0.30, size.height * 0.90)
      ..close();
    canvas.drawPath(inner, white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
