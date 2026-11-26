import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../utils/phone_normalizer.dart';
import '../models/user_address.dart';
import '../state/cart_state.dart';
import '../theme/app_theme.dart';
import 'bouncing_widget.dart';
import 'razorpay_checkout_sheet.dart';
import 'orders_sheet.dart';
import 'online_address_sheet.dart';
import 'auth_sheet.dart';
import 'catalog_network_image.dart';
import 'email_prompt_dialog.dart';
import 'web_app_download_sheet.dart';

enum _StorePaymentPhase { processing, failed, cleared }

class _StorePaymentModalState {
  final _StorePaymentPhase phase;
  final String orderId;
  final num amount;
  final String? gateway;
  final String? reason;
  final bool isExpired;
  final Map<String, dynamic>? failover;

  const _StorePaymentModalState({
    required this.phase,
    required this.orderId,
    required this.amount,
    this.gateway,
    this.reason,
    this.isExpired = false,
    this.failover,
  });

  _StorePaymentModalState copyWith({
    _StorePaymentPhase? phase,
    String? gateway,
    String? reason,
    bool? isExpired,
    Map<String, dynamic>? failover,
  }) {
    return _StorePaymentModalState(
      phase: phase ?? this.phase,
      orderId: orderId,
      amount: amount,
      gateway: gateway ?? this.gateway,
      reason: reason ?? this.reason,
      isExpired: isExpired ?? this.isExpired,
      failover: failover ?? this.failover,
    );
  }
}

class CartBottomSheet extends StatefulWidget {
  final CartState cartState;
  final int initialStep;
  final String? resumeDraftId;
  final String? recoveryBannerMessage;

  const CartBottomSheet({
    super.key,
    required this.cartState,
    this.initialStep = 0,
    this.resumeDraftId,
    this.recoveryBannerMessage,
  });

  @override
  State<CartBottomSheet> createState() => _CartBottomSheetState();
}

