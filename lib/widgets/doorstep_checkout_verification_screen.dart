import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/phone_normalizer.dart';
import '../utils/unit_helper.dart';
import '../services/coupon_registry.dart';
import '../services/doorstep_pricing.dart';
import '../services/doorstep_session_manager.dart';
import '../services/qr_product_registry.dart';
import '../services/universal_scanner_helper.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import 'bouncing_widget.dart';
import 'razorpay_checkout_sheet.dart';

class DoorstepCheckoutVerificationScreen extends StatefulWidget {
  final List<ScannedRoItem> initialItems;
  final CartState cartState;
  final ServiceTrackingState? serviceState;
  final VoidCallback onScanMore;
  final VoidCallback? onPaymentComplete;
  final ValueChanged<List<ScannedRoItem>>? onItemsChanged;

  const DoorstepCheckoutVerificationScreen({
    super.key,
    required this.initialItems,
    required this.cartState,
    this.serviceState,
    required this.onScanMore,
    this.onPaymentComplete,
    this.onItemsChanged,
  });

  @override
  State<DoorstepCheckoutVerificationScreen> createState() =>
      _DoorstepCheckoutVerificationScreenState();
}

class _DoorstepCheckoutVerificationScreenState
    extends State<DoorstepCheckoutVerificationScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late List<ScannedRoItem> _items;
  final Map<String, Set<String>> _verifiedChildSerials = {}; // kitCode -> set of child QRs

  // Coupon state (Single Source of Truth from backend API)
  String? _appliedCouponCode;
  double _couponDiscount = 0.0;
  List<Map<String, dynamic>> _availableCoupons = [];
  bool _isCouponsLoading = true;

  static double _toDouble(dynamic val, [double fallback = 0.0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? fallback;
  }

  // Selected UPI App Preference
  static const String _selectedUpiApp = 'upi';

  bool _isProcessing = false;
  bool _isAwaitingPaymentConfirmation = false;
  bool _isPaymentFailed = false;
  String? _failureReason;
  Map<String, dynamic>? _failoverInfo;
  bool _isLastStatusExpired = false;
  bool _isCheckingStatusOnce = false;
  bool _doorstepRecheckQueued = false;
  bool _isAppInForeground = true;
  String? _pendingCheckoutRefId;
  double _pendingPayableAmount = 0.0;
  int _clearancePollAttempts = 0;
  Timer? _pollingTimer;
  String? _inPageError;
  String? get _customerScopeId {
    final scoped = PhoneNormalizer.toCustomerId(
      widget.cartState.customerId ?? widget.cartState.userPhone,
    );
    return scoped.isNotEmpty ? scoped : null;
  }

  String? _pendingGatewayOrderId;
  String? _pendingRazorpayKeyId;
  String? _pendingRzpOrderId;

  // Breathing animation for floating shoulder badge
  late AnimationController _breathingController;
  late Animation<double> _breathingScale;

  final TextEditingController _hiddenCouponCtrl = TextEditingController();

  dynamic get _visitId => widget.serviceState?.bookingId ?? '0';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _items = List<ScannedRoItem>.from(widget.initialItems);

    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _breathingScale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOut),
    );

    _restoreSessionOrAutoApply();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _breathingController.dispose();
    _pollingTimer?.cancel();
    _hiddenCouponCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && _pendingCheckoutRefId != null) {
      if (_isAwaitingPaymentConfirmation) {
        _clearancePollAttempts = 0;
        _startBackgroundPaymentClearanceWatcher(
          _pendingCheckoutRefId!,
          _pendingPayableAmount > 0 ? _pendingPayableAmount : _inAppPayableAmount,
        );
        _checkDoorstepStatusOnce(_pendingCheckoutRefId!, immediate: true);
      } else if (_isPaymentFailed) {
        _checkDoorstepStatusOnce(
          _pendingCheckoutRefId!,
          immediate: true,
          suppressDialogOnFailure: true,
        );
      }
    }
  }

  Future<void> _reloadAvailableCoupons({String? customerId}) async {
    final cid = customerId ??
        widget.cartState.customerId ??
        (widget.cartState.userPhone.isNotEmpty ? widget.cartState.userPhone : null);
    try {
      final coupons = await ApiService().getCoupons(
        channel: 'TECHNICIAN',
        customerId: cid,
      );
      if (mounted) {
        setState(() {
          _availableCoupons = coupons;
          _isCouponsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isCouponsLoading = false);
      }
    }
  }

  Future<void> _restoreSessionOrAutoApply() async {
    final customerId = widget.cartState.customerId ??
        (widget.cartState.userPhone.isNotEmpty ? PhoneNormalizer.toCustomerId(widget.cartState.userPhone) : '');

    // 0. Load active public TECHNICIAN coupons from backend (with per-user exhaustion status)
    await _reloadAvailableCoupons(customerId: customerId);

    // 1. Try restore from session
    final saved = await DoorstepSessionManager.loadSession(
      _visitId,
      customerId: _customerScopeId,
    );
    if (saved != null) {
      final savedCoupon = saved['applied_coupon'] as String?;
      if (savedCoupon != null && savedCoupon.isNotEmpty) {
        await _applyCouponInternal(
          savedCoupon,
          notifyUser: false,
          clearPendingOnSuccess: false,
        );
      }

      final currentCodes = _items.map((i) => i.code.trim().toUpperCase()).toList()..sort();
      final savedSignature = saved['pending_item_signature'] is List
          ? (saved['pending_item_signature'] as List)
              .map((e) => e.toString().trim().toUpperCase())
              .where((e) => e.isNotEmpty)
              .toList()
          : DoorstepSessionManager.itemCodesSignature(
              saved['items'] is List ? saved['items'] as List : const [],
            );
      savedSignature.sort();

      final savedRef = (saved['pending_checkout_ref_id'] ?? '').toString().trim();
      final savedPayable = _toDouble(saved['pending_payable_amount'], _inAppPayableAmount);
      final itemsMatch = DoorstepSessionManager.signaturesMatch(currentCodes, savedSignature);

      if (itemsMatch && savedRef.isNotEmpty && mounted) {
        _pendingCheckoutRefId = savedRef;
        _pendingPayableAmount = savedPayable > 0 ? savedPayable : _inAppPayableAmount;
        _isAwaitingPaymentConfirmation = false;
        _isProcessing = false;
        _isPaymentFailed = false;
        _failureReason = null;
        _persistSession();
        _checkDoorstepStatusOnce(
          savedRef,
          immediate: true,
          suppressDialogOnFailure: true,
        );
        return;
      } else if (!itemsMatch && savedRef.isNotEmpty) {
        _persistSession(clearPendingCheckout: true);
      }
    }
    unawaited(_refreshScannedItemPrices());
    if ((saved == null || _appliedCouponCode == null || _appliedCouponCode!.isEmpty) &&
        _availableCoupons.isNotEmpty &&
        _items.isNotEmpty) {
      // Auto-apply top eligible public coupon from backend DB
      final best = _availableCoupons.cast<Map<String, dynamic>?>().firstWhere(
            (c) =>
                c != null &&
                c['is_exhausted'] != true &&
                _totalMrp >= _toDouble(c['min_order_value']),
            orElse: () => null,
          );
      if (best != null && best['code'] != null) {
        await _applyCouponInternal(
          best['code'].toString(),
          notifyUser: false,
          fromAutoApply: true,
        );
      }
    }
    _persistSession();
  }

  void _clearPendingGatewaySessionState() {
    _pollingTimer?.cancel();
    _pendingCheckoutRefId = null;
    _pendingPayableAmount = 0.0;
    _pendingGatewayOrderId = null;
    _pendingGatewayOrderId = null;
    _pendingRazorpayKeyId = null;
    _pendingRzpOrderId = null;
    _pendingRazorpayKeyId = null;
    _pendingRzpOrderId = null;
    _isAwaitingPaymentConfirmation = false;
    _isPaymentFailed = false;
    _failureReason = null;
    _failoverInfo = null;
    _isLastStatusExpired = false;
  }

  void _persistSession({bool clearPendingCheckout = false}) {
    final rawList = _items.map((item) {
      final jsonItem = item.toJson();
      jsonItem['verified_serials'] = (_verifiedChildSerials[item.code] ?? {}).toList();
      return jsonItem;
    }).toList();

    DoorstepSessionManager.saveSession(
      visitId: _visitId,
      customerId: _customerScopeId,
      items: rawList,
      appliedCoupon: _appliedCouponCode,
      pendingCheckoutRefId: clearPendingCheckout ? null : _pendingCheckoutRefId,
      pendingPayableAmount: clearPendingCheckout ? null : _pendingPayableAmount,
      clearPendingCheckout: clearPendingCheckout,
    );
  }

  /// Syncs scanned items with live catalog prices from backend on screen open
  /// (so restored sessions never display stale cached ₹ values).
  Future<void> _refreshScannedItemPrices() async {
    if (_items.isEmpty || !mounted) return;
    final customerId = _customerScopeId;
    final visitId = int.tryParse(widget.serviceState?.bookingId ?? '0');
    bool anyUpdated = false;
    final updatedList = List<ScannedRoItem>.from(_items);

    for (var i = 0; i < updatedList.length; i++) {
      final item = updatedList[i];
      try {
        final res = await ApiService().verifyDoorstepScan(
          serialQr: item.code,
          visitId: visitId,
          customerId: customerId,
        );
        if (!mounted) return;
        if (res['verified'] == true) {
          final liveMrp = _toDouble(res['mrp'], 0.0);
          final liveName = (res['name'] ?? '').toString().trim();
          final rawComps = res['items'] is List
              ? (res['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()
              : item.rawComponents;
          final rawFree = res['free_spares'] is List
              ? (res['free_spares'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
              : item.freeSpares;
          final resSku = (res['sku'] ?? res['recipe_id'])?.toString();
          final resSealed = res['sealed_free_spares'] == true;
          final resVisitFree = res['is_complimentary_with_visit_kit'] == true;
          if ((liveMrp > 0 && ((liveMrp - item.mrp).abs() >= 0.05 || (liveName.isNotEmpty && liveName != item.name))) ||
              (resSku != null && resSku != item.sku) ||
              rawFree.length != item.freeSpares.length ||
              resSealed != item.sealedFreeSpares ||
              resVisitFree != item.isComplimentary) {
            anyUpdated = true;
            updatedList[i] = item.copyWith(
              name: liveName.isNotEmpty ? liveName : item.name,
              mrp: liveMrp > 0 ? liveMrp : item.mrp,
              price: liveMrp > 0 ? liveMrp : item.price,
              rawComponents: rawComps,
              sku: resSku ?? item.sku,
              freeSpares: rawFree,
              sealedFreeSpares: resSealed || item.sealedFreeSpares,
              isComplimentary: resVisitFree || item.isComplimentary,
            );
          }
        }
      } catch (_) {}
    }

    if (anyUpdated && mounted) {
      setState(() {
        _items = updatedList;
        _clearPendingGatewaySessionState();
      });
      widget.onItemsChanged?.call(List<ScannedRoItem>.from(_items));
      if (_appliedCouponCode != null && _appliedCouponCode!.isNotEmpty) {
        await _applyCouponInternal(_appliedCouponCode!, notifyUser: false);
      } else {
        _persistSession(clearPendingCheckout: true);
      }
    }
  }

  /// Applies authoritative live item/coupon pricing returned by server on payment initiation/retry.
  void _applyServerPriceUpdate(
    Map<String, dynamic> payload, {
    required double previousPayable,
    bool preserveGatewaySession = false,
  }) {
    final verifiedList = payload['verified_items'] is List ? payload['verified_items'] as List : const [];
    if (verifiedList.isNotEmpty) {
      final bySerial = <String, Map<String, dynamic>>{};
      for (final raw in verifiedList) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        for (final key in ['component_qr', 'kit_qr', 'serial_qr', 'serial', 'code', 'sku']) {
          final k = (m[key] ?? '').toString().trim().toUpperCase();
          if (k.isNotEmpty) bySerial[k] = m;
        }
      }
      if (bySerial.isNotEmpty) {
        _items = _items.map((item) {
          final matched = bySerial[item.code.trim().toUpperCase()];
          if (matched == null) return item;
          final liveMrp = _toDouble(matched['mrp'] ?? matched['unit_mrp'], item.mrp);
          final liveName = (matched['name'] ?? matched['recipe_name'] ?? '').toString().trim();
          final comps = matched['components'] is List
              ? (matched['components'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()
              : item.rawComponents;
          return item.copyWith(
            name: liveName.isNotEmpty ? liveName : item.name,
            mrp: liveMrp > 0 ? liveMrp : item.mrp,
            price: liveMrp > 0 ? liveMrp : item.price,
            rawComponents: comps,
            sku: (matched['sku'] ?? matched['recipe_id'])?.toString() ?? item.sku,
            freeSpares: matched['free_spares'] is List
                ? (matched['free_spares'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
                : item.freeSpares,
            sealedFreeSpares: matched['sealed_free_spares'] == true || item.sealedFreeSpares,
            isComplimentary: matched['is_complimentary'] == true || item.isComplimentary,
          );
        }).toList();
        widget.onItemsChanged?.call(List<ScannedRoItem>.from(_items));
      }
    }

    if (payload.containsKey('verified_discount')) {
      final nextDisc = _toDouble(payload['verified_discount'], 0.0);
      final couponValid = payload['coupon_valid'] != false;
      final nextCoupon = payload['verified_coupon_code']?.toString().trim();
      if (!couponValid) {
        _appliedCouponCode = null;
        _couponDiscount = 0.0;
      } else {
        if (nextCoupon != null && nextCoupon.isNotEmpty) {
          _appliedCouponCode = nextCoupon.toUpperCase();
        }
        _couponDiscount = nextDisc;
      }
    }

    if (!preserveGatewaySession) {
      _clearPendingGatewaySessionState();
    } else {
      _isPaymentFailed = false;
      _failureReason = null;
    }

    final nextPayable = _inAppPayableAmount > 0
        ? _inAppPayableAmount
        : _toDouble(payload['verified_net_payable'] ?? payload['net_payable'], previousPayable);
    if (preserveGatewaySession) {
      _pendingPayableAmount = nextPayable;
    }
    _persistSession(clearPendingCheckout: !preserveGatewaySession);

    setState(() {
      _isProcessing = false;
      _inPageError = null;
    });
  }

  // Financial calculations aligned to customer MRP = SUM(products) minus kit-coupled free spares (5022 Free Issue).
  DoorstepFreeAllocation get _freeAllocation => DoorstepPricing.allocateFreeKitSpares(
        _items
            .map(
              (item) => DoorstepFreeItemInput(
                sku: item.sku,
                isKit: item.isKit,
                mrp: item.mrp,
                quantity: 1,
                freeSpares: item.freeSpares,
                sealedFreeSpares: item.sealedFreeSpares,
                isExplicitComplimentary: item.isComplimentary,
              ),
            )
            .toList(),
      );

  DoorstepPriceBreakdown get _pricing => DoorstepPricing.calculate(
        totalMrp: _freeAllocation.billableMrp,
        couponDiscount: _couponDiscount,
        freeSparesMrp: _freeAllocation.freeSparesMrp,
      );

  double get _totalMrp => _pricing.totalMrp;

  double get _freeSparesSavings => _pricing.freeSparesMrp;

  double get _sealedFreeSparesValue {
    double total = 0.0;
    for (final item in _items) {
      if (item.isKit && item.freeSpares.isNotEmpty) {
        for (final sp in item.freeSpares) {
          final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
          final u = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
          total += (q > 0 ? q : 1) * u;
        }
      }
    }
    return total;
  }

  double get _maxDiscountAllowed => _pricing.maxDiscountAllowed;

  double get _effectiveDiscount => _pricing.effectiveDiscount;

  double get _inAppPayableAmount =>
      _items.isEmpty ? 0.0 : _pricing.netPayable;

  Future<void> _applyCouponInternal(
    String code, {
    bool notifyUser = true,
    bool fromAutoApply = false,
    bool clearPendingOnSuccess = true,
  }) async {
    final cleanCode =
        CouponRegistry.normalizeScannedCode(code) ?? code.trim().toUpperCase();
    if (cleanCode.isEmpty) return;

    final customerId = widget.cartState.customerId ??
        (widget.cartState.userPhone.isNotEmpty ? PhoneNormalizer.toCustomerId(widget.cartState.userPhone) : '');

    try {
      final res = await ApiService().validateCoupon(
        code: cleanCode,
        channel: 'TECHNICIAN',
        amount: _totalMrp,
        mrp: _totalMrp,
        customerId: customerId,
      );

      if (res['success'] == true) {
        final nextDiscount = _toDouble(res['discount'], 0.0);
        final previewPricing = DoorstepPricing.calculate(
          totalMrp: _totalMrp,
          couponDiscount: nextDiscount,
        );
        // Never auto-apply a promo that pushes payable below Razorpay's ₹1.00 minimum.
        if (fromAutoApply && previewPricing.isBelowGatewayMinimum) {
          return;
        }
        HapticFeedback.lightImpact();
        setState(() {
          _appliedCouponCode = (res['code'] ?? cleanCode).toString().toUpperCase();
          _couponDiscount = nextDiscount;
          _inPageError = null;
          if (clearPendingOnSuccess) {
            _clearPendingGatewaySessionState();
          }
        });
        _persistSession(clearPendingCheckout: clearPendingOnSuccess);
        if (notifyUser && mounted) {
          final savedText = DoorstepPricing.formatRupees(_effectiveDiscount);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text('🎉 Promo Code ${_appliedCouponCode!} applied! Saved ₹$savedText'),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        final errMsg = (res['error'] ?? 'Invalid or expired coupon').toString();
        final isExhausted = res['is_exhausted'] == true;
        final shouldClearApplied = !notifyUser || isExhausted || _appliedCouponCode == cleanCode;
        if (mounted) {
          setState(() {
            if (shouldClearApplied) {
              _appliedCouponCode = null;
              _couponDiscount = 0.0;
              if (clearPendingOnSuccess) {
                _clearPendingGatewaySessionState();
              }
            }
            if (notifyUser) {
              _inPageError = errMsg;
            }
          });
        }
        if (shouldClearApplied && clearPendingOnSuccess) {
          _persistSession(clearPendingCheckout: true);
        }
        if (isExhausted) {
          unawaited(_reloadAvailableCoupons(customerId: customerId));
        }
        if (notifyUser && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(errMsg),
              backgroundColor: const Color(0xFFDC2626),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (_) {
      if (notifyUser && mounted) {
        setState(() {
          _inPageError = 'Unable to verify coupon right now. Please retry.';
        });
      }
    }
  }

  void _removeCoupon() {
    HapticFeedback.selectionClick();
    setState(() {
      _appliedCouponCode = null;
      _couponDiscount = 0.0;
      _inPageError = null;
      _clearPendingGatewaySessionState();
    });
    _persistSession(clearPendingCheckout: true);
  }

  void _removeItem(int index) {
    HapticFeedback.mediumImpact();
    final String? previousCoupon = _appliedCouponCode;
    setState(() {
      final removed = _items.removeAt(index);
      _verifiedChildSerials.remove(removed.code);
      _clearPendingGatewaySessionState();
      _inPageError = null;
      if (_items.isEmpty) {
        _appliedCouponCode = null;
        _couponDiscount = 0.0;
      }
    });
    widget.onItemsChanged?.call(List<ScannedRoItem>.from(_items));
    if (_items.isEmpty) {
      DoorstepSessionManager.clearSession(
        _visitId,
        customerId: _customerScopeId,
      );
    } else {
      _persistSession(clearPendingCheckout: true);
      if (previousCoupon != null && previousCoupon.isNotEmpty) {
        unawaited(_applyCouponInternal(previousCoupon, notifyUser: false));
      }
    }
  }

  /// Launch optional in-sheet seal camera scanner
  void _openSealScannerSheet(ScannedRoItem parentKit, [Map<String, dynamic>? specificComp]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SealScannerSheet(
        parentKit: parentKit,
        specificComp: specificComp,
        onVerified: (matchedSerial, matchedName) {
          if (!mounted) return;
          setState(() {
            _verifiedChildSerials.putIfAbsent(parentKit.code, () => {}).add(matchedSerial);
          });
          _persistSession();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Seal verified: $matchedName!')),
                ],
              ),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  Future<void> _launchDoorstepBrowserUrl(String checkoutUrl) async {
    final uri = Uri.parse(checkoutUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (err) {
        debugPrint('Error launching payment webview: $err');
      }
    }
  }

  Map<String, dynamic>? _extractFailover(Map<String, dynamic> res) {
    final raw = res['failover'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  /// Retry existing temporary checkout session via ?retry=1 / ?switch_gateway=1, or safely create a fresh session if expired/missing
  Future<void> _retryDoorstepPayment({bool switchGateway = false}) async {
    final existingRef = _pendingCheckoutRefId;
    final requestedSwitch =
        switchGateway || (_failoverInfo?['should_try_another_option'] == true);
    if (existingRef != null && !_isLastStatusExpired) {
      setState(() {
        _isProcessing = true;
        _isPaymentFailed = false;
        _failureReason = null;
        _inPageError = null;
      });
      try {
        final precheck = await ApiService().checkCheckoutStatus(existingRef, live: true);
        if (!mounted) return;
        final preFailover = _extractFailover(precheck);
        if (preFailover != null) {
          _failoverInfo = preFailover;
        }
        final useSwitch = requestedSwitch ||
            (_failoverInfo?['should_try_another_option'] == true);
        final st = (precheck['status'] ?? '').toString().trim().toUpperCase();
        final isCleared = precheck['paid'] == true ||
            precheck['is_cleared'] == true ||
            precheck['already_paid'] == true ||
            st == 'CLEARED' ||
            st == 'PAID' ||
            st == 'COMPLETED' ||
            st == 'SETTLED';
        final isRefunded =
            precheck['is_refunded'] == true || st == 'REFUNDED';
        final isExpired = precheck['is_expired'] == true ||
            st == 'EXPIRED' ||
            st == 'NOT_FOUND';

        if (isCleared) {
          setState(() => _isProcessing = false);
          await _handleDoorstepPaymentCleared(
            existingRef,
            _pendingPayableAmount > 0 ? _pendingPayableAmount : _inAppPayableAmount,
          );
          return;
        }

        if (isRefunded) {
          _pollingTimer?.cancel();
          final payable = _pendingPayableAmount > 0
              ? _pendingPayableAmount
              : _inAppPayableAmount;
          await DoorstepSessionManager.clearSession(
            _visitId,
            customerId: _customerScopeId,
          );
          if (!mounted) return;
          setState(() {
            _isProcessing = false;
            _isAwaitingPaymentConfirmation = false;
            _isPaymentFailed = false;
            _failureReason = null;
            _failoverInfo = null;
            _pendingCheckoutRefId = null;
            _pendingPayableAmount = 0.0;
          });
          _showRefundNotificationDialog(
            refId: existingRef,
            amount: _toDouble(precheck['amount'], payable),
            refundId: precheck['refund_id'] as String?,
          );
          return;
        }

        if (!isExpired) {
          setState(() => _isProcessing = false);
          final payable = _pendingPayableAmount > 0
              ? _pendingPayableAmount
              : _inAppPayableAmount;
          String? gwOrderId = _pendingGatewayOrderId;
          String? rzpKeyId = _pendingRazorpayKeyId;
          String? rzpOrderId = _pendingRzpOrderId;
          String? upiUri;
          String? gw = precheck['gateway']?.toString();

          if (!useSwitch && !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
            try {
              final refreshed = await ApiService()
                  .retryCheckoutSession(existingRef, retry: true);
              if (!mounted) return;
              final refSt =
                  (refreshed['status'] ?? '').toString().trim().toUpperCase();
              if (refreshed['paid'] == true ||
                  refreshed['is_cleared'] == true ||
                  refSt == 'CLEARED' ||
                  refSt == 'PAID') {
                await _handleDoorstepPaymentCleared(existingRef, payable);
                return;
              }
              if (refreshed['is_refunded'] == true ||
                  refSt == 'REFUNDED' ||
                  refreshed['statusCode'] == 409) {
                _pollingTimer?.cancel();
                await DoorstepSessionManager.clearSession(
                  _visitId,
                  customerId: _customerScopeId,
                );
                if (!mounted) return;
                _showRefundNotificationDialog(
                  refId: existingRef,
                  amount: _toDouble(refreshed['amount'], payable),
                  refundId: refreshed['refund_id']?.toString(),
                );
                return;
              }
              gwOrderId = refreshed['gateway_order_id']?.toString().trim() ?? gwOrderId;
              gw = refreshed['gateway']?.toString().trim() ?? gw;
              rzpKeyId = (refreshed['razorpay_key_id'] ?? refreshed['key_id'])?.toString().trim() ?? rzpKeyId;
              rzpOrderId = (refreshed['rzp_order_id'] ?? refreshed['razorpay_order_id'])?.toString().trim() ?? rzpOrderId;
              if ((rzpOrderId == null || rzpOrderId.isEmpty) && (gwOrderId ?? '').startsWith('order_')) {
                rzpOrderId = gwOrderId;
              }
              upiUri = refreshed['upi_uri']?.toString().trim() ?? upiUri;

              final refPayable = _toDouble(
                refreshed['verified_net_payable'] ?? refreshed['net_payable'] ?? refreshed['amount'],
                payable,
              );
              if (refreshed['price_updated'] == true || (refPayable - payable).abs() >= 0.05) {
                _pendingGatewayOrderId = gwOrderId;
                if (rzpKeyId != null && rzpKeyId.isNotEmpty) _pendingRazorpayKeyId = rzpKeyId;
                if (rzpOrderId != null && rzpOrderId.isNotEmpty) _pendingRzpOrderId = rzpOrderId;
                _applyServerPriceUpdate(
                  refreshed,
                  previousPayable: payable,
                  preserveGatewaySession: true,
                );
                return;
              }
            } catch (_) {}
          }

          final hasNativeRazorpay = (rzpKeyId != null && rzpKeyId.isNotEmpty) &&
              ((rzpOrderId != null && rzpOrderId.isNotEmpty) || (gwOrderId ?? '').startsWith('order_'));

          if (!hasNativeRazorpay && !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
            debugPrint('[Doorstep Retry] No native Razorpay order on retry. Forcing fresh session...');
            await _processPayment(forceFreshSession: true);
            return;
          }

          final retryQuery = useSwitch ? 'switch_gateway=1' : 'retry=1';
          final retryUrl =
              '${ApiService.cbmBaseUrl}/checkout/${Uri.encodeComponent(existingRef)}?$retryQuery';
          await _launchNativeOrFallbackDoorstepCheckout(
            refId: existingRef,
            payable: payable,
            gatewayOrderId: gwOrderId,
            primaryGateway: useSwitch ? null : gw,
            razorpayKeyId: rzpKeyId,
            rzpOrderId: rzpOrderId,
            fallbackCheckoutUrl: retryUrl,
            upiUri: upiUri,
          );
          return;
        }
      } catch (e) {
        debugPrint('[Doorstep Retry] Precheck error: $e');
      }
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _pendingCheckoutRefId = null;
        _pendingPayableAmount = 0.0;
        _isLastStatusExpired = false;
      });
      _persistSession(clearPendingCheckout: true);
    } else {
      _pendingCheckoutRefId = null;
      _pendingPayableAmount = 0.0;
      _isLastStatusExpired = false;
      _persistSession(clearPendingCheckout: true);
    }

    await _processPayment(forceFreshSession: true);
  }

  /// Initiate Doorstep Checkout (Strict CBM Sovereign Integration)
  Future<void> _processPayment({bool forceFreshSession = false}) async {
    if (_items.isEmpty) {
      setState(() => _inPageError = 'No genuine items in bill to pay for.');
      return;
    }

    if (_pricing.isBelowGatewayMinimum) {
      setState(() {
        _inPageError = DoorstepPricing.belowGatewayMinimumMessage(_inAppPayableAmount);
      });
      return;
    }

    if (!forceFreshSession &&
        _pendingCheckoutRefId != null &&
        !_isLastStatusExpired) {
      await _retryDoorstepPayment();
      return;
    }

    final previousDisplayedPayable = _inAppPayableAmount;
    setState(() {
      _isProcessing = true;
      _isPaymentFailed = false;
      _failureReason = null;
      _isLastStatusExpired = false;
      _inPageError = null;
    });
    HapticFeedback.lightImpact();

    final customerId = widget.cartState.customerId ??
        (widget.cartState.userPhone.isNotEmpty ? PhoneNormalizer.toCustomerId(widget.cartState.userPhone) : '');
    final visitId = int.tryParse(widget.serviceState?.bookingId ?? '0') ?? 0;

    final checkoutItems = List<Map<String, dynamic>>.generate(_items.length, (idx) {
      final i = _items[idx];
      final isFree = _freeAllocation.isItemComplimentary(idx);
      return {
        'serial_qr': i.code,
        'code': i.code,
        if (i.isKit) 'kit_qr': i.code,
        if (!i.isKit) 'component_qr': i.code,
        if (i.sku != null && i.sku!.isNotEmpty) 'sku': i.sku,
        'type': i.isKit ? 'KIT' : 'PRODUCT',
        'qty': 1,
        'mrp': i.mrp,
        if (isFree) 'is_complimentary': true,
      };
    });

    try {
      final res = await ApiService().initiateDoorstepCheckout(
        visitId: visitId,
        customerId: customerId,
        items: checkoutItems,
        couponCode: _appliedCouponCode,
        amount: _inAppPayableAmount,
        totalMrp: _totalMrp,
        discountAmount: _effectiveDiscount,
        allowZeroComplimentary: _pricing.isZeroComplimentary,
      );

      if (!mounted) return;
      setState(() => _isProcessing = false);

      final payable = _toDouble(
        res['breakdown']?['net_payable'],
        _toDouble(res['net_payable'], _toDouble(res['amount'], _inAppPayableAmount)),
      );
      final rawRefId = (res['order_id'] ??
              res['cbm_checkout_token'] ??
              res['order']?['order_number'] ??
              _pendingCheckoutRefId ??
              '')
          .toString()
          .trim();

      // Immediate confirmation if PG/CBM says payment is already deducted/cleared (including HTTP 409)
      if (res['already_paid'] == true) {
        final confirmedRef = rawRefId;
        if (confirmedRef.isNotEmpty) {
          await _handleDoorstepPaymentCleared(confirmedRef, payable);
        }
        return;
      }

      // Final Pre-Payment Live Price Check: if server price changed before payment, update & pause for user confirmation
      if (res['error'] == 'MRP_MISMATCH' ||
          res['price_updated'] == true ||
          (res['success'] == true && (payable - previousDisplayedPayable).abs() >= 0.05)) {
        final hasFreshPgOrder = res['success'] == true && rawRefId.isNotEmpty;
        if (hasFreshPgOrder) {
          _pendingCheckoutRefId = rawRefId;
          _pendingGatewayOrderId = res['gateway_order_id']?.toString().trim();
          _pendingRazorpayKeyId = (res['razorpay_key_id'] ?? res['key_id'])?.toString().trim();
          _pendingRzpOrderId = (res['rzp_order_id'] ?? res['razorpay_order_id'])?.toString().trim();
          if ((_pendingRzpOrderId == null || _pendingRzpOrderId!.isEmpty) &&
              (_pendingGatewayOrderId ?? '').startsWith('order_')) {
            _pendingRzpOrderId = _pendingGatewayOrderId;
          }
        }
        _applyServerPriceUpdate(
          res,
          previousPayable: previousDisplayedPayable,
          preserveGatewaySession: hasFreshPgOrder,
        );
        return;
      }

      if (res['success'] == true) {
        if (rawRefId.isEmpty) {
          setState(() {
            _inPageError = 'Checkout reference missing from server. Please retry.';
          });
          return;
        }
        final refId = rawRefId;

        // 1. Persist single temporary checkout reference
        _pendingCheckoutRefId = refId;
        _pendingPayableAmount = payable;
        _pendingGatewayOrderId = res['gateway_order_id']?.toString().trim();
        _pendingRazorpayKeyId = (res['razorpay_key_id'] ?? res['key_id'])?.toString().trim();
        _pendingRzpOrderId = (res['rzp_order_id'] ?? res['razorpay_order_id'])?.toString().trim();
        if ((_pendingRzpOrderId == null || _pendingRzpOrderId!.isEmpty) &&
            (_pendingGatewayOrderId ?? '').startsWith('order_')) {
          _pendingRzpOrderId = _pendingGatewayOrderId;
        }
        _persistSession();

        // 2. Open Apple-Style Native Razorpay Custom UI (with Chrome fallback if needed)
        final rawCheckoutUrl = res['payment_url']?.toString().trim();
        final checkoutUrl = (rawCheckoutUrl != null && rawCheckoutUrl.isNotEmpty)
            ? rawCheckoutUrl
            : (res['link_url']?.toString().trim() ?? '${ApiService.cbmBaseUrl}/checkout/$refId');
        await _launchNativeOrFallbackDoorstepCheckout(
          refId: refId,
          payable: payable,
          gatewayOrderId: _pendingGatewayOrderId,
          primaryGateway:
              (res['primary_gateway'] ?? res['gateway'])?.toString(),
          razorpayKeyId: _pendingRazorpayKeyId,
          rzpOrderId: _pendingRzpOrderId,
          fallbackCheckoutUrl: checkoutUrl,
          upiUri: res['upi_uri']?.toString(),
        );
      } else {
        setState(() {
          _inPageError = res['error'] ?? res['message'] ?? 'Checkout initiation failed. Please retry.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _inPageError = 'Connection error: $e';
        });
      }
    }
  }

  Future<void> _handleDoorstepPaymentCleared(String refId, double payableAmount) async {
    _pollingTimer?.cancel();
    try {
      await closeInAppWebView();
    } catch (_) {}
    await DoorstepSessionManager.clearSession(
      _visitId,
      customerId: _customerScopeId,
    );

    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isAwaitingPaymentConfirmation = false;
        _isPaymentFailed = false;
        _failureReason = null;
        _isLastStatusExpired = false;
        _pendingCheckoutRefId = null;
        _pendingPayableAmount = 0.0;
      });
      widget.onPaymentComplete?.call();
      _showSuccessReceiptDialog(refId: refId, amount: payableAmount);
    }
  }

  Future<void> _checkDoorstepStatusOnce(
    String refId, {
    bool immediate = false,
    bool suppressDialogOnFailure = false,
  }) async {
    if (!mounted) return;
    if (_isCheckingStatusOnce) {
      if (immediate) _doorstepRecheckQueued = true;
      return;
    }
    _isCheckingStatusOnce = true;
    var shouldTriggerQueuedRecheck = false;

    final payableAmount = _pendingPayableAmount > 0 ? _pendingPayableAmount : _inAppPayableAmount;
    try {
      final pollRes = await ApiService().checkCheckoutStatus(refId, live: true);
      if (!mounted || _pendingCheckoutRefId != refId) return;

      final status = (pollRes['status'] ?? '').toString().trim().toUpperCase();
      final isPaid = pollRes['paid'] == true ||
          pollRes['is_cleared'] == true ||
          pollRes['already_paid'] == true ||
          status == 'COMPLETED' ||
          status == 'CLEARED' ||
          status == 'PAID' ||
          status == 'SETTLED';

      // 1. Authoritative Success Confirmation (Immediate — don't wait!)
      if (isPaid) {
        await _handleDoorstepPaymentCleared(refId, payableAmount);
        return;
      }

      // 2. Automatic Refund Detected -> clean session & show refund dialog
      if (pollRes['is_refunded'] == true || status == 'REFUNDED') {
        _pollingTimer?.cancel();
        await DoorstepSessionManager.clearSession(
          _visitId,
          customerId: _customerScopeId,
        );
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _isAwaitingPaymentConfirmation = false;
          _isPaymentFailed = false;
          _failureReason = null;
          _failoverInfo = null;
          _pendingCheckoutRefId = null;
          _pendingPayableAmount = 0.0;
        });
        final amt = _toDouble(pollRes['amount'], payableAmount);
        _showRefundNotificationDialog(
          refId: refId,
          amount: amt,
          refundId: pollRes['refund_id'] as String?,
        );
        return;
      }

      // 3. Stale/missing temporary ref restored from storage -> clear silently
      if (status == 'NOT_FOUND') {
        _pollingTimer?.cancel();
        setState(() {
          _isProcessing = false;
          _isAwaitingPaymentConfirmation = false;
          _isPaymentFailed = false;
          _failureReason = null;
          _failoverInfo = null;
          _isLastStatusExpired = false;
          _pendingCheckoutRefId = null;
          _pendingPayableAmount = 0.0;
        });
        _persistSession(clearPendingCheckout: true);
        return;
      }

      // 4. Explicit Failure / Cancellation / Expiry from Gateway or Bank
      final isExpired = pollRes['is_expired'] == true || status == 'EXPIRED';
      final pollFailover = _extractFailover(pollRes);
      if (pollRes['is_failed'] == true ||
          isExpired ||
          status == 'FAILED' ||
          status == 'CANCELLED' ||
          status == 'DECLINED') {
        _pollingTimer?.cancel();
        if (suppressDialogOnFailure) {
          setState(() {
            _isProcessing = false;
            _isAwaitingPaymentConfirmation = false;
            _isPaymentFailed = false;
            _failureReason = null;
          });
          return;
        }
        final reasonText = (pollRes['failure_reason']?.toString().trim().isNotEmpty == true)
            ? pollRes['failure_reason'].toString().trim()
            : (isExpired
                ? 'Payment session expired — Kit NOT installed, no order created.'
                : 'Payment Failed — Kit NOT installed, no order created');
        setState(() {
          _isProcessing = false;
          _isAwaitingPaymentConfirmation = false;
          _isPaymentFailed = true;
          _failureReason = reasonText;
          if (pollFailover != null) {
            _failoverInfo = pollFailover;
          }
          _isLastStatusExpired = isExpired;
          if (isExpired) {
            _pendingCheckoutRefId = null;
            _pendingPayableAmount = 0.0;
          }
          _inPageError = null;
        });
        if (isExpired) {
          _persistSession(clearPendingCheckout: true);
        }
        _showPaymentFailureDialog(
          refId: refId,
          reason: reasonText,
          isExpired: isExpired,
        );
        return;
      }

      if (pollFailover != null && mounted) {
        _failoverInfo = pollFailover;
      }

      // 5. Auto-check window (60s = 24 x 2.5s) -> transition cleanly from PROCESSING to FAILED
      if (_isAppInForeground && !immediate) {
        _clearancePollAttempts++;
      }

      if (_clearancePollAttempts >= 24) {
        _pollingTimer?.cancel();
        const timeoutReason =
            'Payment Failed — Kit NOT installed, no order created. Tap Retry Payment to complete or auto-confirm if debited.';
        setState(() {
          _isProcessing = false;
          _isAwaitingPaymentConfirmation = false;
          _isPaymentFailed = true;
          _failureReason = timeoutReason;
          if (pollFailover != null) {
            _failoverInfo = pollFailover;
          }
        });
        if (!suppressDialogOnFailure) {
          _showPaymentFailureDialog(
            refId: refId,
            reason: timeoutReason,
            isExpired: false,
          );
        }
      }
    } catch (err) {
      debugPrint('[ClearanceWatcher] Polling error: $err');
    } finally {
      _isCheckingStatusOnce = false;
      if (_doorstepRecheckQueued && mounted && _pendingCheckoutRefId == refId) {
        _doorstepRecheckQueued = false;
        shouldTriggerQueuedRecheck = true;
      }
    }
    if (shouldTriggerQueuedRecheck) {
      await _checkDoorstepStatusOnce(
        refId,
        immediate: true,
        suppressDialogOnFailure: suppressDialogOnFailure,
      );
    }
  }

  Future<void> _launchNativeOrFallbackDoorstepCheckout({
    required String refId,
    required double payable,
    String? gatewayOrderId,
    String? primaryGateway,
    String? razorpayKeyId,
    String? rzpOrderId,
    required String fallbackCheckoutUrl,
    String? upiUri,
  }) async {
    _pendingGatewayOrderId =
        (gatewayOrderId != null && gatewayOrderId.isNotEmpty)
            ? gatewayOrderId
            : refId;
    if (razorpayKeyId != null && razorpayKeyId.trim().isNotEmpty) {
      _pendingRazorpayKeyId = razorpayKeyId.trim();
    }
    if (rzpOrderId != null && rzpOrderId.trim().isNotEmpty) {
      _pendingRzpOrderId = rzpOrderId.trim();
    }

    final effectiveRzpOrderId = (_pendingRzpOrderId != null && _pendingRzpOrderId!.isNotEmpty)
        ? _pendingRzpOrderId
        : ((_pendingGatewayOrderId ?? '').startsWith('order_') ? _pendingGatewayOrderId : null);
    final effectiveKeyId = _pendingRazorpayKeyId;
    final gwLower = (primaryGateway ?? '').trim().toLowerCase();

    // 1. Native Razorpay Custom UI Checkout Sheet (Primary Live Gateway)
    if (!kIsWeb &&
        (Platform.isAndroid || Platform.isIOS) &&
        effectiveRzpOrderId != null &&
        effectiveRzpOrderId.isNotEmpty &&
        effectiveKeyId != null &&
        effectiveKeyId.isNotEmpty &&
        (gwLower.isEmpty || gwLower == 'razorpay')) {
      await RazorpayCheckoutSheet.show(
        context,
        orderId: refId,
        rzpOrderId: effectiveRzpOrderId,
        razorpayKeyId: effectiveKeyId,
        amount: payable,
        customerPhone: widget.cartState.userPhone,
        customerEmail: widget.cartState.userEmail,
        customerName: widget.cartState.userName,
        fallbackCheckoutUrl: fallbackCheckoutUrl,
        upiUri: upiUri,
        initialMethod: _selectedUpiApp,
        onPaymentCleared: () async {
          await _handleDoorstepPaymentCleared(refId, payable);
        },
        onPaymentFailed: (reason) {
          if (mounted) {
            setState(() {
              _isPaymentFailed = true;
              _failureReason = reason;
            });
          }
        },
      );
      return;
    }

    // Fallback Browser / Chrome Custom Tab if native SDK params absent
    _startBackgroundPaymentClearanceWatcher(refId, payable);
    await _launchDoorstepBrowserUrl(fallbackCheckoutUrl);
  }

  /// Background auto-checking watcher every 2.5s for instant gateway confirmation
  void _startBackgroundPaymentClearanceWatcher(String refId, double payableAmount) {
    _pollingTimer?.cancel();
    _clearancePollAttempts = 0;
    _pendingCheckoutRefId = refId;
    _pendingPayableAmount = payableAmount;
    if (mounted) {
      setState(() {
        _isAwaitingPaymentConfirmation = true;
        _isPaymentFailed = false;
        _failureReason = null;
        _inPageError = null;
      });
    }

    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      await _checkDoorstepStatusOnce(refId);
    });
  }


  void _showSuccessReceiptDialog({required String refId, required double amount}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFFF0FDF4), shape: BoxShape.circle),
              child: const Icon(Icons.verified_rounded, color: Color(0xFF16A34A), size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              'Payment Confirmed!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'Order Ref: $refId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: refId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Order Reference copied to clipboard'), duration: Duration(seconds: 2)),
                      );
                    },
                    child: const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '₹${amount.toStringAsFixed(2)} Paid Successfully',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF16A34A)),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Builder(
                builder: (_) {
                  final specs = _items
                      .map((i) => CbmSpecHelper.resolveItemSpec(i.toJson()))
                      .toList();
                  final labels = specs
                      .map((s) => s.shortBadge ?? s.primaryRatingLabel)
                      .whereType<String>()
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toSet()
                      .toList();
                  final hasHardware = specs.any((s) => s.partNature == 'NON_CONSUMABLE');
                  final hasConsumable = specs.any((s) => s.partNature == 'CONSUMABLE');
                  final summaryTitle = labels.isNotEmpty
                      ? (labels.length == 1
                          ? '${labels.first} Active'
                          : 'Verified CBM Spec: ${labels.join(' • ')}')
                      : 'Genuine Factory Spare Verified';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            hasHardware && !hasConsumable
                                ? Icons.verified_user_rounded
                                : Icons.water_drop_rounded,
                            color: const Color(0xFF0284C7),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              summaryTitle,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '100% genuine factory spare certified and registered to this service visit.',
                        style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                      ),
                    ],
                  );
                },
              ),
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
                onPressed: () {
                  // Pop dialog, doorstep verification, and scanner directly back to Service In Progress
                  Navigator.of(context).popUntil((route) =>
                    route.settings.name == 'service_in_progress' || route.isFirst
                  );
                },
                child: const Text('Done & Return to Service', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaymentFailureDialog({
    required String refId,
    String? reason,
    bool isExpired = false,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFFFEF2F2), shape: BoxShape.circle),
              child: const Icon(Icons.info_outline_rounded, color: Color(0xFFEF4444), size: 48),
            ),
            const SizedBox(height: 16),
            Text(
              isExpired
                  ? 'Payment Expired — Kit NOT installed'
                  : 'Payment Failed — Kit NOT installed, no order created',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'Order Ref: $refId',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: refId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Order Reference copied to clipboard'), duration: Duration(seconds: 2)),
                      );
                    },
                    child: const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              reason?.isNotEmpty == true
                  ? reason!
                  : (isExpired
                      ? 'This payment session expired before confirmation. Technician will install the kit only after confirmed payment.'
                      : 'No payment confirmation was received. No order was created and technician will NOT install the kit yet.\n\nTap Retry Payment on this temporary session.'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.4),
            ),
            if (_failoverInfo?['rail_hint'] == 'TRY_CARD_OR_NETBANKING') ...[
              const SizedBox(height: 8),
              const Text(
                'Tip: Try Debit/Credit Card, NetBanking, or another UPI app.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF0369A1)),
              ),
            ],
            const SizedBox(height: 20),
            Builder(
              builder: (_) {
                final nextLabel = _failoverInfo?['next_gateway_label']?.toString();
                final shouldSwitch = !isExpired &&
                    _failoverInfo?['should_try_another_option'] == true &&
                    nextLabel != null &&
                    nextLabel.isNotEmpty;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF475569))),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              if (isExpired) {
                                _pendingCheckoutRefId = null;
                                _isLastStatusExpired = false;
                                _processPayment(forceFreshSession: true);
                              } else {
                                _retryDoorstepPayment(switchGateway: shouldSwitch);
                              }
                            },
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                shouldSwitch ? 'Try via $nextLabel' : 'Retry Payment',
                                maxLines: 1,
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!isExpired &&
                        !shouldSwitch &&
                        nextLabel != null &&
                        nextLabel.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _retryDoorstepPayment(switchGateway: true);
                        },
                        icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Try another option ($nextLabel)',
                            maxLines: 1,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRefundNotificationDialog({required String refId, required double amount, String? refundId}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFFEFF6FF), shape: BoxShape.circle),
              child: const Icon(Icons.published_with_changes_rounded, color: Color(0xFF0284C7), size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              'Refund Processed Automatically',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Order Ref: $refId',
                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '₹${amount.toStringAsFixed(2)} has been safely reversed to your original payment method (UPI / Bank).\n\nFunds typically reflect within a few hours depending on your bank.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('Back to Home', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A)),
          onPressed: () {
            HapticFeedback.lightImpact();
            Navigator.pop(context);
          },
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                'Verify Genuine Spares',
                maxLines: 1,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              ),
            ),
            Text(
              'Step 1 of 2 • Check seals before payment',
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_shopping_cart_rounded, color: Color(0xFF0284C7)),
            tooltip: 'Scan more spares',
            onPressed: () {
              final nav = Navigator.of(context);
              nav.pop();
              widget.onScanMore();
            },
          ),
        ],
      ),
      body: _items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 54, color: Color(0xFF94A3B8)),
                  const SizedBox(height: 12),
                  const Text('No spares scanned yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
                  const SizedBox(height: 6),
                  const Text('Scan genuine box QR in technician custody', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                    label: const Text('Open Box Scanner'),
                    onPressed: () {
                      final nav = Navigator.of(context);
                      nav.pop();
                      widget.onScanMore();
                    },
                  ),
                ],
              ),
            )
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // 0. In-Page Localized Error Banner (Pillar 1: Discarded automatically when leaving page)
                if (_inPageError != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFCA5A5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _inPageError!,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF991B1B)),
                          ),
                        ),
                        InkWell(
                          onTap: () => setState(() => _inPageError = null),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close_rounded, size: 16, color: Color(0xFF991B1B)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (_isPaymentFailed && _failureReason != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFFCA5A5),
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                              color: Color(0xFFDC2626),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Payment Failed — Kit NOT installed, no order created',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF991B1B),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _failureReason!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.35,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                        if (_isPaymentFailed) ...[
                          const SizedBox(height: 10),
                          Builder(
                            builder: (_) {
                              final nextLabel =
                                  _failoverInfo?['next_gateway_label']?.toString();
                              final shouldSwitch = !_isLastStatusExpired &&
                                  _failoverInfo?['should_try_another_option'] == true &&
                                  nextLabel != null &&
                                  nextLabel.isNotEmpty;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF0284C7),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10, horizontal: 12),
                                        shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(10)),
                                      ),
                                      onPressed: _isProcessing
                                          ? null
                                          : () => _retryDoorstepPayment(
                                              switchGateway: shouldSwitch),
                                      icon: Icon(
                                        shouldSwitch
                                            ? Icons.swap_horiz_rounded
                                            : Icons.refresh_rounded,
                                        size: 16,
                                      ),
                                      label: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          shouldSwitch
                                              ? 'Try Another Option — Pay via $nextLabel'
                                              : 'Retry Payment',
                                          maxLines: 1,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (!_isLastStatusExpired &&
                                      !shouldSwitch &&
                                      nextLabel != null &&
                                      nextLabel.isNotEmpty)
                                    TextButton.icon(
                                      onPressed: _isProcessing
                                          ? null
                                          : () => _retryDoorstepPayment(
                                              switchGateway: true),
                                      icon: const Icon(Icons.swap_horiz_rounded,
                                          size: 15),
                                      label: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          'Try another option ($nextLabel)',
                                          maxLines: 1,
                                          style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ],

                // 1. Mandatory 1-Line Physical Verification Notice (Vicky Law 6)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.verified_rounded, color: Color(0xFF16A34A), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _items.any((i) => i.isKit)
                                ? '100% Genuine Sealed Kit • Inner seal scans are optional'
                                : '100% Genuine Spare Verified • Ready for Doorstep Payment',
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 2. Scanned Items List with Nested Component Inspection
                ..._items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  return _buildProductCard(item, index);
                }),

                const SizedBox(height: 12),

                // Scan More Spares Outlined Action
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0284C7),
                    side: const BorderSide(color: Color(0xFFBAE6FD), width: 1.5),
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Scan Another Spare / Kit Box', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  onPressed: () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    widget.onScanMore();
                  },
                ),

                const SizedBox(height: 20),

                // 3. Coupon Engine Section (WELCOME80 + Hidden Promo Code)
                _buildCouponEngineSection(),

                const SizedBox(height: 20),

                // 4. Financial Bill Breakdown (CBM Formula)
                _buildBillBreakdownCard(),
              ],
            ),
      bottomNavigationBar: _items.isNotEmpty ? _buildStickyProceedBottomBar() : null,
      ),
    );
  }

  /// Builds Apple-style glassy card with nested components for kits
  Widget _buildProductCard(ScannedRoItem item, int index) {
    final verifiedSet = _verifiedChildSerials[item.code] ?? {};
    final rawComponents = item.rawComponents;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Header Row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Product / Kit Icon Thumb
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: item.isKit
                        ? const LinearGradient(
                            colors: [Color(0xFF1D4ED8), Color(0xFF0284C7)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : const LinearGradient(
                            colors: [Color(0xFFE0F2FE), Color(0xFFBAE6FD)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: item.isKit
                          ? const Color(0xFF93C5FD).withValues(alpha: 0.6)
                          : const Color(0xFF7DD3FC),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset(
                      item.imageAsset,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            item.isKit
                                ? Icons.inventory_2_rounded
                                : Icons.water_drop_rounded,
                            size: 18,
                            color: item.isKit
                                ? Colors.white
                                : const Color(0xFF0369A1),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'RO PREMIUM',
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 5.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.2,
                              color: item.isKit
                                  ? Colors.white
                                  : const Color(0xFF0369A1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Title + Subtitle (Vicky Law 1: Containment Law)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          item.name,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: item.isKit ? const Color(0xFFEFF6FF) : const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.isKit ? 'SERVICE KIT' : 'SPARE PART',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                color: item.isKit ? const Color(0xFF0284C7) : const Color(0xFFD97706),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'QR: ${item.code}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Delete Item
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFF94A3B8), size: 20),
                  onPressed: () => _removeItem(index),
                ),
              ],
            ),
          ),

          // Pricing Summary Pill (Strict SSoT: Pure Factory MRP, Discounts & Kit Free Spares in Bill Summary)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Builder(
              builder: (_) {
                final bool isComplimentaryItem = _freeAllocation.isItemComplimentary(index);
                return Row(
                  children: [
                    Expanded(
                      child: isComplimentaryItem
                          ? Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 6,
                              children: [
                                Text(
                                  '₹${DoorstepPricing.formatRupees(item.mrp)}',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF94A3B8),
                                    decoration: TextDecoration.lineThrough,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'FREE WITH KIT • ₹0',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFF15803D),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              'MRP ₹${DoorstepPricing.formatRupees(item.mrp)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                            ),
                    ),
                    ...() {
                      final spec = CbmSpecHelper.resolveItemSpec(item.toJson());
                      final label = spec.shortBadge ??
                          (item.warranty.trim().isNotEmpty ? item.warranty.trim() : null);
                      if (label == null) return const <Widget>[];
                      return <Widget>[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: spec.hasSpec
                                  ? spec.pillBackground
                                  : (item.isKit ? const Color(0xFFEFF6FF) : const Color(0xFFF0FDF4)),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: spec.hasSpec
                                    ? spec.pillForeground
                                    : (item.isKit ? const Color(0xFF0284C7) : const Color(0xFF16A34A)),
                              ),
                            ),
                          ),
                        ),
                      ];
                    }(),
                  ],
                );
              },
            ),
          ),

          // If Kit: Render Nested Components Breakdown
          if (item.isKit && (rawComponents.isNotEmpty || item.bundledItems.isNotEmpty || item.freeSpares.isNotEmpty)) ...[
            const Divider(height: 20, color: Color(0xFFF1F5F9)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'INSPECT FACTORY SEALS ON EACH CARTRIDGE:',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),

                  if (rawComponents.where((comp) => comp['is_complimentary'] != true).isNotEmpty) ...[
                    ...rawComponents.where((comp) => comp['is_complimentary'] != true).map((comp) {
                      final serial = (comp['qr'] ?? comp['serial'] ?? comp['component_qr'] ?? '').toString().trim();
                      final isVerified = verifiedSet.contains(serial);
                      final compName = comp['name'] ?? comp['product_name'] ?? 'Filter Cartridge';
                      final compMrp = _toDouble(comp['unit_mrp'], 500.0);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: isVerified ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isVerified ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isVerified ? Icons.check_circle_rounded : Icons.verified_user_outlined,
                              color: isVerified ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                              size: 16,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      compName,
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: isVerified ? const Color(0xFF15803D) : const Color(0xFF1E293B),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    'Serial: $serial • MRP ₹${DoorstepPricing.formatRupees(compMrp)}',
                                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                            if (isVerified)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'VERIFIED',
                                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF0284C7),
                        side: const BorderSide(color: Color(0xFFBAE6FD), width: 1.2),
                        backgroundColor: const Color(0xFFF0F9FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        minimumSize: const Size(double.infinity, 38),
                      ),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                      label: const Text(
                        'Scan to Verify (Optional)',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                      ),
                      onPressed: () => _openSealScannerSheet(item),
                    ),
                  ] else ...[
                    ...item.bundledItems.map((b) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.check_rounded, size: 14, color: Color(0xFF16A34A)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(b, style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                              ),
                            ],
                          ),
                        )),
                  ],
                  if (item.freeSpares.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFA7F3D0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '🎁 SEALED FREE SPARES INSIDE POUCH (₹0 FREE)',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF047857), letterSpacing: 0.4),
                          ),
                          const SizedBox(height: 6),
                          ...item.freeSpares.map((sp) {
                            final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
                            final uMrp = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
                            final worth = (q > 0 ? q : 1) * uMrp;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Row(
                                children: [
                                  const Icon(Icons.card_giftcard_rounded, size: 14, color: Color(0xFF059669)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      ProductUnitHelper.formatBomOrFreeName(Map<String, dynamic>.from(sp)),
                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF065F46)),
                                    ),
                                  ),
                                  Text(
                                    worth > 0 ? 'Worth ₹${DoorstepPricing.formatRupees(worth)} FREE' : 'FREE',
                                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  /// Builds dynamic server-backed Coupon Section with Floating Shoulder Badges
  Widget _buildCouponEngineSection() {
    final bool hasHiddenCouponApplied = _appliedCouponCode != null &&
        !_availableCoupons.any(
          (c) =>
              (c['code'] ?? '').toString().trim().toUpperCase() ==
              _appliedCouponCode!.trim().toUpperCase(),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'OFFERS & PROMOTIONS',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.6),
        ),
        const SizedBox(height: 14),

        if (_isCouponsLoading && _availableCoupons.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Loading live technician offers...',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          )
        else ...[
          for (final c in _availableCoupons) ...[
            _buildPublicCouponCard(c),
            const SizedBox(height: 14),
          ],
        ],

        if (hasHiddenCouponApplied) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF16A34A), width: 1.5),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_rounded, color: Color(0xFF16A34A), size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Promo Applied: ${_appliedCouponCode!}',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                      ),
                      Text(
                        'Instant discount of ₹${DoorstepPricing.formatRupees(_effectiveDiscount)} active',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF15803D), fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _removeCoupon,
                  child: const Text('REMOVE', style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 11)),
                ),
              ],
            ),
          ),
        ],

        // Hidden / Custom Promo Code Input
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              const Icon(Icons.confirmation_number_outlined, color: Color(0xFF94A3B8), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _hiddenCouponCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    hintText: 'Enter promo or partner code',
                    hintStyle: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                  onSubmitted: (val) {
                    final code = val.trim();
                    if (code.isNotEmpty) {
                      _applyCouponInternal(code, notifyUser: true);
                      _hiddenCouponCtrl.clear();
                    }
                  },
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF0284C7),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  final code = _hiddenCouponCtrl.text.trim();
                  if (code.isNotEmpty) {
                    _applyCouponInternal(code, notifyUser: true);
                    _hiddenCouponCtrl.clear();
                  }
                },
                child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPublicCouponCard(Map<String, dynamic> c) {
    final code = (c['code'] ?? '').toString().trim().toUpperCase();
    final desc = (c['description'] ?? '').toString().trim();
    final discType = (c['discount_type'] ?? 'PERCENTAGE').toString().trim().toUpperCase();
    final discVal = _toDouble(c['discount_value']);
    final minOrder = _toDouble(c['min_order_value']);
    final isExhausted = c['is_exhausted'] == true;
    final bool isApplied = _appliedCouponCode != null &&
        _appliedCouponCode!.trim().toUpperCase() == code;
    final bool belowMin = !isExhausted && minOrder > 0 && _totalMrp < minOrder;
    final bool isDisabled = isExhausted || belowMin;

    final String badgeLabel = isExhausted
        ? 'OFFER EXHAUSTED'
        : (discType == 'PERCENTAGE'
            ? 'FLAT ${discVal.toStringAsFixed(discVal.truncateToDouble() == discVal ? 0 : 1)}% OFF'
            : 'FLAT ₹${discVal.toStringAsFixed(0)} OFF');

    final String subtitleText = isExhausted
        ? 'Offer limit reached • Already redeemed on your account'
        : (belowMin
            ? 'Minimum order ₹${minOrder.toInt()} required'
            : (desc.isNotEmpty ? desc : 'Exclusive doorstep technician discount'));

    return Opacity(
      opacity: isDisabled ? 0.78 : 1.0,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isApplied ? const Color(0xFFF0FDF4) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isApplied ? const Color(0xFF16A34A) : const Color(0xFFE2E8F0),
                width: isApplied ? 1.5 : 1,
              ),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 3)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isApplied
                        ? const Color(0xFFDCFCE7)
                        : (isDisabled ? const Color(0xFFF1F5F9) : const Color(0xFFEFF6FF)),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.local_offer_rounded,
                    color: isApplied
                        ? const Color(0xFF16A34A)
                        : (isDisabled ? const Color(0xFF64748B) : const Color(0xFF0284C7)),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: 0.4),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitleText,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isExhausted ? const Color(0xFFB91C1C) : const Color(0xFF475569),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                BouncingWidget(
                  onTap: isDisabled
                      ? () {
                          HapticFeedback.lightImpact();
                          setState(() {
                            _inPageError = isExhausted
                                ? '$code offer exhausted: Already redeemed on your account.'
                                : 'Add ₹${DoorstepPricing.formatRupees(math.max(0.0, minOrder - _totalMrp))} more to apply $code.';
                          });
                        }
                      : () {
                          if (isApplied) {
                            _removeCoupon();
                          } else {
                            _applyCouponInternal(code, notifyUser: true);
                          }
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: isDisabled
                          ? const Color(0xFFE2E8F0)
                          : (isApplied ? const Color(0xFF16A34A) : const Color(0xFF0284C7)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isExhausted
                          ? 'EXHAUSTED'
                          : (belowMin
                              ? 'MIN ₹${minOrder.toInt()}'
                              : (isApplied ? 'APPLIED ✓' : 'APPLY')),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: isDisabled ? const Color(0xFF475569) : Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Floating Shoulder Badge
          Positioned(
            top: -10,
            right: 14,
            child: isExhausted
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF64748B),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.block_rounded, color: Colors.white, size: 10),
                        const SizedBox(width: 3),
                        Text(
                          badgeLabel,
                          style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                        ),
                      ],
                    ),
                  )
                : ScaleTransition(
                    scale: _breathingScale,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(color: const Color(0xFFDC2626).withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.bolt_rounded, color: Colors.white, size: 11),
                          const SizedBox(width: 2),
                          Text(
                            badgeLabel,
                            style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Bill Breakdown according to CBM Sovereign Ledger
  Widget _buildBillBreakdownCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Price Breakdown',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.4),
          ),
          const SizedBox(height: 12),

          _buildBreakdownRow('Spares Total MRP', '₹${_totalMrp.toStringAsFixed(2)}'),

          if (_freeSparesSavings > 0) ...[
            const SizedBox(height: 6),
            _buildBreakdownRow(
              'Free Kit Spares Allowance',
              'FREE (-₹${_freeSparesSavings.toStringAsFixed(2)})',
              isDiscount: true,
            ),
          ] else if (_sealedFreeSparesValue > 0) ...[
            const SizedBox(height: 6),
            _buildBreakdownRow(
              'Sealed Free Kit Spares (Worth ₹${_sealedFreeSparesValue.toStringAsFixed(2)})',
              '₹0 FREE',
              isDiscount: true,
            ),
          ],

          if (_effectiveDiscount > 0) ...[
            const SizedBox(height: 6),
            _buildBreakdownRow('Discount ($_appliedCouponCode)', '-₹${_effectiveDiscount.toStringAsFixed(2)}', isDiscount: true),
          ],

          const Divider(height: 20, color: Color(0xFFE2E8F0)),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Payable',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                    ),
                    Text('Includes GST • Official Tax Invoice', style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '₹${_inAppPayableAmount.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: -0.5),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          if (_pricing.isBelowGatewayMinimum) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xFFD97706)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      DoorstepPricing.belowGatewayMinimumMessage(_inAppPayableAmount),
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),
          ],

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Technician service visit labor fee (₹${widget.serviceState?.fee ?? 49}) is paid directly to technician in cash/UPI.',
                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreakdownRow(String label, String value, {bool isDiscount = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569))),
        ),
        const SizedBox(width: 10),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: isDiscount ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }


  /// Sticky Bottom Action Bar with Tactile Button (Pillar 10)
  Widget _buildStickyProceedBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -4)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 13, color: Color(0xFF0284C7)),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Order stays temporary until confirmed. Technician installs kit only after payment confirmation.',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF475569),
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('NET PAYABLE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '₹${_inAppPayableAmount.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: -0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: BouncingWidget(
                      onTap: _isProcessing ? null : _processPayment,
                      child: Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: _isProcessing ? const Color(0xFF94A3B8) : const Color(0xFF0284C7),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.center,
                        child: _isProcessing
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  ),
                                  SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      'Connecting...',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.lock_outline_rounded, color: Colors.white, size: 17),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      _isPaymentFailed
                                          ? ((_failoverInfo?['should_try_another_option'] == true &&
                                                  _failoverInfo?['next_gateway_label'] != null)
                                              ? 'Try Another Option (${_failoverInfo!['next_gateway_label']}) ₹${DoorstepPricing.formatRupees(_inAppPayableAmount)}'
                                              : 'Retry Payment ₹${DoorstepPricing.formatRupees(_inAppPayableAmount)}')
                                          : (_pricing.isZeroComplimentary
                                              ? 'Confirm Free Kit Spares (₹0)'
                                              : 'Proceed to Pay ₹${DoorstepPricing.formatRupees(_inAppPayableAmount)}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Self-owning seal QR scanner bottom sheet so [MobileScannerController] is disposed
/// only after Flutter finishes the closing transition and unmounts [MobileScanner].
class _SealScannerSheet extends StatefulWidget {
  final ScannedRoItem parentKit;
  final Map<String, dynamic>? specificComp;
  final void Function(String matchedSerial, String matchedName) onVerified;

  const _SealScannerSheet({
    required this.parentKit,
    this.specificComp,
    required this.onVerified,
  });

  @override
  State<_SealScannerSheet> createState() => _SealScannerSheetState();
}

class _SealScannerSheetState extends State<_SealScannerSheet> {
  final MobileScannerController _scannerCtrl = UniversalScannerHelper.createController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 800,
  );
  bool _handledMatch = false;

  @override
  void dispose() {
    _scannerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expectedQr = widget.specificComp != null
        ? (widget.specificComp!['qr'] ??
                widget.specificComp!['serial'] ??
                widget.specificComp!['component_qr'] ??
                '')
            .toString()
            .trim()
        : null;

    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.of(context).viewPadding.bottom,
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Scan Seal QR / Barcode (Optional)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      expectedQr != null
                          ? 'Expecting: ${widget.specificComp?['name'] ?? expectedQr}'
                          : 'Scan any cartridge seal QR or barcode in this kit',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                onPressed: () {
                  _handledMatch = true;
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  MobileScanner(
                    controller: _scannerCtrl,
                    onDetect: (capture) {
                      if (_handledMatch) return;
                      for (final barcode in capture.barcodes) {
                        final raw = UniversalScannerHelper.normalizeCode(
                          barcode.rawValue,
                          uppercase: false,
                        );
                        if (raw.isEmpty) continue;
                        final rawUpper = raw.toUpperCase();
                        String? matchedSerial;
                        String? matchedName;

                        if (expectedQr != null) {
                          final expUpper = expectedQr.toUpperCase();
                          if (rawUpper == expUpper ||
                              rawUpper.contains(expUpper) ||
                              expUpper.contains(rawUpper)) {
                            matchedSerial = expectedQr;
                            matchedName =
                                (widget.specificComp?['name'] ?? expectedQr)
                                    .toString();
                          }
                        } else {
                          for (final c in widget.parentKit.rawComponents) {
                            final cQr = (c['qr'] ??
                                    c['serial'] ??
                                    c['component_qr'] ??
                                    '')
                                .toString()
                                .trim();
                            final cUpper = cQr.toUpperCase();
                            if (cQr.isNotEmpty &&
                                (rawUpper == cUpper ||
                                    rawUpper.contains(cUpper) ||
                                    cUpper.contains(rawUpper))) {
                              matchedSerial = cQr;
                              matchedName =
                                  (c['name'] ?? c['product_name'] ?? cQr)
                                      .toString();
                              break;
                            }
                          }
                        }

                        if (matchedSerial != null) {
                          _handledMatch = true;
                          HapticFeedback.mediumImpact();
                          ScanConfirmationOverlay.show(context, isSuccess: true);
                          Navigator.pop(context);
                          widget.onVerified(
                            matchedSerial,
                            matchedName ?? matchedSerial,
                          );
                          return;
                        }
                      }
                    },
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: ScannerZoomPill(controller: _scannerCtrl, compact: true),
                  ),
                  Container(
                    width: 260,
                    height: 165,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF38BDF8),
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  Positioned(
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Point at QR or Barcode on filter seal sticker',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
