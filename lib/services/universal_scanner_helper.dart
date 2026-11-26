import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Shared universal scanner configuration and multi-barcode frame resolver.
/// Supports all 2D (QR, DataMatrix, Aztec, PDF417) and 1D barcodes
/// (Code128, Code39, Code93, Codabar, EAN-13, EAN-8, ITF-14, UPC-A, UPC-E).
class UniversalScannerHelper {
  UniversalScannerHelper._();

  static const List<BarcodeFormat> allSupportedFormats = <BarcodeFormat>[
    BarcodeFormat.qrCode,
    BarcodeFormat.dataMatrix,
    BarcodeFormat.aztec,
    BarcodeFormat.pdf417,
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf14,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ];

  static final RegExp _controlCharsRegex = RegExp(r'[\x00-\x1F\x7F\u200B-\u200D\uFEFF]');
  static final RegExp _hasLetterRegex = RegExp(r'[A-Za-z]');
  static final RegExp _hasDigitRegex = RegExp(r'[0-9]');
  static final RegExp _pureDigitsRegex = RegExp(r'^\d+$');

  /// Creates a [MobileScannerController] tuned for both QR codes and thin 1D barcodes.
  static MobileScannerController createController({
    DetectionSpeed detectionSpeed = DetectionSpeed.normal,
    int detectionTimeoutMs = 800,
    CameraFacing facing = CameraFacing.back,
    bool torchEnabled = false,
    Size? cameraResolution = const Size(1280, 720),
  }) {
    return MobileScannerController(
      detectionSpeed: detectionSpeed,
      detectionTimeoutMs: detectionTimeoutMs,
      facing: facing,
      torchEnabled: torchEnabled,
      cameraResolution: cameraResolution,
      formats: allSupportedFormats,
    );
  }

  /// Strips scanner/GS1 control characters and normalizes casing/whitespace.
  static String normalizeCode(String? raw, {bool uppercase = false}) {
    if (raw == null) return '';
    final stripped = raw.replaceAll(_controlCharsRegex, '').trim();
    return uppercase ? stripped.toUpperCase() : stripped;
  }

  /// Extracts all valid non-empty normalized candidates from [capture].
  static List<String> extractCandidates(BarcodeCapture capture, {bool uppercase = false}) {
    final seen = <String>{};
    final out = <String>[];
    for (final b in capture.barcodes) {
      final clean = normalizeCode(b.rawValue, uppercase: uppercase);
      if (clean.isNotEmpty && seen.add(clean)) {
        out.add(clean);
      }
    }
    return out;
  }

  /// Selects the most relevant barcode/QR when a frame contains multiple labels
  /// (e.g. an adjacent OEM EAN barcode beside our serialized Code128/QR sticker).
  static String? pickBestCode(
    BarcodeCapture capture, {
    bool Function(String code)? prefer,
    bool preferAlphanumericOverBareDigits = true,
    bool uppercase = false,
  }) {
    final candidates = extractCandidates(capture, uppercase: uppercase);
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    if (prefer != null) {
      for (final c in candidates) {
        if (prefer(c)) return c;
      }
    }

    if (preferAlphanumericOverBareDigits) {
      final hasPureDigits = candidates.any((c) => _pureDigitsRegex.hasMatch(c));
      if (hasPureDigits) {
        for (final c in candidates) {
          if (_hasLetterRegex.hasMatch(c) && _hasDigitRegex.hasMatch(c)) {
            return c;
          }
        }
      }
    }

    return candidates.first;
  }
}

/// Compact 1x / 2x zoom toggle pill for scanning small/narrow 1D barcodes.
class ScannerZoomPill extends StatefulWidget {
  final MobileScannerController? controller;
  final bool compact;

  const ScannerZoomPill({
    super.key,
    required this.controller,
    this.compact = false,
  });

  @override
  State<ScannerZoomPill> createState() => _ScannerZoomPillState();
}

class _ScannerZoomPillState extends State<ScannerZoomPill> {
  bool _zoomed = false;

