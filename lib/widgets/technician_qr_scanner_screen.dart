import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/api_service.dart';
import '../services/coupon_registry.dart';
import '../services/doorstep_session_manager.dart';
import '../services/qr_product_registry.dart';
import '../services/universal_scanner_helper.dart';
import '../state/cart_state.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/display_sanitizer.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';
import 'cart_bottom_sheet.dart';
import 'doorstep_checkout_verification_screen.dart';

import '../state/service_tracking_state.dart';

class TechnicianQrScannerScreen extends StatefulWidget {
  final CartState cartState;
  final ServiceTrackingState? serviceState;

  const TechnicianQrScannerScreen({
    super.key,
    required this.cartState,
    this.serviceState,
  });

  @override
  State<TechnicianQrScannerScreen> createState() => _TechnicianQrScannerScreenState();
}

class _TechnicianQrScannerScreenState extends State<TechnicianQrScannerScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _laserController;
  late Animation<double> _laserAnimation;
  late MobileScannerController _cameraController;

  bool _isTorchOn = false;
  bool _isSheetOpen = false;
  bool _isProcessingCode = false;
  final ScanCooldownGate _scanGate = ScanCooldownGate();

  final List<ScannedRoItem> _scannedDoorstepItems = [];
  dynamic get _visitId => widget.serviceState?.bookingId ?? '0';
  String? get _customerScopeId {
    final scoped = PhoneNormalizer.toCustomerId(
      widget.cartState.customerId ?? widget.cartState.userPhone,
    );
    return scoped.isNotEmpty ? scoped : null;
  }

  @override
  void initState() {
    super.initState();
    _restoreSavedSession();

    _cameraController = UniversalScannerHelper.createController(
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 1000,
    );

    _laserController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _laserAnimation = Tween<double>(begin: 0.08, end: 0.92).animate(
      CurvedAnimation(parent: _laserController, curve: Curves.easeInOut),
    );
  }

  Future<void> _restoreSavedSession() async {
    final saved = await DoorstepSessionManager.loadSession(
      _visitId,
      customerId: _customerScopeId,
    );
    final list = (saved != null && saved['items'] is List)
        ? (saved['items'] as List)
            .map((e) => ScannedRoItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList()
        : <ScannedRoItem>[];
    if (mounted) {
      setState(() {
        _scannedDoorstepItems
          ..clear()
          ..addAll(list);
      });
    }
  }

  void _addScannedItem(ScannedRoItem item) {
    setState(() {
      _scannedDoorstepItems.removeWhere((i) => i.code == item.code);
      _scannedDoorstepItems.add(item);
    });
    DoorstepSessionManager.saveSession(
      visitId: _visitId,
      customerId: _customerScopeId,
      items: _scannedDoorstepItems.map((i) => i.toJson()).toList(),
    );
  }

  void _openVerificationAndPayScreen([ScannedRoItem? newItem]) {
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    if (newItem != null) {
      _addScannedItem(newItem);
    }
    Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DoorstepCheckoutVerificationScreen(
          initialItems: List<ScannedRoItem>.from(_scannedDoorstepItems),
          cartState: widget.cartState,
          serviceState: widget.serviceState,
          onItemsChanged: (updated) {
            if (!mounted) return;
            setState(() {
              _scannedDoorstepItems
                ..clear()
                ..addAll(updated);
            });
          },
          onScanMore: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
          onPaymentComplete: () {
            setState(() {
              _scannedDoorstepItems.clear();
            });
          },
        ),
      ),
    ).then((returnedFromPayment) {
      if (returnedFromPayment == true && mounted) {
        Navigator.pop(context, true);
        return;
      }
      _restoreSavedSession();
    });
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _laserController.dispose();
    super.dispose();
  }

  void _onBarcodeCapture(BarcodeCapture capture) {
    if (_isSheetOpen) return;
    final picked = UniversalScannerHelper.pickBestCode(
      capture,
      uppercase: false,
      prefer: (raw) => CouponRegistry.isExplicitCouponPayload(raw),
    );
    if (picked != null && picked.isNotEmpty) {
      if (!_scanGate.tryAcquire(picked)) return;
      _onCodeDetected(picked);
    }
  }

  Future<void> _onCodeDetected(String rawCode) async {
    if (_isSheetOpen || _isProcessingCode) return;
    final trimmed = rawCode.trim();
    if (trimmed.isEmpty) return;

    _isProcessingCode = true;
    try {
      // 1. Explicit Coupon QR payload (`COUPON:`, `VOUCHER:`, `PROMO:`, `?code=`)
      if (CouponRegistry.isExplicitCouponPayload(trimmed)) {
        final couponCode = CouponRegistry.normalizeScannedCode(trimmed);
        if (couponCode != null) {
          ScanConfirmationOverlay.show(context, isSuccess: true);
          await _handleScannedCouponCode(couponCode);
          return;
        }
      }

      // 2. Strict Live Server-Side Inventory Verification Against Assigned Technician Custody
      try {
        final customerId = _customerScopeId;
        final visitId = int.tryParse(widget.serviceState?.bookingId ?? '0');
        final backendRes = await ApiService().verifyDoorstepScan(
          serialQr: trimmed,
          visitId: visitId,
          customerId: customerId,
        );
        if (!mounted) return;

        if (backendRes['verified'] == true) {
          List<Map<String, dynamic>> rawComponents = [];
          if (backendRes['items'] is List) {
            rawComponents = (backendRes['items'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }

          final rawMrp = (backendRes['mrp'] is num)
              ? (backendRes['mrp'] as num).toDouble()
              : (double.tryParse(backendRes['mrp']?.toString() ?? '') ?? 0.0);
          if (rawMrp <= 0) {
            ScanConfirmationOverlay.show(context, isSuccess: false);
            _showCustodyErrorSheet(trimmed, 'Server returned invalid price for scanned item.');
            return;
          }
          final itemType = (backendRes['type'] ?? '').toString().toUpperCase();
          final warrantyMonths = backendRes['warranty_months'];
          final cbmResolved = CbmSpecHelper.resolveItemSpec(backendRes);
          final resolvedWarranty = (backendRes['warranty'] ?? '').toString().trim().isNotEmpty
              ? backendRes['warranty'].toString().trim()
              : (cbmResolved.primaryRatingLabel ??
                  (warrantyMonths != null ? '$warrantyMonths Months' : ''));
          final rawFreeSpares = backendRes['free_spares'] is List
              ? (backendRes['free_spares'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
              : const <Map<String, dynamic>>[];
          final serverItem = ScannedRoItem(
            code: (backendRes['serial'] ?? backendRes['code'] ?? trimmed).toString(),
            name: (backendRes['name'] ??
                    (itemType == 'KIT' ? 'RO Service Kit' : 'RO Component'))
                .toString(),
            type: itemType == 'KIT' ? QrItemType.kit : QrItemType.product,
            mrp: rawMrp,
            price: rawMrp, // SSoT: Authentic MRP, discounts handled strictly at checkout bill level
            description: (backendRes['description'] ?? '').toString(),
            imageAsset: itemType == 'KIT'
                ? 'assets/images/standard-kit-desk.png'
                : 'assets/images/membrane.png',
            batchNumber: (backendRes['batch_number'] ?? backendRes['batchNumber'] ?? '').toString(),
            hologramCode: (backendRes['hologram_code'] ?? backendRes['hologramCode'] ?? '').toString(),
            qcStatus: (backendRes['qc_status'] ?? backendRes['qcStatus'] ?? '').toString(),
            warranty: resolvedWarranty,
            compatibility: (backendRes['compatibility'] ?? '').toString(),
            partNature: cbmResolved.partNature != 'UNSPECIFIED'
                ? cbmResolved.partNature
                : backendRes['part_nature']?.toString(),
            isConsumable: cbmResolved.isConsumable,
            shelfLifeLiters: cbmResolved.shelfLifeLiters,
            warrantyYears: cbmResolved.warrantyYears,
            shelfLifeMonths: cbmResolved.shelfLifeMonths,
            cbmSpecLabel: cbmResolved.primaryRatingLabel ?? backendRes['cbm_spec_label']?.toString(),
            rawComponents: rawComponents,
            sku: (backendRes['sku'] ?? backendRes['recipe_id'])?.toString(),
            freeSpares: rawFreeSpares,
            sealedFreeSpares: backendRes['sealed_free_spares'] == true,
            isComplimentary: backendRes['is_complimentary_with_visit_kit'] == true,
          );
          ScanConfirmationOverlay.show(context, isSuccess: true);
          _showProductAuthenticitySheet(serverItem);
          return;
        } else if (backendRes['error'] != null && backendRes['verified'] == false) {
          final errText = DisplaySanitizer.sanitizeErrorMessage(
            backendRes['error'].toString(),
          );
          final isUnrecognized = errText.toLowerCase().contains('unrecognized');
          if (!isUnrecognized) {
            ScanConfirmationOverlay.show(context, isSuccess: false);
            _showCustodyErrorSheet(trimmed, errText);
            return;
          }
        }
      } catch (e) {
        if (mounted) {
          ScanConfirmationOverlay.show(context, isSuccess: false);
          _showCustodyErrorSheet(
            trimmed,
            'Unable to verify item right now. Please check connection and retry.',
          );
        }
        return;
      }

      if (!mounted) return;
      // 3. Fallback Coupon check for unprefixed promo QRs when cart or doorstep bill has items
      if (widget.cartState.items.isNotEmpty || _scannedDoorstepItems.isNotEmpty) {
        final candidateCoupon = CouponRegistry.normalizeScannedCode(trimmed);
        if (candidateCoupon != null) {
          final matched = await _tryValidateUnprefixedCoupon(candidateCoupon);
          if (matched || !mounted) return;
        }
      }

      // 4. Unrecognized or not in technician custody
      if (mounted) {
        ScanConfirmationOverlay.show(context, isSuccess: false);
        _showUnrecognizedCodeSheet(trimmed);
      }
    } finally {
      _scanGate.touch(trimmed);
      _isProcessingCode = false;
    }
  }

  Future<bool> _tryValidateUnprefixedCoupon(String couponCode) async {
    if (_scannedDoorstepItems.isNotEmpty) {
      final customerId = _customerScopeId;
      final totalMrp = _scannedDoorstepItems.fold<double>(0.0, (s, i) => s + i.mrp);
      final res = await ApiService().validateCoupon(
        code: couponCode,
        channel: 'TECHNICIAN',
        amount: totalMrp,
        mrp: totalMrp,
        customerId: customerId,
      );
      if (res['success'] == true) {
        final resolvedCode = (res['code'] ?? couponCode).toString().trim();
        await _persistDoorstepCouponAndShowSheet(couponCode: resolvedCode, res: res);
        return true;
      }
      return false;
    }

    if (widget.cartState.items.isNotEmpty) {
      final ok = await widget.cartState.applyCoupon(couponCode);
      if (ok) {
        _showCouponResultSheet(
          code: widget.cartState.appliedCoupon?.code ?? couponCode,
          success: true,
          message: 'Saved ₹${widget.cartState.couponDiscountAmount} on your online cart!',
        );
        return true;
      }
    }
    return false;
  }

  Future<void> _handleScannedCouponCode(String couponCode) async {
    if (_scannedDoorstepItems.isNotEmpty) {
      final customerId = _customerScopeId;
      final totalMrp = _scannedDoorstepItems.fold<double>(0.0, (s, i) => s + i.mrp);
      final res = await ApiService().validateCoupon(
        code: couponCode,
        channel: 'TECHNICIAN',
        amount: totalMrp,
        mrp: totalMrp,
        customerId: customerId,
      );
      if (!mounted) return;
      if (res['success'] == true) {
        final resolvedCode = (res['code'] ?? couponCode).toString().trim();
        await _persistDoorstepCouponAndShowSheet(couponCode: resolvedCode, res: res);
      } else {
        _showCouponResultSheet(
          code: couponCode,
          success: false,
          message: (res['error'] ?? 'Coupon is not valid for these scanned items.').toString(),
        );
      }
      return;
    }

    if (widget.cartState.items.isNotEmpty) {
      final ok = await widget.cartState.applyCoupon(couponCode);
      if (!mounted) return;
      _showCouponResultSheet(
        code: ok ? (widget.cartState.appliedCoupon?.code ?? couponCode) : couponCode,
        success: ok,
        message: ok
            ? 'Saved ₹${widget.cartState.couponDiscountAmount} on your online cart!'
            : (widget.cartState.couponError ?? 'Coupon not eligible for current cart.'),
      );
      return;
    }

    _showCouponResultSheet(
      code: couponCode,
      success: false,
      message: 'Promo code $couponCode detected. Add cart items or scan a part QR first to redeem.',
    );
  }

  Future<void> _persistDoorstepCouponAndShowSheet({
    required String couponCode,
    required Map<String, dynamic> res,
  }) async {
    final rawList = _scannedDoorstepItems.map((i) => i.toJson()).toList();
    await DoorstepSessionManager.saveSession(
      visitId: _visitId,
      customerId: _customerScopeId,
      items: rawList,
      appliedCoupon: couponCode,
    );
    if (!mounted) return;
    final disc = res['discount'] ?? 0;
    _showCouponResultSheet(
      code: couponCode,
      success: true,
      message: 'Doorstep promo applied! Instant discount: ₹$disc',
    );
  }

  void _showCouponResultSheet({
    required String code,
    required bool success,
    required String message,
  }) {
    if (!mounted) return;
    setState(() => _isSheetOpen = true);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + math.max(MediaQuery.of(context).viewPadding.bottom, MediaQuery.of(context).padding.bottom),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(2)),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: success ? const Color(0xFFDCFCE7) : const Color(0xFFFEF2F2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                success ? Icons.local_offer_rounded : Icons.error_outline_rounded,
                color: success ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                size: 32,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              success ? 'Coupon Applied: $code' : 'Coupon Check: $code',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: success ? const Color(0xFF16A34A) : const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  if (success && widget.cartState.items.isNotEmpty && _scannedDoorstepItems.isEmpty) {
                    Navigator.pop(context);
                  }
                },
                child: Text(
                  success && widget.cartState.items.isNotEmpty && _scannedDoorstepItems.isEmpty
                      ? 'Back to Cart'
                      : 'Done',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted) {
        setState(() => _isSheetOpen = false);
      }
    });
  }

  void _showCustodyErrorSheet(String rawCode, String errorMessage) {
    setState(() => _isSheetOpen = true);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + math.max(MediaQuery.of(context).viewPadding.bottom, MediaQuery.of(context).padding.bottom),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(2)),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(color: Color(0xFFFEF2F2), shape: BoxShape.circle),
              child: const Icon(Icons.gpp_bad_rounded, color: Color(0xFFDC2626), size: 36),
            ),
            const SizedBox(height: 12),
            const Text(
              'Inventory Custody Mismatch',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Text(
              errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Scan Another Item', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) setState(() => _isSheetOpen = false);
      });
    });
  }

  void _showUnrecognizedCodeSheet(String rawCode) {
    setState(() => _isSheetOpen = true);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + math.max(MediaQuery.of(context).viewPadding.bottom, MediaQuery.of(context).padding.bottom),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFFFEF2F2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.qr_code_2_rounded, color: Color(0xFFDC2626), size: 36),
            ),
            const SizedBox(height: 12),
            const Text(
              'Unrecognized Box QR Code',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Text(
              'Scanned: "$rawCode"\nPlease scan a genuine box QR code from the technician\'s inventory (e.g. KIT... or spare serial).',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.4),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF334155),
                      side: const BorderSide(color: Color(0xFFCBD5E1), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                    label: const Text('Enter Manually', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openManualEntryDialog();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() => _isSheetOpen = false);
        }
      });
    });
  }

  Future<void> _openManualEntryDialog() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const ManualQrEntryDialog(),
    );
    if (!mounted || code == null || code.isEmpty) return;
    _onCodeDetected(code);
  }

  void _showProductAuthenticitySheet(ScannedRoItem item) {
    setState(() => _isSheetOpen = true);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          24 + math.max(MediaQuery.of(context).viewPadding.bottom, MediaQuery.of(context).padding.bottom),
        ),
        child: Column(
          children: [
            // Top Drag Handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                children: [
                  // 1. Genuine Verification Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.verified_rounded, color: Color(0xFF16A34A), size: 22),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '100% GENUINE FACTORY SPARE',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF15803D),
                                  letterSpacing: 0.4,
                                ),
                              ),
                              Text(
                                'Tamper-Proof Hologram • Verified',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10, color: Color(0xFF166534)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: item.isKit ? const Color(0xFFEFF6FF) : const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            item.isKit ? 'SERVICE KIT' : 'SPARE PART',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: item.isKit ? const Color(0xFF0284C7) : const Color(0xFFD97706),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 2. Product Image & Title
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Image.asset(
                          item.imageAsset,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) => const Icon(
                            Icons.settings_suggest_rounded,
                            size: 32,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.code,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF94A3B8),
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.name,
                              style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '₹${item.price.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                Text(
                                  '₹${item.mrp.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF94A3B8),
                                    decoration: TextDecoration.lineThrough,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${item.discountPercent.toStringAsFixed(0)}% OFF',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFF16A34A),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),
                  Text(
                    item.description,
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569), height: 1.4),
                  ),

                  const SizedBox(height: 14),

                  // 3. Technical & QC Verification Grid
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Builder(
                      builder: (_) {
                        final cbmSpec = CbmSpecHelper.resolveItemSpec(item.toJson());
                        final ratingText = cbmSpec.primaryRatingLabel ??
                            (item.warranty.trim().isNotEmpty ? item.warranty.trim() : null);
                        final ratingLabel = cbmSpec.partNature == 'CONSUMABLE'
                            ? 'Rated Filter Life'
                            : (cbmSpec.partNature == 'NON_CONSUMABLE'
                                ? 'Warranty Terms'
                                : (item.isKit ? 'Kit Coverage / Life' : 'Warranty / Life'));
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildVerificationRow(
                              'Factory Certification',
                              (item.batchNumber.isNotEmpty && item.batchNumber != 'TECH-INVENTORY-VERIFIED')
                                  ? item.batchNumber
                                  : 'Verified Scan',
                              Icons.qr_code_2_rounded,
                            ),
                            if (item.qcStatus.trim().isNotEmpty) ...[
                              const Divider(height: 12, color: Color(0xFFE2E8F0)),
                              _buildVerificationRow('QC Certification', item.qcStatus, Icons.fact_check_outlined),
                            ],
                            if (cbmSpec.natureLabel != null) ...[
                              const Divider(height: 12, color: Color(0xFFE2E8F0)),
                              _buildVerificationRow('Part Classification', cbmSpec.natureLabel!, cbmSpec.icon),
                            ],
                            if (ratingText != null) ...[
                              const Divider(height: 12, color: Color(0xFFE2E8F0)),
                              _buildVerificationRow(
                                ratingLabel,
                                ratingText,
                                cbmSpec.partNature == 'CONSUMABLE'
                                    ? Icons.water_drop_outlined
                                    : Icons.verified_user_outlined,
                              ),
                            ],
                            if (item.compatibility.trim().isNotEmpty) ...[
                              const Divider(height: 12, color: Color(0xFFE2E8F0)),
                              _buildVerificationRow('Purifier Fits', item.compatibility, Icons.check_circle_outline_rounded),
                            ],
                          ],
                        );
                      },
                    ),
                  ),

                  // If Kit: show bundled contents list
                  if (item.bundledItems.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    const Text(
                      'BUNDLED KIT CONTENTS',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.6),
                    ),
                    const SizedBox(height: 8),
                    ...item.bundledItems.map((bundle) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.check_rounded, size: 16, color: Color(0xFF0284C7)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(bundle, style: const TextStyle(fontSize: 12, color: Color(0xFF334155))),
                              ),
                            ],
                          ),
                        )),
                  ],
                  if (item.freeSpares.isNotEmpty)
                    SealedFreeSparesBox(
                      freeSpares: item.freeSpares,
                      margin: const EdgeInsets.only(top: 10),
                    ),

                  const SizedBox(height: 20),
                ],
              ),
            ),

            // Modal Bottom Actions: Two Options (Add & Scan More OR Review & Pay)
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0284C7),
                      side: const BorderSide(color: Color(0xFFBAE6FD), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Add & Scan More', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _addScannedItem(item);
                      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('Added ${item.name} (${_scannedDoorstepItems.length} in bill). Ready to scan next box.'),
                              ),
                            ],
                          ),
                          backgroundColor: const Color(0xFF16A34A),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(milliseconds: 1800),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 1,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.receipt_long_rounded, size: 18),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Review & Pay (${_scannedDoorstepItems.any((i) => i.code == item.code) ? _scannedDoorstepItems.length : _scannedDoorstepItems.length + 1})',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openVerificationAndPayScreen(item);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() => _isSheetOpen = false);
        }
      });
    });
  }

  Widget _buildVerificationRow(String title, String val, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF0284C7)),
        const SizedBox(width: 8),
        SizedBox(
          width: 95,
          child: Text(
            title,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
          ),
        ),
        Expanded(
          child: Text(
            val,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
          ),
        ),
      ],
    );
  }

  void _openCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CartBottomSheet(cartState: widget.cartState),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.cartState,
      builder: (context, _) {
        return ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                // 1. Camera Viewfinder Screen with Grid Background
                Column(
                  children: [
                    // Top Action Bar
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const Expanded(
                            child: Column(
                              children: [
                                Text(
                                  'Scan Genuine RO Spare QR',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                Text(
                                  'Technician Visit • Instant Verification',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          ScannerZoomPill(controller: _cameraController, compact: true),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: Icon(
                              _isTorchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                              color: _isTorchOn ? const Color(0xFFFBBF24) : Colors.white,
                              size: 22,
                            ),
                            onPressed: () async {
                              try {
                                await _cameraController.toggleTorch();
                                if (mounted) {
                                  setState(() => _isTorchOn = !_isTorchOn);
                                }
                              } catch (e) {
                                debugPrint('Torch toggle error: $e');
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Viewfinder Frame
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 300,
                          height: 215,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1.5),
                          ),
                          child: Stack(
                            children: [
                              // Live Hardware Camera Scanner
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(22),
                                  child: MobileScanner(
                                    controller: _cameraController,
                                    onDetect: _onBarcodeCapture,
                                    errorBuilder: (context, error) {
                                      return Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 36),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Camera: ${error.errorCode.name}',
                                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),

                              // 4 Corner Laser Reticles
                              const Positioned.fill(
                                child: CustomPaint(
                                  painter: _ScannerReticlePainter(),
                                ),
                              ),

                              // Animated Pulsing Laser Beam
                              AnimatedBuilder(
                                animation: _laserAnimation,
                                builder: (context, child) {
                                  return Positioned(
                                    top: 215 * _laserAnimation.value,
                                    left: 16,
                                    right: 16,
                                    child: Container(
                                      height: 2.5,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF38BDF8),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFF0284C7).withValues(alpha: 0.9),
                                            blurRadius: 10,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),

                              // Center helper text
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.qr_code_scanner_rounded,
                                      size: 40,
                                      color: Colors.white.withValues(alpha: 0.2),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Align QR or Barcode inside the frame',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.5),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
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

                    // Pure physical inventory scanning pill
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.verified_user_rounded, color: Color(0xFF38BDF8), size: 14),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Scanning Genuine RO Spares in Technician Custody',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Manual Entry Option
                    Center(
                      child: BouncingWidget(
                        onTap: _openManualEntryDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.keyboard_alt_outlined, color: Color(0xFF38BDF8), size: 16),
                              SizedBox(width: 8),
                              Text(
                                "Can't scan? Enter Code Manually",
                                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    SizedBox(height: (_scannedDoorstepItems.isNotEmpty || widget.cartState.itemCount > 0) ? 88 : 24),
                  ],
                ),

                // Floating Bottom Spares Verification & Bill Bar
                if (_scannedDoorstepItems.isNotEmpty || widget.cartState.itemCount > 0)
                  Positioned(
                    bottom: 12,
                    left: 16,
                    right: 16,
                    child: BouncingWidget(
                      onTap: () {
                        if (_scannedDoorstepItems.isNotEmpty) {
                          _openVerificationAndPayScreen();
                        } else {
                          _openCart();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0284C7).withValues(alpha: 0.4),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '${_scannedDoorstepItems.isNotEmpty ? _scannedDoorstepItems.length : widget.cartState.itemCount}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF0284C7),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _scannedDoorstepItems.isNotEmpty
                                              ? '${_scannedDoorstepItems.length} Genuine ${_scannedDoorstepItems.length == 1 ? "Item" : "Items"} Scanned'
                                              : 'Unified Cart & Spares Bill',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        Text(
                                          _scannedDoorstepItems.isNotEmpty
                                              ? 'Tap to Inspect Seals & Pay'
                                              : '₹${widget.cartState.finalPayableAmount} payable • Tap to Review',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Row(
                              children: [
                                Text(
                                  'Review & Pay',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                                ),
                                SizedBox(width: 4),
                                Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
                              ],
                            ),
                          ],
                        ),
                      ),
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

class _ScannerReticlePainter extends CustomPainter {
  const _ScannerReticlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0284C7)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const double len = 28;
    const double r = 18;
    final w = size.width;
    final h = size.height;

    final path = Path()
      // Top-left
      ..moveTo(0, len)
      ..lineTo(0, r)
      ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
      ..lineTo(len, 0)
      // Top-right
      ..moveTo(w - len, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, len)
      // Bottom-left
      ..moveTo(0, h - len)
      ..lineTo(0, h - r)
      ..arcToPoint(Offset(r, h), radius: const Radius.circular(r), clockwise: false)
      ..lineTo(len, h)
      // Bottom-right
      ..moveTo(w - len, h)
      ..lineTo(w - r, h)
      ..arcToPoint(Offset(w, h - r), radius: const Radius.circular(r), clockwise: false)
      ..lineTo(w, h - len);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Self-contained manual QR/serial entry dialog owning its [TextEditingController]
/// so disposal waits until Flutter finishes the closing transition and unmounts [TextField].
class ManualQrEntryDialog extends StatefulWidget {
  const ManualQrEntryDialog({super.key});

  @override
  State<ManualQrEntryDialog> createState() => _ManualQrEntryDialogState();
}

class _ManualQrEntryDialogState extends State<ManualQrEntryDialog> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.keyboard_alt_outlined, color: Color(0xFF0284C7)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Enter Part or Kit Serial',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter spare part serial, kit QR, or promo code (e.g. A00001, KIT00001, COUPON:CODE):',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            onSubmitted: (raw) => _close(raw.trim()),
            decoration: InputDecoration(
              hintText: 'e.g. A00001 or KIT00001',
              filled: true,
              fillColor: const Color(0xFFF1F5F9),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0284C7),
            foregroundColor: Colors.white,
          ),
          onPressed: () => _close(_textController.text.trim()),
          child: const Text('Verify Code'),
        ),
      ],
    );
  }
}