class _CartBottomSheetState extends State<CartBottomSheet>
    with WidgetsBindingObserver {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _couponController = TextEditingController();
  bool _isPaying = false;
  int _checkoutStep = 0; // 0 = Cart & Address Review (Quick Booking style), 1 = Payment / COD Choice
  String _selectedPaymentMethod = 'ONLINE_PG';
  bool _editingContact = false;

  Timer? _paymentPollTimer;
  bool _isAppInForeground = true;
  int _foregroundPollCount = 0;
  bool _isCheckingPayment = false;
  bool _recheckQueued = false;
  bool _isWaitingModalOpen = false;
  BuildContext? _waitingModalContext;
  String? _pendingOrderId;
  String? _pendingGatewayOrderId;
  String? _lastProcessingOrderId;
  num _pendingPaidAmount = 0;
  num _pendingSavedAmount = 0;
  String? _pendingCouponName;
  ValueNotifier<_StorePaymentModalState>? _paymentStatusNotifier;

  @override
  void initState() {
    super.initState();
    _checkoutStep = widget.initialStep;
    final onlineAddr = widget.cartState.activeOnlineAddress;
    final draft = widget.cartState.activeRecoveryDraft;
    if (_nameController.text.isEmpty) {
      _nameController.text = (onlineAddr?.recipientName?.isNotEmpty == true)
          ? onlineAddr!.recipientName!
          : widget.cartState.userName;
    }
    final activeFullAddr = (onlineAddr?.fullAddress ?? '').isNotEmpty
        ? onlineAddr!.fullAddress
        : (draft?['delivery_address']?.toString() ?? '');
    if (_addressController.text.isEmpty && activeFullAddr.isNotEmpty) {
      _addressController.text = activeFullAddr;
    }
    if (widget.initialStep == 1 && _addressController.text.trim().isEmpty) {
      _checkoutStep = 0;
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.cartState.refreshAvailableCoupons();
        widget.cartState.refreshOnlineShippingQuote();
      }
    });
  }

  @override
  void dispose() {
    _paymentPollTimer?.cancel();
    _paymentStatusNotifier?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    _addressController.dispose();
    _couponController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    final activeOrderId = _pendingOrderId ?? _lastProcessingOrderId;
    if (state == AppLifecycleState.resumed && activeOrderId != null) {
      final current = _paymentStatusNotifier?.value;
      if (_isWaitingModalOpen &&
          current != null &&
          current.phase != _StorePaymentPhase.cleared) {
        _foregroundPollCount = 0;
        _paymentStatusNotifier?.value = current.copyWith(
          phase: _StorePaymentPhase.processing,
          reason: null,
        );
        _startForegroundPaymentPolling();
        _pollPendingOrderStatus(immediate: true);
      } else if (!_isWaitingModalOpen) {
        _reconcileBackgroundOrderOnResume(activeOrderId);
      }
    }
  }

  Future<void> _reconcileBackgroundOrderOnResume(String orderId) async {
    if (_isCheckingPayment || !mounted) return;
    _isCheckingPayment = true;
    try {
      final res = await ApiService().checkCheckoutStatus(orderId, live: true);
      if (!mounted) return;
      final status = (res['status'] ?? '').toString().trim().toUpperCase();
      final isCleared = res['paid'] == true ||
          res['is_cleared'] == true ||
          res['already_paid'] == true ||
          status == 'CLEARED' ||
          status == 'PAID' ||
          status == 'COMPLETED' ||
          status == 'SETTLED';
      if (isCleared) {
        _paymentPollTimer?.cancel();
        final paidAmount = _pendingPaidAmount > 0
            ? _pendingPaidAmount
            : widget.cartState.finalPayableAmount;
        final savedAmount = _pendingSavedAmount > 0
            ? _pendingSavedAmount
            : widget.cartState.combinedTotalSavings;
        final couponName =
            _pendingCouponName ?? widget.cartState.appliedCoupon?.code;
        final gateway = res['gateway']?.toString();
        setState(() {
          _pendingOrderId = null;
          _lastProcessingOrderId = null;
        });
        widget.cartState.clearCart();
        _showOrderConfirmationSheet(
          invoiceNum: orderId,
          paidAmount: paidAmount,
          savedAmount: savedAmount,
          couponName: couponName,
          paymentMethod: (gateway != null && gateway.isNotEmpty)
              ? gateway.toUpperCase()
              : 'ONLINE_PG',
        );
      }
    } catch (e) {
      debugPrint('[Cart Payment] Background resume check error: $e');
    } finally {
      _isCheckingPayment = false;
    }
  }

  Future<void> _applyCouponText() async {
    if (widget.cartState.isValidatingCoupon) return;
    final code = _couponController.text.trim();
    if (code.isEmpty) return;
    final success = await widget.cartState.applyCoupon(code);
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.cartState.couponError ?? 'Invalid coupon code'),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      _couponController.clear();
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _openOnlineAddressPicker() async {
    final selected = await showModalBottomSheet<UserAddress>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OnlineAddressSheet(cartState: widget.cartState),
    );
    if (selected != null && mounted) {
      if (selected.recipientName != null && selected.recipientName!.isNotEmpty) {
        _nameController.text = selected.recipientName!;
      }
      _addressController.text = selected.fullAddress;
      setState(() {});
    }
  }

  Future<void> _handleConfirmCartStep() async {
    if (_isPaying || widget.cartState.items.isEmpty) return;
    if (!widget.cartState.isLoggedIn) {
      await AuthSheet.show(
        context,
        cartState: widget.cartState,
        onAuthSuccess: () {
          if (mounted) {
            if (_nameController.text.trim().isEmpty && widget.cartState.userName.isNotEmpty) {
              _nameController.text = widget.cartState.userName;
            }
            setState(() {});
          }
        },
      );
      if (!mounted || !widget.cartState.isLoggedIn) return;
    }

    var onlineAddr = widget.cartState.activeOnlineAddress;
    var address = _addressController.text.trim().isNotEmpty
        ? _addressController.text.trim()
        : (onlineAddr?.fullAddress ?? '').trim();
    var resolvedPin = (onlineAddr?.pincode ?? widget.cartState.deliveryPincode).replaceAll(RegExp(r'\D'), '');

    if (address.isEmpty || !RegExp(r'^[1-9][0-9]{5}$').hasMatch(resolvedPin)) {
      await _openOnlineAddressPicker();
      if (!mounted) return;
      onlineAddr = widget.cartState.activeOnlineAddress;
      address = _addressController.text.trim().isNotEmpty
          ? _addressController.text.trim()
          : (onlineAddr?.fullAddress ?? '').trim();
      resolvedPin = (onlineAddr?.pincode ?? widget.cartState.deliveryPincode).replaceAll(RegExp(r'\D'), '');
      if (address.isEmpty || !RegExp(r'^[1-9][0-9]{5}$').hasMatch(resolvedPin)) {
        return;
      }
    }

    if (!widget.cartState.isCodEligibleForAllItems && _selectedPaymentMethod == 'COD') {
      _selectedPaymentMethod = 'ONLINE_PG';
    }
    setState(() => _checkoutStep = 1);
  }

  Future<bool> _launchCheckoutUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        return true;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    } catch (e) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      } catch (err) {
        debugPrint('[Cart Payment] Browser checkout error: $err');
        return false;
      }
    }
  }

  void _startForegroundPaymentPolling() {
    _paymentPollTimer?.cancel();
    _paymentPollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      _pollPendingOrderStatus();
    });
  }

  Future<void> _completeStorePaymentConfirmed({
    required String orderId,
    String? gateway,
  }) async {
    _paymentPollTimer?.cancel();
    final current = _paymentStatusNotifier?.value;
    if (current != null) {
      _paymentStatusNotifier?.value = current.copyWith(
        phase: _StorePaymentPhase.cleared,
        gateway: gateway,
      );
    }
    try {
      await closeInAppWebView();
    } catch (_) {}
    _closeWaitingModal();

    final paidAmount = _pendingPaidAmount > 0
        ? _pendingPaidAmount
        : widget.cartState.finalPayableAmount;
    final savedAmount = _pendingSavedAmount > 0
        ? _pendingSavedAmount
        : widget.cartState.combinedTotalSavings;
    final couponName =
        _pendingCouponName ?? widget.cartState.appliedCoupon?.code;
    if (mounted) {
      setState(() {
        _pendingOrderId = null;
        _lastProcessingOrderId = null;
      });
    }
    widget.cartState.clearCart();
    if (mounted) {
      _showOrderConfirmationSheet(
        invoiceNum: orderId,
        paidAmount: paidAmount,
        savedAmount: savedAmount,
        couponName: couponName,
        paymentMethod: (gateway != null && gateway.isNotEmpty)
            ? gateway.toUpperCase()
            : 'ONLINE_PG',
      );
    }
  }

  void _reportFailureToRecovery(String? orderId, String reason) {
    final onlineAddr = widget.cartState.activeOnlineAddress;
    final address = _addressController.text.trim().isNotEmpty
        ? _addressController.text.trim()
        : (onlineAddr?.fullAddress ?? '');
    final pin = (onlineAddr?.pincode ?? widget.cartState.deliveryPincode)
        .replaceAll(RegExp(r'\D'), '');
    unawaited(
      widget.cartState.reportOnlinePaymentFailure(
        orderNumber: orderId,
        reason: reason,
        deliveryAddress: address,
        deliveryPincode: pin,
        deliveryCity: onlineAddr?.city ?? widget.cartState.deliveryCity,
        deliveryState: onlineAddr?.stateName,
      ),
    );
  }

  Future<void> _switchFailedPaymentToCod() async {
    _paymentPollTimer?.cancel();
    try {
      await closeInAppWebView();
    } catch (_) {}
    _closeWaitingModal();
    if (!mounted) return;
    setState(() {
      _selectedPaymentMethod = 'COD';
      _checkoutStep = 1;
    });
    await _processOnlineOrder(paymentMethod: 'COD');
  }

  Future<void> _pollPendingOrderStatus({bool immediate = false}) async {
    final orderId = _pendingOrderId;
    if (!mounted || orderId == null) return;
    if (_isCheckingPayment) {
      if (immediate) _recheckQueued = true;
      return;
    }

    _isCheckingPayment = true;
    var shouldTriggerQueuedRecheck = false;
    try {
      final res = await ApiService().checkCheckoutStatus(orderId, live: true);
      if (!mounted || _pendingOrderId != orderId) return;

      final status = (res['status'] ?? '').toString().trim().toUpperCase();
      final isCleared = res['paid'] == true ||
          res['is_cleared'] == true ||
          res['already_paid'] == true ||
          status == 'CLEARED' ||
          status == 'PAID' ||
          status == 'COMPLETED' ||
          status == 'SETTLED';
      final isRefunded = res['is_refunded'] == true || status == 'REFUNDED';
      final isExpired = res['is_expired'] == true || status == 'EXPIRED';
      final isFailed = !isRefunded &&
          (res['is_failed'] == true ||
              isExpired ||
              status == 'FAILED' ||
              status == 'CANCELLED' ||
              status == 'DECLINED');
      final gateway = res['gateway']?.toString();
      final Map<String, dynamic>? failover = res['failover'] is Map
          ? Map<String, dynamic>.from(res['failover'] as Map)
          : null;
      final current = _paymentStatusNotifier?.value;

      if (isCleared) {
        await _completeStorePaymentConfirmed(orderId: orderId, gateway: gateway);
        return;
      }

      if (isRefunded) {
        _paymentPollTimer?.cancel();
        if (mounted) {
          setState(() => _lastProcessingOrderId = null);
        }
        if (current != null) {
          const reasonMsg =
              'Payment was refunded for this order. Your cart items are still saved.';
          _paymentStatusNotifier?.value = current.copyWith(
            phase: _StorePaymentPhase.failed,
            gateway: gateway,
            isExpired: false,
            failover: failover,
            reason: reasonMsg,
          );
          _reportFailureToRecovery(orderId, reasonMsg);
        }
        return;
      }

      if (isFailed) {
        _paymentPollTimer?.cancel();
        if (mounted) {
          setState(() => _lastProcessingOrderId = isExpired ? null : orderId);
        }
        if (current != null) {
          final reasonMsg = res['failure_reason']?.toString() ??
              (isExpired
                  ? 'Payment session expired. Your cart is intact — tap Retry Payment to continue.'
                  : 'Payment was not completed. Your cart items are still saved.');
          _paymentStatusNotifier?.value = current.copyWith(
            phase: _StorePaymentPhase.failed,
            gateway: gateway,
            isExpired: isExpired,
            failover: failover,
            reason: reasonMsg,
          );
          _reportFailureToRecovery(orderId, reasonMsg);
        }
        return;
      }

      if (_isAppInForeground && !immediate) {
        _foregroundPollCount++;
      }

      if (_foregroundPollCount >= 24) {
        _paymentPollTimer?.cancel();
        if (mounted) {
          setState(() => _lastProcessingOrderId = orderId);
        }
        if (current != null) {
          const reasonMsg =
              'Payment confirmation was not received yet. Your cart items stay saved — tap Retry Payment to complete or auto-confirm if already debited.';
          _paymentStatusNotifier?.value = current.copyWith(
            phase: _StorePaymentPhase.failed,
            gateway: gateway,
            isExpired: false,
            failover: failover,
            reason: reasonMsg,
          );
          _reportFailureToRecovery(orderId, reasonMsg);
        }
      } else if (current != null &&
          ((gateway != null && gateway != current.gateway) || failover != null)) {
        _paymentStatusNotifier?.value = current.copyWith(
          gateway: gateway ?? current.gateway,
          failover: failover,
        );
      }
    } catch (e) {
      debugPrint('[Cart Payment] Status check error: $e');
    } finally {
      _isCheckingPayment = false;
      if (_recheckQueued && mounted && _pendingOrderId == orderId) {
        _recheckQueued = false;
        shouldTriggerQueuedRecheck = true;
      }
    }
    if (shouldTriggerQueuedRecheck) {
      await _pollPendingOrderStatus(immediate: true);
    }
  }

  void _closeWaitingModal() {
    if (_isWaitingModalOpen &&
        _waitingModalContext != null &&
        _waitingModalContext!.mounted) {
      Navigator.pop(_waitingModalContext!);
    }
    _isWaitingModalOpen = false;
    _waitingModalContext = null;
  }

  Future<void> _retryStorePayment(
    String orderId, {
    bool switchGateway = false,
  }) async {
    _foregroundPollCount = 0;
    final current = _paymentStatusNotifier?.value;
    final shouldSwitch = switchGateway ||
        (current?.failover?['should_try_another_option'] == true);
    if (current != null) {
      _paymentStatusNotifier?.value = current.copyWith(
        phase: _StorePaymentPhase.processing,
        reason: null,
      );
    }

    try {
      final precheck = await ApiService().checkCheckoutStatus(orderId, live: true);
      if (!mounted) return;
      final status = (precheck['status'] ?? '').toString().trim().toUpperCase();
      final isCleared = precheck['paid'] == true ||
          precheck['is_cleared'] == true ||
          precheck['already_paid'] == true ||
          status == 'CLEARED' ||
          status == 'PAID' ||
          status == 'COMPLETED' ||
          status == 'SETTLED';
      if (isCleared) {
        await _completeStorePaymentConfirmed(
          orderId: orderId,
          gateway: precheck['gateway']?.toString(),
        );
        return;
      }
      if (precheck['is_refunded'] == true || status == 'REFUNDED') {
        _paymentPollTimer?.cancel();
        if (mounted) {
          setState(() => _lastProcessingOrderId = null);
        }
        final latest = _paymentStatusNotifier?.value;
        if (latest != null) {
          _paymentStatusNotifier?.value = latest.copyWith(
            phase: _StorePaymentPhase.failed,
            isExpired: false,
            reason:
                'Payment was refunded for this order. Your cart items are still saved.',
          );
        }
        return;
      }
    } catch (_) {}

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS) && !shouldSwitch) {
      try {
        final refreshed =
            await ApiService().retryCheckoutSession(orderId, retry: true);
        if (!mounted) return;
        final st = (refreshed['status'] ?? '').toString().trim().toUpperCase();
        if (refreshed['paid'] == true ||
            refreshed['is_cleared'] == true ||
            st == 'CLEARED' ||
            st == 'PAID') {
          await _completeStorePaymentConfirmed(
            orderId: orderId,
            gateway: refreshed['gateway']?.toString(),
          );
          return;
        }
        if (refreshed['is_refunded'] == true ||
            st == 'REFUNDED' ||
            refreshed['statusCode'] == 409) {
          _paymentPollTimer?.cancel();
          setState(() => _lastProcessingOrderId = null);
          final latest = _paymentStatusNotifier?.value;
          if (latest != null) {
            _paymentStatusNotifier?.value = latest.copyWith(
              phase: _StorePaymentPhase.failed,
              isExpired: false,
              reason:
                  'Payment was refunded for this order. Your cart items are still saved.',
            );
          }
          return;
        }
        final gwOrder = refreshed['gateway_order_id']?.toString().trim() ??
            _pendingGatewayOrderId ??
            orderId;
        final rzpKeyId =
            (refreshed['razorpay_key_id'] ?? refreshed['key_id'])?.toString().trim() ?? '';
        final rawRzpOrderId =
            (refreshed['rzp_order_id'] ?? refreshed['razorpay_order_id'])?.toString().trim() ?? '';
        final effectiveRzpOrderId =
            rawRzpOrderId.isNotEmpty ? rawRzpOrderId : (gwOrder.startsWith('order_') ? gwOrder : '');
        final linkUrl = (refreshed['link_url'] ?? refreshed['payment_url'] ?? '').toString().trim();
        final upiUri = refreshed['upi_uri']?.toString().trim();
        final refreshedPayable = num.tryParse(
          (refreshed['verified_net_payable'] ?? refreshed['net_payable'] ?? refreshed['amount'] ?? '').toString(),
        );
        final prevAmt = _pendingPaidAmount > 0
            ? _pendingPaidAmount
            : widget.cartState.finalPayableAmount;
        final paidAmt = (refreshedPayable != null && refreshedPayable > 0)
            ? refreshedPayable
            : prevAmt;
        final serverItems = refreshed['verified_items'] is List
            ? refreshed['verified_items'] as List
            : const <dynamic>[];
        final serverDiscount = double.tryParse((refreshed['verified_discount'] ?? '').toString());
        final synced = widget.cartState.syncCartPrices(serverItems, updatedCouponDiscount: serverDiscount);
        if (refreshed['price_updated'] == true || synced || (paidAmt - prevAmt).abs() >= 1.0) {
          _pendingPaidAmount = paidAmt;
          _closeWaitingModal();
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(
                  'Catalog price updated (₹${prevAmt.round()} → ₹${paidAmt.round()}). Review & tap Pay to confirm.',
                ),
                backgroundColor: const Color(0xFFD97706),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }

        if (rzpKeyId.isNotEmpty && effectiveRzpOrderId.isNotEmpty) {
          _pendingGatewayOrderId = effectiveRzpOrderId;
          _closeWaitingModal();
          await _runNativeRazorpaySheet(
            orderId: orderId,
            rzpOrderId: effectiveRzpOrderId,
            razorpayKeyId: rzpKeyId,
            linkUrl: linkUrl,
            paidAmount: paidAmt,
            upiUri: upiUri,
          );
          return;
        }
      } catch (_) {}
    }

    _startForegroundPaymentPolling();
    final retryParam = shouldSwitch ? 'switch_gateway=1' : 'retry=1';
    final retryUrl =
        '${ApiService.cbmBaseUrl}/checkout/${Uri.encodeComponent(orderId)}?$retryParam';
    final launched = await _launchCheckoutUrl(retryUrl);
    if (!launched && mounted && _paymentStatusNotifier != null) {
      _paymentPollTimer?.cancel();
      _paymentStatusNotifier!.value = _paymentStatusNotifier!.value.copyWith(
        phase: _StorePaymentPhase.failed,
        reason: 'Could not open payment browser. Please try again.',
      );
    }
  }

  void _openOrdersHistoryFromCart() {
    final parentNav = Navigator.of(context);
    _paymentPollTimer?.cancel();
    _closeWaitingModal();
    if (mounted) {
      Navigator.pop(context);
    }
    if (parentNav.context.mounted) {
      showModalBottomSheet(
        context: parentNav.context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => OrdersSheet(cartState: widget.cartState),
      );
    }
  }

  Future<void> _runNativeRazorpaySheet({
    required String orderId,
    required String rzpOrderId,
    required String razorpayKeyId,
    required String linkUrl,
    required num paidAmount,
    String? upiUri,
  }) async {
    if (!mounted) return;
    await RazorpayCheckoutSheet.show(
      context,
      orderId: orderId,
      rzpOrderId: rzpOrderId,
      razorpayKeyId: razorpayKeyId,
      amount: paidAmount.toDouble(),
      customerPhone: widget.cartState.userPhone,
      customerEmail: widget.cartState.userEmail,
      customerName: widget.cartState.userName,
      fallbackCheckoutUrl: linkUrl,
      upiUri: upiUri,
      onPaymentCleared: () async {
        await _completeStorePaymentConfirmed(
          orderId: orderId,
          gateway: 'RAZORPAY',
        );
      },
      onPaymentFailed: (reason) {
        if (mounted) {
          _paymentStatusNotifier?.value = _StorePaymentModalState(
            phase: _StorePaymentPhase.failed,
            orderId: orderId,
            amount: paidAmount,
            reason: reason,
          );
          _reportFailureToRecovery(orderId, reason);
          _openPaymentConfirmationModal();
        }
      },
    );
  }

  Future<void> _beginOnlinePgPaymentFlow({
    required String orderId,
    required String checkoutUrl,
    required num paidAmount,
    required num savedAmount,
    String? couponName,
    String? gatewayOrderId,
    String? primaryGateway,
    String? upiUri,
    String? razorpayKeyId,
    String? rzpOrderId,
  }) async {
    _paymentPollTimer?.cancel();
    final prevNotifier = _paymentStatusNotifier;
    _pendingOrderId = orderId;
    _pendingGatewayOrderId = gatewayOrderId;
    _lastProcessingOrderId = orderId;
    _pendingPaidAmount = paidAmount;
    _pendingSavedAmount = savedAmount;
    _pendingCouponName = couponName;
    _foregroundPollCount = 0;

    _paymentStatusNotifier = ValueNotifier<_StorePaymentModalState>(
      _StorePaymentModalState(
        phase: _StorePaymentPhase.processing,
        orderId: orderId,
        amount: paidAmount,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      prevNotifier?.dispose();
    });

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      String effectiveKeyId = (razorpayKeyId ?? '').trim();
      String effectiveRzpOrderId = (rzpOrderId ?? '').trim();
      if (effectiveRzpOrderId.isEmpty && (gatewayOrderId ?? '').startsWith('order_')) {
        effectiveRzpOrderId = gatewayOrderId!.trim();
      }
      String? effectiveUpiUri = upiUri;

      final gwLower = (primaryGateway ?? '').trim().toLowerCase();
      if (effectiveKeyId.isEmpty ||
          effectiveRzpOrderId.isEmpty ||
          gwLower == 'razorpay') {
        if (effectiveKeyId.isEmpty || effectiveRzpOrderId.isEmpty) {
          try {
            final resolved = await ApiService().retryCheckoutSession(orderId, retry: false);
            if (!mounted) return;
            if (resolved['paid'] == true || resolved['is_cleared'] == true) {
              await _completeStorePaymentConfirmed(
                orderId: orderId,
                gateway: resolved['gateway']?.toString() ?? 'RAZORPAY',
              );
              return;
            }
            effectiveKeyId =
                (resolved['razorpay_key_id'] ?? resolved['key_id'])?.toString().trim() ?? effectiveKeyId;
            final resolvedRzpOrder =
                (resolved['rzp_order_id'] ?? resolved['razorpay_order_id'])?.toString().trim() ?? '';
            if (resolvedRzpOrder.isNotEmpty) {
              effectiveRzpOrderId = resolvedRzpOrder;
            } else if ((resolved['gateway_order_id'] ?? '').toString().startsWith('order_')) {
              effectiveRzpOrderId = resolved['gateway_order_id'].toString().trim();
            }
            effectiveUpiUri ??= resolved['upi_uri']?.toString().trim();
          } catch (_) {}
        }
      }

      if (effectiveKeyId.isNotEmpty && effectiveRzpOrderId.isNotEmpty) {
        await _runNativeRazorpaySheet(
          orderId: orderId,
          rzpOrderId: effectiveRzpOrderId,
          razorpayKeyId: effectiveKeyId,
          linkUrl: checkoutUrl,
          paidAmount: paidAmount,
          upiUri: effectiveUpiUri,
        );
        return;
      }
    }

    _openPaymentConfirmationModal();
    _startForegroundPaymentPolling();

    final launched = await _launchCheckoutUrl(checkoutUrl);
    if (!launched && mounted && _paymentStatusNotifier != null) {
      _paymentPollTimer?.cancel();
      _paymentStatusNotifier!.value = _paymentStatusNotifier!.value.copyWith(
        phase: _StorePaymentPhase.failed,
        reason: 'Could not launch payment browser. Please tap Retry Payment.',
      );
    }
  }

  Future<void> _reopenProcessingOrderModal(String orderId, {required bool retry}) async {
    _paymentPollTimer?.cancel();
    _paymentStatusNotifier?.dispose();
    _pendingOrderId = orderId;
    _foregroundPollCount = 0;
    _paymentStatusNotifier = ValueNotifier<_StorePaymentModalState>(
      _StorePaymentModalState(
        phase: _StorePaymentPhase.processing,
        orderId: orderId,
        amount: _pendingPaidAmount > 0
            ? _pendingPaidAmount
            : widget.cartState.finalPayableAmount,
      ),
    );
    _openPaymentConfirmationModal();
    if (retry) {
      await _retryStorePayment(orderId);
    } else {
      _startForegroundPaymentPolling();
      await _pollPendingOrderStatus(immediate: true);
    }
  }

  void _openPaymentConfirmationModal() {
    if (_isWaitingModalOpen || _paymentStatusNotifier == null || !mounted) {
      return;
    }
    _isWaitingModalOpen = true;

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        _waitingModalContext = modalCtx;
        return ValueListenableBuilder<_StorePaymentModalState>(
          valueListenable: _paymentStatusNotifier!,
          builder: (ctx, state, _) {
            final isProcessing = state.phase == _StorePaymentPhase.processing;
            final isFailed = state.phase == _StorePaymentPhase.failed;

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(
                20,
                14,
                20,
                20 + MediaQuery.of(ctx).viewPadding.bottom,
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
                  if (isProcessing)
                    Container(
                      width: 60,
                      height: 60,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFFDE68A)),
                      ),
                      child: const CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFFD97706)),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: const Icon(
                        Icons.error_outline_rounded,
                        color: Color(0xFFDC2626),
                        size: 34,
                      ),
                    ),
                  const SizedBox(height: 14),
                  Text(
                    isProcessing
                        ? 'Payment is Processing'
                        : 'Payment Not Completed',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Awaiting Payment Confirmation',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF334155),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0F2FE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '₹${state.amount}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isFailed
                          ? const Color(0xFFFEF2F2)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isFailed
                            ? const Color(0xFFFECACA)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    child: Text(
                      isProcessing
                          ? 'Payment is processing. Order stays temporary and appears in Order History once confirmed (auto-checking...).'
                          : (state.reason ??
                              'Payment was not completed. Your cart items are still intact.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: isFailed
                            ? const Color(0xFF991B1B)
                            : const Color(0xFF475569),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Builder(
                    builder: (_) {
                      final failover = state.failover;
                      final nextGwLabel = failover?['next_gateway_label']?.toString();
                      final shouldSwitchGw =
                          failover?['should_try_another_option'] == true &&
                          nextGwLabel != null &&
                          nextGwLabel.isNotEmpty;
                      final railHint = failover?['rail_hint']?.toString();
                      return Column(
                        children: [
                          if (isFailed &&
                              (railHint == 'TRY_CARD_OR_NETBANKING' ||
                                  railHint == 'TRY_OTHER_UPI_OR_CARD')) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                railHint == 'TRY_CARD_OR_NETBANKING'
                                    ? 'Tip: Try Debit/Credit Card, NetBanking, or an alternate UPI app.'
                                    : 'Tip: If this UPI attempt fails again, switch gateway for Cards / NetBanking.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF0369A1),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _retryStorePayment(
                                state.orderId,
                                switchGateway: shouldSwitchGw,
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 13, horizontal: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: Icon(
                                shouldSwitchGw
                                    ? Icons.swap_horiz_rounded
                                    : Icons.refresh_rounded,
                                size: 18,
                              ),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  shouldSwitchGw
                                      ? 'Try Another Option ($nextGwLabel)'
                                      : 'Retry Payment',
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (isFailed &&
                              !shouldSwitchGw &&
                              nextGwLabel != null &&
                              nextGwLabel.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => _retryStorePayment(
                                state.orderId,
                                switchGateway: true,
                              ),
                              icon: const Icon(Icons.swap_horiz_rounded,
                                  size: 16),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Try another option ($nextGwLabel)',
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          if (isFailed &&
                              widget.cartState.isCodEligibleForAllItems) ...[
                            const SizedBox(height: 6),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _switchFailedPaymentToCod,
                                icon: const Icon(
                                    Icons.local_shipping_outlined,
                                    size: 16),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    'Switch to Cash on Delivery',
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF047857),
                                  side: const BorderSide(
                                      color: Color(0xFF10B981)),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 11, horizontal: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openOrdersHistoryFromCart,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0F172A),
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 11, horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Order History',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            _paymentPollTimer?.cancel();
                            _closeWaitingModal();
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF64748B),
                            side: const BorderSide(color: Color(0xFFE2E8F0)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 11, horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Close',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _paymentPollTimer?.cancel();
      _isWaitingModalOpen = false;
      _waitingModalContext = null;
      if (_paymentStatusNotifier?.value.phase != _StorePaymentPhase.cleared) {
        _pendingOrderId = null;
      }
    });
  }

  Future<void> _processOnlineOrder({required String paymentMethod}) async {
    if (WebAppDownloadConfig.isWeb) {
      await showWebAppDownloadSheet(
        context,
        badge: 'PAYMENT ONLY IN APP • UP TO 80% OFF',
        title: 'Download ROParts App to Complete Payment',
        subtitle:
            'Your cart items are saved! Install the ROParts Android App to pay and unlock up to 80% off.',
      );
      return;
    }
    if (_isPaying || widget.cartState.items.isEmpty) return;

    final phone = widget.cartState.userPhone.isNotEmpty
        ? widget.cartState.userPhone
        : (widget.cartState.customerId ?? '');
    final customerId = PhoneNormalizer.toCustomerId(phone);
    if (customerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in with mobile number to place order.')),
      );
      return;
    }

    final onlineAddr = widget.cartState.activeOnlineAddress;
    final address = _addressController.text.trim().isNotEmpty
        ? _addressController.text.trim()
        : (onlineAddr?.fullAddress ?? '').trim();
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter or select a Pan-India delivery address.')),
      );
      return;
    }

    final resolvedPin = (onlineAddr?.pincode ?? widget.cartState.deliveryPincode).replaceAll(RegExp(r'\D'), '');
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(resolvedPin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an address with a valid 6-digit Indian PIN code.')),
      );
      return;
    }

    final recipientName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : (onlineAddr?.recipientName ?? widget.cartState.userName);
    final recipientPhone = (onlineAddr?.recipientPhone?.isNotEmpty == true)
        ? onlineAddr!.recipientPhone!
        : phone.replaceAll(RegExp(r'\D'), '');

    final previousDisplayedPayable = widget.cartState.finalPayableAmount;
    setState(() => _isPaying = true);
    try {
      final res = await ApiService().createOnlineOrder(
        customerId: customerId,
        items: widget.cartState.items.values
            .map((item) => {
                  'sku': item.product.sku,
                  'name': item.product.name,
                  'quantity': item.quantity,
                  'price': item.product.mrp,
                  'mrp': item.product.mrp,
                  if (item.product.freeSpares.isNotEmpty) ...{
                    'free_spares': item.product.freeSpares,
                    'free_spares_value': item.product.freeSparesValue,
                  },
                })
            .toList(),
        address: address,
        pincode: resolvedPin,
        recipientName: recipientName,
        recipientPhone: recipientPhone,
        deliveryCity: onlineAddr?.city ?? widget.cartState.deliveryCity,
        deliveryState: onlineAddr?.stateName,
        paymentMethod: paymentMethod,
        couponCode: widget.cartState.appliedCoupon?.code,
        email: widget.cartState.userEmail,
        expectedNetPayable: previousDisplayedPayable.toDouble(),
      );

      if (!mounted) return;

      final rawOrderId = ((res['order_id'] ?? res['order']?['order_number'])?.toString())?.trim();
      final invoiceNum = rawOrderId ?? '';
      if (invoiceNum.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order reference missing from server. Please retry.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final serverPayable = num.tryParse(
        (res['net_payable'] ?? res['breakdown']?['net_payable'] ?? '').toString(),
      );
      final paidAmount = (serverPayable != null && serverPayable > 0)
          ? serverPayable
          : widget.cartState.finalPayableAmount;
      final serverItems = (res['verified_items'] ?? res['order']?['items']) as List<dynamic>? ?? const [];
      final serverCouponDisc = double.tryParse((res['breakdown']?['coupon_discount'] ?? '').toString());
      final syncedPriceChanged = widget.cartState.syncCartPrices(
        serverItems,
        updatedCouponDiscount: serverCouponDisc,
      );
      final serverDeliveryFee = double.tryParse((res['breakdown']?['delivery_fee'] ?? '').toString());
      final bool shippingFeeUpdated = serverDeliveryFee != null &&
          (serverDeliveryFee - widget.cartState.onlineDeliveryFee).abs() >= 0.5;
      final bool priceUpdated = syncedPriceChanged ||
          shippingFeeUpdated ||
          res['price_updated'] == true ||
          (serverPayable != null && (serverPayable - previousDisplayedPayable).abs() >= 1.0);
      if (priceUpdated) {
        await widget.cartState.refreshOnlineShippingQuote();
        if (!mounted) return;
      }
      final savedAmount = widget.cartState.combinedTotalSavings;
      final couponName = widget.cartState.appliedCoupon?.code;

      if (res['already_paid'] == true) {
        _paymentPollTimer?.cancel();
        _closeWaitingModal();
        setState(() {
          _pendingOrderId = null;
          _lastProcessingOrderId = null;
        });
        widget.cartState.clearCart();
        _showOrderConfirmationSheet(
          invoiceNum: invoiceNum,
          paidAmount: paidAmount,
          savedAmount: savedAmount,
          couponName: couponName,
          paymentMethod: (res['primary_gateway'] ?? res['gateway'] ?? paymentMethod)
              .toString()
              .toUpperCase(),
        );
        return;
      }

      if (res['success'] == true && paymentMethod == 'ONLINE_PG' && priceUpdated) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Price updated from ₹$previousDisplayedPayable to ₹${paidAmount.toStringAsFixed(0)} per latest catalog. Tap Pay ₹${paidAmount.toStringAsFixed(0)} to confirm.',
            ),
            backgroundColor: const Color(0xFFD97706),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }

      if (res['success'] == true) {
        if (paymentMethod == 'ONLINE_PG') {
          final rawUrl = res['payment_url']?.toString().trim();
          final checkoutUrl = (rawUrl != null && rawUrl.isNotEmpty)
              ? rawUrl
              : '${ApiService.cbmBaseUrl}/checkout/${Uri.encodeComponent(invoiceNum)}';
          await _beginOnlinePgPaymentFlow(
            orderId: invoiceNum,
            checkoutUrl: checkoutUrl,
            paidAmount: paidAmount,
            savedAmount: savedAmount,
            couponName: couponName,
            gatewayOrderId: res['gateway_order_id']?.toString(),
            primaryGateway: res['primary_gateway']?.toString(),
            upiUri: res['upi_uri']?.toString(),
            razorpayKeyId: (res['razorpay_key_id'] ?? res['key_id'])?.toString(),
            rzpOrderId: (res['rzp_order_id'] ?? res['razorpay_order_id'])?.toString(),
          );
          return;
        }

        // Default COD confirmation
        final orderStatus = (res['status'] ?? res['order']?['status'] ?? 'PENDING_CONFIRMATION').toString().toUpperCase();
        final dispatchLabel = (res['auto_confirmed'] == true || orderStatus == 'CONFIRMED')
            ? 'Confirmed • Preparing Pan-India Courier'
            : 'Placed • Awaiting Admin Confirmation';
        widget.cartState.clearCart();
        _showOrderConfirmationSheet(
          invoiceNum: invoiceNum,
          paidAmount: paidAmount,
          savedAmount: savedAmount,
          couponName: couponName,
          paymentMethod: paymentMethod,
          dispatchStatusText: dispatchLabel,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['error'] ?? res['message'] ?? 'Order creation failed. Please retry.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order creation failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPaying = false);
      }
    }
  }

  void _showOrderConfirmationSheet({
    required String invoiceNum,
    required num paidAmount,
    required num savedAmount,
    String? couponName,
    required String paymentMethod,
    String dispatchStatusText = 'Order Placed • Pan-India Tracking Active',
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => OnlineOrderConfirmationSheet(
        cartState: widget.cartState,
        invoiceNum: invoiceNum,
        paidAmount: paidAmount,
        savedAmount: savedAmount,
        couponName: couponName,
        paymentMethod: paymentMethod,
        dispatchStatusText: dispatchStatusText,
        onContinue: () {
          Navigator.pop(ctx);
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  Widget _buildPaymentSelectionStep() {
    final onlineAddr = widget.cartState.activeOnlineAddress;
    final activePin = (onlineAddr?.pincode ?? widget.cartState.deliveryPincode).replaceAll(RegExp(r'\D'), '');
    final displayAddress = _addressController.text.trim().isNotEmpty
        ? _addressController.text.trim()
        : (onlineAddr?.fullAddress ?? '').trim();
    final recipient = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : (onlineAddr?.recipientName?.isNotEmpty == true ? onlineAddr!.recipientName! : widget.cartState.userName);
    final codEligible = widget.cartState.isCodEligibleForAllItems;
    final String codDisabledReason = !widget.cartState.isCodPolicyEnabled
        ? 'COD is currently disabled by Admin'
        : (!widget.cartState.isCodAmountEligible
            ? 'COD available only up to ₹${widget.cartState.maxCodOrderAmount}'
            : (!widget.cartState.isCodEligibleForAllItems
                ? 'One or more items require prepaid online payment'
                : 'Pay via cash or UPI when courier arrives'));

    final bool isOnlineSelected = _selectedPaymentMethod == 'ONLINE_PG';

    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const BouncingScrollPhysics(),
      children: [
        if (widget.recoveryBannerMessage != null ||
            widget.cartState.isRecoveryDraftPaymentFailed) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFFECDD3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.replay_circle_filled_rounded,
                    size: 18, color: Color(0xFFBE123C)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.recoveryBannerMessage ??
                        'Resuming your saved order (${widget.cartState.recoveryDraftDaysRemaining}d window). Retry online payment or switch to Cash on Delivery.',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF881337),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        // Order & Address Recap Pill
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${widget.cartState.itemCount} Item(s) • Pan-India Courier',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                  ),
                  Text(
                    '₹${widget.cartState.finalPayableAmount}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppTheme.appleBlue),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$recipient • PIN $activePin',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 2),
              Text(
                displayAddress,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B), height: 1.3),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        if (WebAppDownloadConfig.isWeb) ...[
          WebAppDownloadGateCard(
            key: const Key('web_cart_payment_download_gate'),
            badge: 'PAYMENT ONLY IN APP • UP TO 80% OFF',
            title: 'Download ROParts App to Complete Payment',
            subtitle:
                'Web payment is disabled. Install the ROParts App to pay and unlock up to 80% off!',
            bullets: const [
              'Cart items & delivery address stay saved',
              'Up to 80% discount on genuine RO parts on app',
              'Instant UPI, Card & Cash on Delivery options',
            ],
            onDownloadTap: () => WebAppDownloadConfig.launchAppDownload(context),
          ),
          const SizedBox(height: 16),
        ] else ...[
        const Text(
          'Select how you would like to pay',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
        ),
        const SizedBox(height: 10),

        // Option 1: Pay Online (UPI / Cards / NetBanking)
        InkWell(
          onTap: _isPaying ? null : () => setState(() => _selectedPaymentMethod = 'ONLINE_PG'),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isOnlineSelected ? const Color(0xFFF0F9FF) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isOnlineSelected ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                width: isOnlineSelected ? 1.8 : 1.0,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.payment_rounded, color: Color(0xFF0284C7), size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Online Payment (UPI / Cards / NetBanking)',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Instant confirmation via GPay, PhonePe, Paytm or Card',
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isOnlineSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: isOnlineSelected ? const Color(0xFF0284C7) : const Color(0xFF94A3B8),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        // Option 2: Cash on Delivery (COD)
        InkWell(
          onTap: (_isPaying || !codEligible) ? null : () => setState(() => _selectedPaymentMethod = 'COD'),
          borderRadius: BorderRadius.circular(16),
          child: Opacity(
            opacity: codEligible ? 1.0 : 0.55,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (!isOnlineSelected && codEligible) ? const Color(0xFFF0FDF4) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: (!isOnlineSelected && codEligible) ? const Color(0xFF16A34A) : const Color(0xFFE2E8F0),
                  width: (!isOnlineSelected && codEligible) ? 1.8 : 1.0,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.local_shipping_outlined, color: Color(0xFF15803D), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cash on Delivery (COD)',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          codDisabledReason,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: codEligible ? const Color(0xFF475569) : const Color(0xFFDC2626),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    (!isOnlineSelected && codEligible) ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: (!isOnlineSelected && codEligible) ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _buildPinnedBottomBar() {
    final bool isStep1 = _checkoutStep == 1;
    final bool isWebStep1 = isStep1 && WebAppDownloadConfig.isWeb;
    final bool codEligible = widget.cartState.isCodEligibleForAllItems;
    final bool isCodChosen = isStep1 && _selectedPaymentMethod == 'COD' && codEligible;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _isPaying
              ? null
              : (isWebStep1
                  ? () => WebAppDownloadConfig.launchAppDownload(context)
                  : (isStep1
                      ? () => _processOnlineOrder(paymentMethod: isCodChosen ? 'COD' : 'ONLINE_PG')
                      : _handleConfirmCartStep)),
          icon: _isPaying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                )
              : Icon(
                  isWebStep1
                      ? Icons.download_rounded
                      : (isStep1
                          ? (isCodChosen ? Icons.local_shipping_outlined : Icons.lock_outline_rounded)
                          : Icons.check_circle_outline_rounded),
                  color: Colors.white,
                  size: 18,
                ),
          label: Text(
            _isPaying
                ? 'PROCESSING...'
                : (isWebStep1
                    ? 'Download App & Get 80% Off'
                    : (isStep1
                        ? (isCodChosen
                            ? 'Place COD Order • ₹${widget.cartState.finalPayableAmount}'
                            : 'Pay Online • ₹${widget.cartState.finalPayableAmount}')
                        : 'Confirm Order • ₹${widget.cartState.finalPayableAmount}')),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 0.2),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: isWebStep1
                ? const Color(0xFF0284C7)
                : (isStep1
                    ? (isCodChosen ? const Color(0xFF16A34A) : const Color(0xFF0284C7))
                    : const Color(0xFF0F172A)),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.cartState,
      builder: (context, child) {
        final items = widget.cartState.items.values.toList();
        final appliedCoupon = widget.cartState.appliedCoupon;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.viewPaddingOf(context).bottom,
          ),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.90,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Apple Pull Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0x33000000),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          if (_checkoutStep == 1 && items.isNotEmpty) ...[
                            IconButton(
                              onPressed: _isPaying ? null : () => setState(() => _checkoutStep = 0),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppTheme.textPrimary),
                              tooltip: 'Back to Cart',
                            ),
                            const SizedBox(width: 4),
                          ] else ...[
                            const Icon(Icons.shopping_bag_outlined, color: AppTheme.appleBlue, size: 22),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              _checkoutStep == 1 && items.isNotEmpty
                                  ? 'Payment Method'
                                  : 'Your Cart (${widget.cartState.itemCount} items)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (items.isNotEmpty && _checkoutStep == 0)
                      TextButton(
                        onPressed: () {
                          _paymentPollTimer?.cancel();
                          _pendingOrderId = null;
                          _lastProcessingOrderId = null;
                          _checkoutStep = 0;
                          widget.cartState.clearCart(syncDismiss: true);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.appleRed,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text(
                          'Clear All',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.borderLight),

              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF5F5F7),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.shopping_bag_outlined, size: 36, color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Your cart is empty',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Add genuine spare parts or service kits from the catalog to place an online order.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.appleBlue,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.storefront_outlined, size: 16),
                        label: const Text('Browse Catalog', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      ),
                    ],
                  ),
                )
              else if (_checkoutStep == 1)
                Expanded(child: _buildPaymentSelectionStep())
              else
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      if (_lastProcessingOrderId != null && !_isWaitingModalOpen)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFFBEB),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFFDE68A)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.hourglass_top_rounded,
                                      size: 16, color: Color(0xFFD97706)),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Payment Verification Pending',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF92400E),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Payment is processing. Order stays temporary and appears in Order History once confirmed (auto-checking...).',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFB45309),
                                  height: 1.3,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: () => _reopenProcessingOrderModal(
                                        _lastProcessingOrderId!,
                                        retry: true,
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF0284C7),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text('Retry Payment', maxLines: 1, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: _openOrdersHistoryFromCart,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF0F172A),
                                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    child: const Text('Order History', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      // Cart Item List
                      ...items.map((item) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F7),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: item.isScanned ? const Color(0xFF86EFAC) : const Color(0x14000000),
                              width: item.isScanned ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0x14000000)),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: CatalogNetworkImage(
                                    imageUrl: item.product.image,
                                    fit: BoxFit.contain,
                                    fallbackIcon: Icons.water_drop,
                                    fallbackIconSize: 24,
                                    fallbackIconColor: AppTheme.appleBlue,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (item.isScanned)
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 3),
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFDCFCE7),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.verified_rounded, size: 11, color: Color(0xFF16A34A)),
                                            SizedBox(width: 3),
                                            Text(
                                              'Genuine Scanned Spare',
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF15803D),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Text(
                                      item.product.name,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.textPrimary,
                                        letterSpacing: -0.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '₹${item.product.mrp} each',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Total: ₹${item.totalPrice}',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: AppTheme.appleBlue,
                                      ),
                                    ),
                                    if (item.product.freeSpares.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFECFDF5),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFFA7F3D0)),
                                        ),
                                        child: Text(
                                          '🎁 Sealed Free: ${item.product.freeSpares.map((f) => '${(int.tryParse((f['qty'] ?? f['quantity'] ?? '1').toString()) ?? 1) * item.quantity}x ${f['name'] ?? f['product_name'] ?? f['sku']}').join(', ')} (₹0 FREE)',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF047857),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  BouncingWidget(
                                    onTap: () {
                                      _lastProcessingOrderId = null;
                                      widget.cartState.decrementQuantity(item.product);
                                    },
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: const Color(0x1E000000)),
                                      ),
                                      child: const Icon(Icons.remove, size: 14, color: AppTheme.textPrimary),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 180),
                                      transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                                      child: Text(
                                        '${item.quantity}',
                                        key: ValueKey<int>(item.quantity),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                  BouncingWidget(
                                    onTap: () {
                                      _lastProcessingOrderId = null;
                                      widget.cartState.addToCart(item.product);
                                    },
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: const BoxDecoration(
                                        color: AppTheme.appleBlue,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.add, size: 14, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),

                      const SizedBox(height: 6),

                      // --- COUPONS & OFFERS SECTION ---
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F7),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: appliedCoupon != null ? const Color(0xFF86EFAC) : const Color(0x14000000),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.local_offer_rounded, size: 15, color: Color(0xFF16A34A)),
                                SizedBox(width: 6),
                                Text(
                                  'Coupons & Discounts',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // If coupon applied: show active card
                            if (appliedCoupon != null)
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF86EFAC)),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF16A34A),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  appliedCoupon.code,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 11,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  'Saved ₹${widget.cartState.couponDiscountAmount}!',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF15803D),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            appliedCoupon.description,
                                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF166534)),
                                          ),
                                        ],
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => widget.cartState.removeCoupon(),
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(0xFFDC2626),
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        minimumSize: Size.zero,
                                      ),
                                      child: const Text('REMOVE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                  ],
                                ),
                              )
                            else ...[
                              // Coupon Input Row
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _couponController,
                                      textCapitalization: TextCapitalization.characters,
                                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                                      decoration: InputDecoration(
                                        hintText: 'Enter Coupon (e.g. ROPARTS15)',
                                        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.normal),
                                        isDense: true,
                                        filled: true,
                                        fillColor: Colors.white,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                                      ),
                                      onSubmitted: (_) => _applyCouponText(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.appleBlue,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    onPressed: widget.cartState.isValidatingCoupon ? null : _applyCouponText,
                                    child: widget.cartState.isValidatingCoupon
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                          )
                                        : const Text('APPLY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                                  ),
                                ],
                              ),
                              if (widget.cartState.couponError != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  widget.cartState.couponError!,
                                  style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626), fontWeight: FontWeight.w600),
                                ),
                              ],
                              const SizedBox(height: 10),
                              // Quick Coupon Chips (Live from DB)
                              if (widget.cartState.isLoadingCoupons && widget.cartState.availableCoupons.isEmpty)
                                const Text(
                                  'Loading live offers...',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                )
                              else if (widget.cartState.availableCoupons.isEmpty)
                                const Text(
                                  'Have a promo or QR code? Enter it above or tap scan.',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                )
                              else
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  physics: const BouncingScrollPhysics(),
                                  child: Row(
                                    children: widget.cartState.availableCoupons.map((c) {
                                      final bool isExhausted = c.isExhausted;
                                      final bool meetsMin = widget.cartState.totalAmount >= c.minOrderValue;
                                      final bool isUsable = !isExhausted && meetsMin;
                                      final String chipLabel = isExhausted
                                          ? '${c.code} (Redeemed)'
                                          : (meetsMin
                                              ? '${c.code} (${c.title})'
                                              : '${c.code} (Min ₹${c.minOrderValue.toInt()})');
                                      return Padding(
                                        padding: const EdgeInsets.only(right: 6),
                                        child: Opacity(
                                          opacity: isUsable ? 1.0 : 0.45,
                                          child: ActionChip(
                                            label: Text(chipLabel),
                                            labelStyle: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.bold,
                                              color: isUsable ? const Color(0xFF0284C7) : const Color(0xFF64748B),
                                            ),
                                            backgroundColor: Colors.white,
                                            side: BorderSide(
                                              color: isUsable ? const Color(0xFFBAE6FD) : const Color(0xFFCBD5E1),
                                            ),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            onPressed: () {
                                              if (isExhausted) {
                                                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                                  SnackBar(
                                                    content: Text('${c.code} has already been redeemed on this account.'),
                                                    duration: const Duration(seconds: 2),
                                                    behavior: SnackBarBehavior.floating,
                                                  ),
                                                );
                                                return;
                                              }
                                              if (!meetsMin) {
                                                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                                  SnackBar(
                                                    content: Text('Add ₹${(c.minOrderValue - widget.cartState.totalAmount).ceil()} more to unlock ${c.code}'),
                                                    duration: const Duration(seconds: 2),
                                                    behavior: SnackBarBehavior.floating,
                                                  ),
                                                );
                                                return;
                                              }
                                              _couponController.text = c.code;
                                              _applyCouponText();
                                            },
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Clean Delivery Address Card (Matches Quick Booking _buildAddressCard)
                      Builder(
                        builder: (context) {
                          final onlineAddr = widget.cartState.activeOnlineAddress;
                          final activePin = onlineAddr?.pincode ?? widget.cartState.deliveryPincode;
                          final activeState = onlineAddr?.stateName;
                          final displayAddress = _addressController.text.trim().isNotEmpty
                              ? _addressController.text.trim()
                              : (onlineAddr?.fullAddress ?? '').trim();
                          final hasAddress = displayAddress.isNotEmpty && RegExp(r'^[1-9][0-9]{5}$').hasMatch(activePin.replaceAll(RegExp(r'\D'), ''));

                          return Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
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
                                if (hasAddress) ...[
                                  Row(
                                    children: [
                                      Icon(
                                        onlineAddr?.tag == 'Work'
                                            ? Icons.work_outline_rounded
                                            : (onlineAddr?.tag == 'Home' ? Icons.home_rounded : Icons.local_shipping_rounded),
                                        color: const Color(0xFF0284C7),
                                        size: 19,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'DELIVERING TO ${(onlineAddr?.tag ?? 'COURIER').toUpperCase()} • PIN $activePin',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFF0284C7),
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                      const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF16A34A)),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: _openOnlineAddressPicker,
                                        borderRadius: BorderRadius.circular(8),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                          child: Text(
                                            'Change',
                                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF0284C7)),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    displayAddress,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                      height: 1.35,
                                    ),
                                  ),
                                  if (activeState != null && activeState.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Pan-India Courier • $activeState',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                                    ),
                                  ],
                                ] else ...[
                                  const Row(
                                    children: [
                                      Icon(Icons.public_rounded, color: Color(0xFF0284C7), size: 20),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Select Delivery Address (Pan-India)',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: Color(0xFF0F172A)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 5),
                                  const Text(
                                    'Delivers across India to any 6-digit PIN code.',
                                    style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                                  ),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF0284C7),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      onPressed: _openOnlineAddressPicker,
                                      icon: const Icon(Icons.add_location_alt_rounded, size: 16),
                                      label: const Text('Add Delivery Address (Any PIN)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 10),

                      // Clean Contact Pill (Matches Quick Booking _buildContactCard)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.person_outline_rounded, size: 17, color: Color(0xFF475569)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Receiver: ${_nameController.text.trim().isNotEmpty ? _nameController.text.trim() : (widget.cartState.userName.isNotEmpty ? widget.cartState.userName : "Customer")}'
                                    '${widget.cartState.userPhone.isNotEmpty ? " • ${widget.cartState.userPhone}" : ""}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setState(() => _editingContact = !_editingContact),
                                  child: Text(
                                    _editingContact ? 'Done' : 'Edit',
                                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF0284C7)),
                                  ),
                                ),
                              ],
                            ),
                            if (_editingContact) ...[
                              const SizedBox(height: 8),
                              TextField(
                                controller: _nameController,
                                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                onChanged: (_) => setState(() {}),
                                decoration: InputDecoration(
                                  hintText: 'Recipient Name',
                                  isDense: true,
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Clean Price Breakdown (with compact inline free-courier hint)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F7),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0x14000000)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Subtotal (MRP)', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                                Text(
                                  '₹${widget.cartState.totalAmount}',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                ),
                              ],
                            ),
                            Builder(
                              builder: (_) {
                                double sealedFreeWorth = 0.0;
                                bool hasFreeSpares = false;
                                for (final ci in widget.cartState.items.values) {
                                  if (ci.product.freeSpares.isNotEmpty) {
                                    hasFreeSpares = true;
                                    if (ci.product.freeSparesValue > 0) {
                                      sealedFreeWorth += ci.product.freeSparesValue * ci.quantity;
                                    } else {
                                      for (final sp in ci.product.freeSpares) {
                                        final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
                                        final mrp = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
                                        sealedFreeWorth += (q > 0 ? q : 1) * mrp * ci.quantity;
                                      }
                                    }
                                  }
                                }
                                if (!hasFreeSpares) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          sealedFreeWorth > 0
                                              ? '🎁 Sealed Free Spares (Worth ₹${sealedFreeWorth.round()})'
                                              : '🎁 Sealed Free Spares Inside Pouch',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF047857)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        '₹0 FREE',
                                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF16A34A)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            if (appliedCoupon != null && widget.cartState.couponDiscountAmount > 0) ...[
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Coupon Discount (${appliedCoupon.code})',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF16A34A)),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '-₹${widget.cartState.couponDiscountAmount}',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF16A34A)),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Courier Delivery Fee', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                                Text(
                                  widget.cartState.onlineDeliveryFee == 0
                                      ? 'FREE'
                                      : '₹${widget.cartState.onlineDeliveryFee}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: widget.cartState.onlineDeliveryFee == 0
                                        ? AppTheme.appleGreen
                                        : AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            if (widget.cartState.shippingFeeEnabled && widget.cartState.standardCourierCharge > 0) ...[
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  widget.cartState.isFreeShippingUnlocked
                                      ? '✓ Free All-India Delivery unlocked (Orders ≥ ₹${widget.cartState.freeShippingMinOrder})'
                                      : 'Add ₹${widget.cartState.amountRemainingForFreeShipping} more for FREE Delivery (₹${widget.cartState.standardCourierCharge} courier)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: widget.cartState.isFreeShippingUnlocked
                                        ? const Color(0xFF059669)
                                        : const Color(0xFFB45309),
                                  ),
                                ),
                              ),
                            ],
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Divider(height: 1, color: AppTheme.borderLight),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Total Payable',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary, letterSpacing: -0.3),
                                ),
                                Text(
                                  '₹${widget.cartState.finalPayableAmount}',
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.appleBlue, letterSpacing: -0.5),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              if (items.isNotEmpty) _buildPinnedBottomBar(),
            ],
          ),
        );
      },
    );
  }
}