  Future<void> _toggleZoom() async {
    final ctrl = widget.controller;
    if (ctrl == null) return;
    final next = !_zoomed;
    setState(() => _zoomed = next);
    try {
      await ctrl.setZoomScale(next ? 0.45 : 0.0);
    } catch (_) {
      // Ignore camera zoom errors on unsupported devices/tests.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller == null) return const SizedBox.shrink();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggleZoom,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 8 : 10,
            vertical: widget.compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: _zoomed
                ? const Color(0xFF0071E3).withValues(alpha: 0.9)
                : Colors.black.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _zoomed ? const Color(0xFF93C5FD) : Colors.white30,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _zoomed ? Icons.zoom_out_rounded : Icons.zoom_in_rounded,
                color: Colors.white,
                size: widget.compact ? 13 : 15,
              ),
              const SizedBox(width: 4),
              Text(
                _zoomed ? '2x' : '1x',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.compact ? 10.5 : 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Enforces a 1-second inter-scan cooldown in Hold / Auto scanner modes so
/// consecutive camera frames cannot double-fire before the user moves away.
class ScanCooldownGate {
  final Duration cooldown;
  DateTime? _lastAcceptedAt;
  String? _lastCode;

  ScanCooldownGate({this.cooldown = const Duration(milliseconds: 1000)});

  /// Consumes the cooldown gate if [cooldown] elapsed since the last scan.
  bool tryAcquire(String code) {
    final now = DateTime.now();
    if (_lastAcceptedAt != null && now.difference(_lastAcceptedAt!) < cooldown) {
      return false;
    }
    _lastCode = code;
    _lastAcceptedAt = now;
    return true;
  }

  /// Refreshes the cooldown timestamp after async processing finishes.
  void touch([String? code]) {
    _lastAcceptedAt = DateTime.now();
    if (code != null) _lastCode = code;
  }

  void reset() {
    _lastAcceptedAt = null;
    _lastCode = null;
  }

  String? get lastCode => _lastCode;
  DateTime? get lastAcceptedAt => _lastAcceptedAt;
}

/// Non-blocking 0.40s full-screen green tick / red cross scan confirmation flash.
class ScanConfirmationOverlay {
  ScanConfirmationOverlay._();

  static const Duration displayDuration = Duration(milliseconds: 400);
  static OverlayEntry? _activeEntry;

  /// Flashes an unmistakable full-screen confirmation over root [Overlay] for
  /// [duration] (default 400ms) without stealing pointer events from Hold mode.
  static void show(
    BuildContext context, {
    required bool isSuccess,
    Duration duration = displayDuration,
  }) {
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ScanFlashOverlayWidget(
        isSuccess: isSuccess,
        duration: duration,
        onComplete: () {
          if (identical(_activeEntry, entry)) {
            _activeEntry = null;
          }
          if (entry.mounted) {
            entry.remove();
          }
        },
      ),
    );

    _activeEntry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final prev = _activeEntry;
    _activeEntry = null;
    if (prev != null && prev.mounted) {
      prev.remove();
    }
  }
}

class _ScanFlashOverlayWidget extends StatefulWidget {
  final bool isSuccess;
  final Duration duration;
  final VoidCallback onComplete;

  const _ScanFlashOverlayWidget({
    required this.isSuccess,
    required this.duration,
    required this.onComplete,
  });

  @override
  State<_ScanFlashOverlayWidget> createState() => _ScanFlashOverlayWidgetState();
}

class _ScanFlashOverlayWidgetState extends State<_ScanFlashOverlayWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.onComplete);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isSuccess ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    final icon = widget.isSuccess ? Icons.check_rounded : Icons.close_rounded;

    return IgnorePointer(
      ignoring: true,
      child: Material(
        color: color.withValues(alpha: 0.72),
        child: Center(
          child: Container(
            key: Key(widget.isSuccess ? 'scan_flash_success_overlay' : 'scan_flash_error_overlay'),
            width: 176,
            height: 176,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Color(0x44000000), blurRadius: 28, spreadRadius: 4),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 124,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