/// Receipt sheet shown immediately when an Online Store order (COD or PG) succeeds.
/// When customer email is missing, shows a non-blocking small popup (with × dismiss)
/// right after order placement so checkout itself remains instant.
class OnlineOrderConfirmationSheet extends StatefulWidget {
  final CartState cartState;
  final String invoiceNum;
  final num paidAmount;
  final num savedAmount;
  final String? couponName;
  final String paymentMethod;
  final String dispatchStatusText;
  final VoidCallback onContinue;

  const OnlineOrderConfirmationSheet({
    super.key,
    required this.cartState,
    required this.invoiceNum,
    required this.paidAmount,
    required this.savedAmount,
    this.couponName,
    required this.paymentMethod,
    required this.dispatchStatusText,
    required this.onContinue,
  });

  @override
  State<OnlineOrderConfirmationSheet> createState() => _OnlineOrderConfirmationSheetState();
}

class _OnlineOrderConfirmationSheetState extends State<OnlineOrderConfirmationSheet> {
  Timer? _emailPromptTimer;

  @override
  void initState() {
    super.initState();
    final needsEmail = widget.cartState.isLoggedIn &&
        (widget.cartState.userEmail ?? '').trim().isEmpty;
    if (needsEmail) {
      _emailPromptTimer = Timer(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        showOrderEmailPromptDialog(
          context,
          cartState: widget.cartState,
          orderNumber: widget.invoiceNum,
          titleText: 'Get Updates on Email?',
          subtitleText: 'Update your email once to receive order updates, live AWB tracking & invoices.',
        );
      });
    }
  }

  @override
  void dispose() {
    _emailPromptTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.cartState,
      builder: (ctx, _) {
        final savedEmail = (widget.cartState.userEmail ?? '').trim();
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
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
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF0FDF4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 48),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Order Placed Successfully!',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Order #${widget.invoiceNum} • ${widget.paymentMethod}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                  ),
                  if (savedEmail.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Order alerts will also be sent to $savedEmail',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF0284C7)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Text('Amount Paid (Spares & Kits):', style: TextStyle(fontSize: 13, color: Color(0xFF475569))),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '₹${widget.paidAmount}',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                        if (widget.couponName != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text('Coupon Applied (${widget.couponName}):', style: const TextStyle(fontSize: 12, color: Color(0xFF16A34A))),
                              ),
                              const SizedBox(width: 8),
                              const Text('Discounted', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Text('Total Savings:', style: TextStyle(fontSize: 13, color: Color(0xFF16A34A))),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '₹${widget.savedAmount} Saved',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF16A34A)),
                            ),
                          ],
                        ),
                        const Divider(height: 16, color: Color(0xFFE2E8F0)),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Text('Order Status:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                widget.dispatchStatusText,
                                textAlign: TextAlign.end,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: widget.onContinue,
                      child: const Text('Continue Shopping', style: TextStyle(fontWeight: FontWeight.w800)),
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
