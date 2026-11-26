import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui show Image, ImageByteFormat;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/api_service.dart';
import '../services/razorpay_sdk_service.dart';
import 'bouncing_widget.dart';
import 'payment_brand_logos.dart';

enum _CheckoutView { main, addCard, qr }

/// Apple-style glassy Razorpay Custom UI (`razorpay_flutter_customui: ^1.5.1`) sheet.
/// Supports 1-tap UPI Intent apps, UPI ID Collect, Dynamic UPI QR,
/// dynamically-verified PayLater providers, Credit/Debit Cards, and Netbanking.
class RazorpayCheckoutSheet extends StatefulWidget {
  final String orderId;
  final String rzpOrderId;
  final String razorpayKeyId;
  final double amount;
  final String customerPhone;
  final String customerEmail;
  final String customerName;
  final String? fallbackCheckoutUrl;
  final String? upiUri;
  final String? initialMethod;
  final RazorpayAvailableMethods? initialMethods;
  final List<RazorpayUpiAppOption>? initialInstalledUpiApps;
  final Future<void> Function() onPaymentCleared;
  final void Function(String reason)? onPaymentFailed;
  final VoidCallback? onPaymentCancelled;

  const RazorpayCheckoutSheet({
    super.key,
    required this.orderId,
    required this.rzpOrderId,
    required this.razorpayKeyId,
    required this.amount,
    required this.customerPhone,
    required this.customerEmail,
    required this.customerName,
    required this.onPaymentCleared,
    this.fallbackCheckoutUrl,
    this.upiUri,
    this.initialMethod,
    this.initialMethods,
    this.initialInstalledUpiApps,
    this.onPaymentFailed,
    this.onPaymentCancelled,
  });

  /// Opens the Razorpay Custom UI modal bottom sheet.
  /// Returns `true` if payment succeeded and was verified by backend; `false` otherwise.
  static Future<bool> show(
    BuildContext context, {
    required String orderId,
    required String rzpOrderId,
    required String razorpayKeyId,
    required double amount,
    String? customerPhone,
    String? customerEmail,
    String? customerName,
    String? fallbackCheckoutUrl,
    String? upiUri,
    String? initialMethod,
    required Future<void> Function() onPaymentCleared,
    void Function(String reason)? onPaymentFailed,
    VoidCallback? onPaymentCancelled,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RazorpayCheckoutSheet(
        orderId: orderId,
        rzpOrderId: rzpOrderId,
        razorpayKeyId: razorpayKeyId,
        amount: amount,
        customerPhone: (customerPhone ?? '').trim(),
        customerEmail: (customerEmail ?? '').trim(),
        customerName: (customerName ?? '').trim(),
        fallbackCheckoutUrl: fallbackCheckoutUrl,
        upiUri: upiUri,
        initialMethod: initialMethod,
        onPaymentCleared: onPaymentCleared,
        onPaymentFailed: onPaymentFailed,
        onPaymentCancelled: onPaymentCancelled,
      ),
    );
    return result == true;
  }

  @override
  State<RazorpayCheckoutSheet> createState() => _RazorpayCheckoutSheetState();
}

class _RazorpayCheckoutSheetState extends State<RazorpayCheckoutSheet>
    with WidgetsBindingObserver {
  final RazorpaySdkService _sdk = RazorpaySdkService.instance;

  late _CheckoutView _currentView;
  RazorpayAvailableMethods _methods = RazorpayAvailableMethods.minimalFallback();
  List<RazorpayUpiAppOption> _upiApps = const [];
  bool _loadingCapabilities = true;
  bool _leftForegroundDuringAttempt = false;
  Timer? _resumeRecoveryTimer;

  bool _isBusy = false;
  String? _busyMessage;
  String? _bannerMessage;
  bool _bannerIsInfo = false;
  bool _paymentCompleted = false;

  // UPI ID expandable input state
  bool _showVpaInput = false;
  final TextEditingController _vpaController = TextEditingController();

  // Netbanking expand + search state
  bool _showAllBanks = false;
  final TextEditingController _bankSearchController = TextEditingController();
  String _bankQuery = '';

  // Add New Card form state
  final TextEditingController _cardNumberCtrl = TextEditingController();
  final TextEditingController _expiryCtrl = TextEditingController();
  final TextEditingController _cvvCtrl = TextEditingController();
  final TextEditingController _cardNameCtrl = TextEditingController();
  bool _showCvvInfo = false;
  String _detectedCardNetwork = '';

  // QR polling, prefetch & SSE live-clearance state
  Timer? _qrPollTimer;
  Timer? _qrCountdownTimer;
  Timer? _qrPrefetchTimer;
  StreamSubscription<Map<String, dynamic>>? _clearanceEventSub;
  Timer? _sseReconnectTimer;
  int _qrPollTick = 0;
  int _qrSecondsLeft = 600;
  bool _qrExpired = false;
  bool _paymentAttempted = false;
  bool _qrCheckingNow = false;
  bool _qrPollInFlight = false;
  bool _leftForegroundInQr = false;
  bool _qrLoading = false;
  String? _dynamicQrImageUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final init = (widget.initialMethod ?? '').toLowerCase().trim();
    if (init == 'qr') {
      _currentView = _CheckoutView.qr;
      _startQrTimers();
      if (widget.initialMethods == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureDynamicQrLoaded());
      }
    } else if (init == 'card') {
      _currentView = _CheckoutView.addCard;
    } else {
      _currentView = _CheckoutView.main;
    }

    if (widget.customerName.isNotEmpty) {
      _cardNameCtrl.text = widget.customerName;
    }

    _cardNumberCtrl.addListener(_onCardFieldChanged);
    _expiryCtrl.addListener(_onCardFieldChanged);
    _cvvCtrl.addListener(_onCardFieldChanged);
    _bankSearchController.addListener(() {
      if (mounted) {
        setState(() => _bankQuery = _bankSearchController.text.trim().toLowerCase());
      }
    });

    if (widget.initialMethods != null) {
      _methods = widget.initialMethods!;
      _upiApps = widget.initialInstalledUpiApps ?? const [];
      _loadingCapabilities = false;
    } else {
      _sdk.warmupCheckout();
      _subscribeCheckoutEvents();
      if (init != 'qr') {
        _qrPrefetchTimer = Timer(const Duration(milliseconds: 700), _prefetchQrIfIdle);
      }
      if (widget.initialInstalledUpiApps != null) {
        _upiApps = widget.initialInstalledUpiApps!;
        _loadRazorpayCapabilities(overrideUpiApps: widget.initialInstalledUpiApps);
      } else {
        _loadRazorpayCapabilities();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resumeRecoveryTimer?.cancel();
    _qrPrefetchTimer?.cancel();
    _sseReconnectTimer?.cancel();
    _clearanceEventSub?.cancel();
    _clearanceEventSub = null;
    _stopQrTimers();
    _sdk.cancelPendingAttempt();
    if (widget.initialMethods == null) {
      _sdk.releaseCheckoutWarmup();
    }
    _vpaController.dispose();
    _bankSearchController.dispose();
    _cardNumberCtrl.dispose();
    _expiryCtrl.dispose();
    _cvvCtrl.dispose();
    _cardNameCtrl.dispose();
    super.dispose();
  }

  void _scheduleSseReconnect() {
    if (!mounted || _paymentCompleted || widget.initialMethods != null) return;
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _paymentCompleted || widget.initialMethods != null) return;
      _subscribeCheckoutEvents();
    });
  }

  void _subscribeCheckoutEvents() {
    _sseReconnectTimer?.cancel();
    _clearanceEventSub?.cancel();
    _clearanceEventSub = ApiService()
        .watchCheckoutClearanceEvents(widget.orderId)
        .listen(
      (eventMap) async {
        if (!mounted || _paymentCompleted) return;
        final evName = (eventMap['_event'] ?? '').toString().toLowerCase();
        if (evName == 'clearance' || isCheckoutClearedResponse(eventMap)) {
          await _verifySseClearanceAndComplete();
        }
      },
      onError: (_) => _scheduleSseReconnect(),
      onDone: () => _scheduleSseReconnect(),
    );
  }

  Future<void> _verifySseClearanceAndComplete() async {
    if (!mounted || _paymentCompleted) return;
    try {
      final fastCheck = await ApiService().checkCheckoutStatus(widget.orderId, live: false);
      if (!mounted || _paymentCompleted) return;
      if (isCheckoutClearedResponse(fastCheck)) {
        _sdk.cancelPendingAttempt(message: '');
        await _completeClearedFlow();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_isBusy && _sdk.hasPendingAttempt) {
        _leftForegroundDuringAttempt = true;
        _resumeRecoveryTimer?.cancel();
      }
      if (_currentView == _CheckoutView.qr && !_paymentCompleted) {
        _leftForegroundInQr = true;
      }
      return;
    }
    if (state == AppLifecycleState.resumed &&
        _leftForegroundInQr &&
        _currentView == _CheckoutView.qr &&
        !_paymentCompleted) {
      _leftForegroundInQr = false;
      if (widget.initialMethods == null) {
        _subscribeCheckoutEvents();
      }
      unawaited(_pollOrderClearanceOnce(live: true));
    }
    if (state == AppLifecycleState.resumed &&
        _leftForegroundDuringAttempt &&
        _isBusy &&
        !_paymentCompleted &&
        _sdk.hasPendingAttempt) {
      _leftForegroundDuringAttempt = false;
      _resumeRecoveryTimer?.cancel();
      _resumeRecoveryTimer = Timer(const Duration(milliseconds: 250), () async {
        if (!mounted || _paymentCompleted || !_isBusy || !_sdk.hasPendingAttempt) {
          return;
        }
        try {
          // 1. Fast Redis/DB check first (~2-15ms if Razorpay webhook already cleared)
          final fastCheck = await ApiService().checkCheckoutStatus(widget.orderId, live: false);
          if (!mounted || _paymentCompleted) return;
          if (isCheckoutClearedResponse(fastCheck)) {
            _sdk.cancelPendingAttempt(message: '');
            await _completeClearedFlow();
            return;
          }

          // 2. Fallback S2S PG verify only if DB/Redis is still pending
          final liveCheck = await ApiService().checkCheckoutStatus(widget.orderId, live: true);
          if (!mounted || _paymentCompleted) return;
          if (isCheckoutClearedResponse(liveCheck)) {
            _sdk.cancelPendingAttempt(message: '');
            await _completeClearedFlow();
            return;
          }
        } catch (_) {}
        if (mounted && !_paymentCompleted && _sdk.hasPendingAttempt) {
          _sdk.cancelPendingAttempt(
            message: 'Payment was cancelled or paused. Select a payment method to try again.',
          );
        }
      });
    }
  }

  void _onCardFieldChanged() {
    final network = RazorpaySdkService.detectCardNetworkLocal(_cardNumberCtrl.text);
    if (mounted) {
      setState(() => _detectedCardNetwork = network);
    }
  }

  Future<void> _loadRazorpayCapabilities({
    List<RazorpayUpiAppOption>? overrideUpiApps,
  }) async {
    try {
      final results = await Future.wait<dynamic>([
        _sdk.fetchSupportedMethods(widget.razorpayKeyId),
        overrideUpiApps != null
            ? Future.value(overrideUpiApps)
            : _sdk.getInstalledUpiApps(widget.razorpayKeyId),
      ]);
      if (!mounted) return;
      final fetchedMethods = results[0] as RazorpayAvailableMethods;
      final installedUpi = results[1] as List<RazorpayUpiAppOption>;
      setState(() {
        _methods = fetchedMethods;
        _upiApps = installedUpi;
        _loadingCapabilities = false;
      });
      if (widget.initialMethods == null &&
          fetchedMethods.upiEnabled &&
          installedUpi.every((a) => !a.upiReady) &&
          _currentView == _CheckoutView.main &&
          !_isBusy &&
          !_paymentCompleted) {
        _qrPrefetchTimer?.cancel();
        _prefetchQrIfIdle();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _upiApps = overrideUpiApps ?? const [];
          _loadingCapabilities = false;
        });
      }
    }
  }

  String get _formattedAmount {
    final val = widget.amount;
    if ((val - val.roundToDouble()).abs() < 0.01) {
      return val.round().toString();
    }
    return val.toStringAsFixed(2);
  }

  String get _description => 'RO Parts Order ${widget.orderId}';

  bool get _isCardFormValid {
    final digits = RazorpaySdkService.digitsOnly(_cardNumberCtrl.text);
    return RazorpaySdkService.luhnCheck(digits) &&
        RazorpaySdkService.isValidExpiry(_expiryCtrl.text) &&
        RazorpaySdkService.isValidCvv(_cvvCtrl.text, _detectedCardNetwork);
  }

  void _switchView(_CheckoutView view) {
    if (_isBusy) return;
    FocusScope.of(context).unfocus();
    if (view == _CheckoutView.qr) {
      _paymentAttempted = true;
      _qrPrefetchTimer?.cancel();
      _startQrTimers();
      _ensureDynamicQrLoaded();
    } else {
      _stopQrTimers();
    }
    setState(() {
      _bannerMessage = null;
      _currentView = view;
    });
  }

  void _regenerateQr() {
    if (_isBusy || _paymentCompleted) return;
    _paymentAttempted = true;
    setState(() {
      _qrExpired = false;
      _qrSecondsLeft = 600;
      _dynamicQrImageUrl = null;
      _qrLoading = false;
      _bannerMessage = null;
    });
    _startQrTimers();
    _ensureDynamicQrLoaded();
  }

  void _prefetchQrIfIdle() {
    if (!mounted ||
        _paymentCompleted ||
        _isBusy ||
        _currentView != _CheckoutView.main ||
        !_methods.upiEnabled ||
        (_dynamicQrImageUrl != null && _dynamicQrImageUrl!.isNotEmpty) ||
        _qrLoading) {
      return;
    }
    _ensureDynamicQrLoaded(silent: true);
  }

  Future<void> _ensureDynamicQrLoaded({bool silent = false}) async {
    if (_qrLoading || (_dynamicQrImageUrl != null && _dynamicQrImageUrl!.isNotEmpty)) {
      return;
    }
    if (!silent && mounted) {
      setState(() => _qrLoading = true);
    } else {
      _qrLoading = true;
    }
    try {
      final qrRes = await ApiService().createRazorpayQr(orderId: widget.orderId);
      if (!mounted) return;
      final url = (qrRes['image_url'] ?? qrRes['qr_url'] ?? '').toString().trim();
      if (qrRes['success'] == true && url.isNotEmpty) {
        if (!_paymentCompleted && mounted) {
          precacheRazorpayQrImage(url, context);
        }
        setState(() {
          _dynamicQrImageUrl = url;
          _qrLoading = false;
        });
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _qrLoading = false);
    } else {
      _qrLoading = false;
    }
  }

  void _startQrTimers() {
    _stopQrTimers();
    _qrPollTick = 0;
    _qrSecondsLeft = 600;
    _qrExpired = false;
    _qrCountdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_qrSecondsLeft > 0) {
        setState(() => _qrSecondsLeft--);
      } else {
        t.cancel();
        _qrPollTimer?.cancel();
        if (mounted && !_qrExpired) {
          setState(() {
            _qrExpired = true;
            _dynamicQrImageUrl = null;
          });
        }
      }
    });

    _qrPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _qrPollTick++;
      _pollOrderClearanceOnce(live: shouldUseLivePgPoll(_qrPollTick));
    });
  }

  void _stopQrTimers() {
    _qrPollTimer?.cancel();
    _qrPollTimer = null;
    _qrCountdownTimer?.cancel();
    _qrCountdownTimer = null;
  }

  Future<void> _pollOrderClearanceOnce({bool userTriggered = false, bool? live}) async {
    if (_paymentCompleted) return;
    if (userTriggered) {
      if (_qrCheckingNow) return;
    } else {
      if (_qrPollInFlight || _qrCheckingNow) return;
    }
    final bool useLive = live ?? userTriggered;
    if (userTriggered) {
      _paymentAttempted = true;
      if (mounted) {
        setState(() {
          _qrCheckingNow = true;
          _bannerMessage = null;
        });
      } else {
        _qrCheckingNow = true;
      }
    } else {
      _qrPollInFlight = true;
    }

    try {
      final res = await ApiService().checkCheckoutStatus(widget.orderId, live: useLive);
      if (!mounted) return;
      if (isCheckoutClearedResponse(res)) {
        await _completeClearedFlow();
        return;
      }
      if (userTriggered) {
        setState(() {
          _bannerIsInfo = true;
          _bannerMessage =
              'Payment not yet reflected. If you already paid, wait a moment and check again.';
        });
      }
    } catch (_) {
      if (userTriggered && mounted) {
        setState(() {
          _bannerIsInfo = false;
          _bannerMessage = 'Unable to reach server right now. Please try again.';
        });
      }
    } finally {
      if (userTriggered) {
        _qrCheckingNow = false;
        if (mounted) {
          setState(() => _qrCheckingNow = false);
        }
      } else {
        _qrPollInFlight = false;
      }
    }
  }

  Future<void> _executeSdkPayment({
    required String loadingLabel,
    required Future<RazorpaySdkOutcome> Function() invokeSdk,
  }) async {
    if (_isBusy || _paymentCompleted) return;
    FocusScope.of(context).unfocus();
    HapticFeedback.lightImpact();

    _paymentAttempted = true;
    _qrPrefetchTimer?.cancel();
    _leftForegroundDuringAttempt = false;
    _resumeRecoveryTimer?.cancel();

    setState(() {
      _isBusy = true;
      _busyMessage = loadingLabel;
      _bannerMessage = null;
    });

    final outcome = await invokeSdk();
    _leftForegroundDuringAttempt = false;
    _resumeRecoveryTimer?.cancel();
    if (!mounted) return;

    if (!outcome.success || (outcome.paymentId ?? '').isEmpty) {
      String resolvedBanner = outcome.errorMessage ??
          'Payment was not completed. Please try another option.';
      bool bannerIsInfo = outcome.isCancelled;

      if (outcome.needsServerStatusCheck &&
          widget.initialMethods == null &&
          !_paymentCompleted) {
        setState(() => _busyMessage = 'Checking bank confirmation...');
        try {
          final liveCheck = await ApiService().checkCheckoutStatus(
            widget.orderId,
            live: true,
          );
          if (!mounted) return;
          if (isCheckoutClearedResponse(liveCheck)) {
            await _completeClearedFlow();
            return;
          }
          final serverReason = extractCheckoutFailureReason(liveCheck);
          if (serverReason != null) {
            resolvedBanner = serverReason;
            bannerIsInfo = false;
          }
        } catch (_) {}
      }

      if (widget.initialMethods == null) {
        _sdk.warmupCheckout();
      }
      setState(() {
        _isBusy = false;
        _busyMessage = null;
        _bannerIsInfo = bannerIsInfo;
        _bannerMessage = resolvedBanner;
      });
      return;
    }

    // Cryptographically verify payment signature on backend before clearing
    setState(() {
      _busyMessage = 'Verifying payment securely...';
    });

    final verified = await _verifyPaymentWithBackend(outcome);
    if (!mounted) return;

    if (verified) {
      await _completeClearedFlow();
      return;
    }

    setState(() {
      _isBusy = false;
      _busyMessage = null;
      _bannerIsInfo = false;
      _bannerMessage =
          'Payment received, awaiting final server confirmation. Tap Verify or wait a second.';
    });
  }

  Future<bool> _verifyPaymentWithBackend(RazorpaySdkOutcome outcome) async {
    final effectiveOrderId = (outcome.orderId != null && outcome.orderId!.isNotEmpty)
        ? outcome.orderId!
        : widget.rzpOrderId;

    final verifyRes = await ApiService().verifyRazorpayPayment(
      orderId: widget.orderId,
      razorpayPaymentId: outcome.paymentId!,
      razorpayOrderId: effectiveOrderId,
      razorpaySignature: outcome.signature ?? '',
    );

    final st = (verifyRes['status'] ?? '').toString().trim().toUpperCase();
    if (verifyRes['paid'] == true ||
        verifyRes['is_cleared'] == true ||
        verifyRes['already_paid'] == true ||
        verifyRes['success'] == true && (st == 'CLEARED' || st == 'PAID' || st.isEmpty)) {
      return true;
    }

    // Cross-check live status once in case webhook settled concurrently
    final liveCheck = await ApiService().checkCheckoutStatus(widget.orderId, live: true);
    return isCheckoutClearedResponse(liveCheck);
  }

  Future<void> _completeClearedFlow() async {
    if (_paymentCompleted) return;
    _paymentCompleted = true;
    _qrPrefetchTimer?.cancel();
    _sseReconnectTimer?.cancel();
    _clearanceEventSub?.cancel();
    _clearanceEventSub = null;
    _stopQrTimers();
    HapticFeedback.mediumImpact();

    if (mounted) {
      Navigator.of(context).pop(true);
    }
    await widget.onPaymentCleared();
  }

  void _triggerUpiIntent({String? packageName, String label = 'UPI app'}) {
    _executeSdkPayment(
      loadingLabel: 'Opening $label...',
      invokeSdk: () => _sdk.submitUpiIntent(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        upiAppPackageName: packageName,
      ),
    );
  }

  void _handleInactiveUpiAppTap(RazorpayUpiAppOption app, String shortName) {
    setState(() {
      _showVpaInput = true;
      _bannerIsInfo = true;
      _bannerMessage =
          'UPI is not activated inside $shortName on this phone yet. Link a bank in $shortName or pay via UPI ID / QR Code.';
    });
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            UpiAppLogo(
              packageOrId: app.packageName,
              displayName: shortName,
              iconBytes: app.iconBytes,
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Activate UPI in $shortName',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          '$shortName is installed on this phone, but its UPI payment handler is inactive (no bank/UPI account activated yet).\n\nYou can open $shortName to set up UPI, or pay right now using UPI ID or QR Code.',
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.4,
            color: Color(0xFF475569),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Use UPI ID / QR'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              _sdk.openUpiAppForSetup(app.packageName);
            },
            child: Text('Open $shortName'),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerUpiCollect() async {
    final vpa = _vpaController.text.trim();
    if (vpa.isEmpty || !vpa.contains('@')) {
      setState(() {
        _bannerIsInfo = false;
        _bannerMessage = 'Enter a valid UPI ID (for example: yourname@okicici).';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _busyMessage = 'Checking UPI ID...';
      _bannerMessage = null;
    });

    final valid = await _sdk.isValidVpa(widget.razorpayKeyId, vpa);
    if (!mounted) return;
    if (!valid) {
      setState(() {
        _isBusy = false;
        _busyMessage = null;
        _bannerIsInfo = false;
        _bannerMessage = 'Could not verify "$vpa". Please check your UPI ID.';
      });
      return;
    }

    setState(() => _isBusy = false);
    await _executeSdkPayment(
      loadingLabel: 'Sending collect request to $vpa...',
      invokeSdk: () => _sdk.submitUpiCollect(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        vpa: vpa,
      ),
    );
  }

  void _triggerPayLater(RazorpayPayLaterOption option) {
    _executeSdkPayment(
      loadingLabel: 'Opening ${option.displayName}...',
      invokeSdk: () => _sdk.submitPayLater(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        provider: option.provider,
      ),
    );
  }

  void _triggerWallet(RazorpayWalletOption wallet) {
    _executeSdkPayment(
      loadingLabel: 'Opening ${wallet.displayName}...',
      invokeSdk: () => _sdk.submitWallet(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        walletCode: wallet.code,
      ),
    );
  }

  void _triggerNetbanking(RazorpayBankOption bank) {
    _executeSdkPayment(
      loadingLabel: 'Connecting to ${bank.name}...',
      invokeSdk: () => _sdk.submitNetbanking(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        bankCode: bank.code,
      ),
    );
  }

  void _triggerCardPayment() {
    if (!_isCardFormValid) {
      setState(() {
        _bannerIsInfo = false;
        _bannerMessage = 'Please check card number, expiry (MM/YY), and CVV.';
      });
      return;
    }

    final expDigits = RazorpaySdkService.digitsOnly(_expiryCtrl.text);
    final mm = expDigits.substring(0, 2);
    final yy = expDigits.substring(2, 4);

    _executeSdkPayment(
      loadingLabel: 'Authorizing card with your bank...',
      invokeSdk: () => _sdk.submitCard(
        keyId: widget.razorpayKeyId,
        rzpOrderId: widget.rzpOrderId,
        amountRupees: widget.amount,
        contact: widget.customerPhone,
        email: widget.customerEmail,
        description: _description,
        cardNumber: _cardNumberCtrl.text,
        expiryMonth: mm,
        expiryYearTwoDigits: yy,
        cvv: _cvvCtrl.text,
        cardHolderName: _cardNameCtrl.text,
      ),
    );
  }

  void _handleCloseTap() {
    if (_isBusy) return;
    if (_currentView != _CheckoutView.main) {
      _switchView(_CheckoutView.main);
      return;
    }
    if (!_paymentCompleted) {
      if (_paymentAttempted) {
        widget.onPaymentFailed?.call('Payment was cancelled before completion.');
      } else {
        widget.onPaymentCancelled?.call();
      }
    }
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: !_isBusy && _currentView == _CheckoutView.main,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          if (!_paymentCompleted) {
            if (_paymentAttempted) {
              widget.onPaymentFailed?.call('Payment was cancelled before completion.');
            } else {
              widget.onPaymentCancelled?.call();
            }
          }
          return;
        }
        if (!_isBusy && _currentView != _CheckoutView.main) {
          _switchView(_CheckoutView.main);
        }
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              constraints: BoxConstraints(maxHeight: screenH * 0.90),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC).withValues(alpha: 0.96),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.9), width: 1.5),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.14),
                    blurRadius: 32,
                    offset: const Offset(0, -8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(),
                  if (_isBusy || _bannerMessage != null) _buildStatusBanner(),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildActiveView(),
                    ),
                  ),
                  _buildFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final bool isSubView = _currentView != _CheckoutView.main;
    final String titleText = switch (_currentView) {
      _CheckoutView.main => 'Drop Purity',
      _CheckoutView.addCard => 'Add New Card',
      _CheckoutView.qr => 'Pay via QR Code',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              InkWell(
                onTap: _isBusy ? null : _handleCloseTap,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    isSubView ? Icons.arrow_back_rounded : Icons.close_rounded,
                    size: 18,
                    color: const Color(0xFF0F172A),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: titleText,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (_currentView == _CheckoutView.main) ...[
                            const TextSpan(
                              text: '  •  ',
                              style: TextStyle(color: Color(0xFF94A3B8), fontWeight: FontWeight.w700),
                            ),
                            TextSpan(
                              text: 'Order #${widget.orderId}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ],
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: _currentView == _CheckoutView.qr
                          ? [
                              ClipOval(
                                child: Image.asset(
                                  'assets/images/app_icon.png',
                                  width: 14,
                                  height: 14,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 5),
                              const Flexible(
                                child: Text(
                                  'ROParts.in Official UPI Checkout',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0B4DBB),
                                  ),
                                ),
                              ),
                            ]
                          : const [
                              RazorpayVerifiedShield(size: 13),
                              SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'Razorpay Trusted Business',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                            ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: Text(
                  '₹$_formattedAmount',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    if (_isBusy) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: const Color(0xFFEFF6FF),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF2563EB),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _busyMessage ?? 'Processing payment...',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1E40AF),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bgColor = _bannerIsInfo ? const Color(0xFFFFFBEB) : const Color(0xFFFEF2F2);
    final borderColor = _bannerIsInfo ? const Color(0xFFFDE68A) : const Color(0xFFFECACA);
    final textColor = _bannerIsInfo ? const Color(0xFF92400E) : const Color(0xFF991B1B);
    final icon = _bannerIsInfo ? Icons.info_outline_rounded : Icons.error_outline_rounded;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _bannerMessage ?? '',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.35,
              ),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _bannerMessage = null),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.close_rounded, size: 16, color: textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveView() {
    switch (_currentView) {
      case _CheckoutView.main:
        return _buildMainView();
      case _CheckoutView.addCard:
        return _buildAddCardView();
      case _CheckoutView.qr:
        return _buildQrView();
    }
  }

  // =========================================================================
  // MAIN CHECKOUT VIEW
  // =========================================================================

  Widget _buildMainView() {
    return SingleChildScrollView(
      key: const ValueKey('rzp_main_view'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section 1: Pay by UPI
          const Row(
            children: [
              UpiHeaderLogo(height: 18),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Pay by UPI',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildUpiCard(),

          // Section 2: Pay Later (dynamically checked via Razorpay /v1/methods)
          if (_loadingCapabilities) ...[
            const SizedBox(height: 18),
            _buildSectionLabel('Pay Later'),
            const SizedBox(height: 8),
            _buildPayLaterSkeleton(),
          ] else if (_methods.payLaterProviders.isNotEmpty) ...[
            const SizedBox(height: 18),
            _buildSectionLabel('Pay Later'),
            const SizedBox(height: 8),
            _buildPayLaterCard(),
          ],

          // Section 3: Credit & Debit Cards
          if (_methods.cardEnabled) ...[
            const SizedBox(height: 18),
            _buildSectionLabel('Credit & Debit Cards'),
            const SizedBox(height: 8),
            _buildCardsEntryCard(),
          ],

          // Section 4: Netbanking
          if (_methods.netbankingBanks.isNotEmpty) ...[
            const SizedBox(height: 18),
            _buildSectionLabel('Netbanking'),
            const SizedBox(height: 8),
            _buildNetbankingCard(),
          ],

          // Section 5: Dynamic Wallets (only enabled wallets from /v1/methods)
          if (!_loadingCapabilities && _methods.wallets.isNotEmpty) ...[
            const SizedBox(height: 18),
            _buildSectionLabel('Wallets'),
            const SizedBox(height: 8),
            _buildWalletsCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFF1E293B),
        ),
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildUpiCard() {
    final apps = _upiApps;
    final activeApps = apps.where((app) => app.upiReady).toList(growable: false);
    final inactiveApps =
        apps.where((app) => !app.upiReady).toList(growable: false);
    final displayApps = activeApps.isNotEmpty ? activeApps : inactiveApps;
    final bool noUpiIntentApps = !_loadingCapabilities && activeApps.isEmpty;
    final initialLower = (widget.initialMethod ?? '').toLowerCase().trim();

    return _glassCard(
      child: Column(
        children: [
          // Row 1: Pay by any UPI app + expandable UPI ID toggle
          InkWell(
            onTap: _isBusy
                ? null
                : () {
                    if (noUpiIntentApps) {
                      setState(() {
                        _showVpaInput = true;
                        _bannerIsInfo = true;
                        _bannerMessage = inactiveApps.isNotEmpty
                            ? 'Installed UPI apps on this phone do not have an active UPI account yet. Link a bank or enter your UPI ID / QR Code.'
                            : 'No UPI app on this device handles instant intent. Enter your UPI ID (@ybl/@okicici) or tap Pay via QR Code.';
                      });
                      return;
                    }
                    _triggerUpiIntent(label: 'UPI app');
                  },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 12, 11),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.phone_android_rounded,
                      size: 20,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pay by any UPI app',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          noUpiIntentApps
                              ? 'No UPI intent app found • Enter UPI ID or Pay via QR'
                              : 'Use any UPI app on the phone to pay',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: Color(0xFF64748B),
                  ),
                ],
              ),
            ),
          ),

          // Compact expandable UPI ID row
          if (_methods.upiCollectEnabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: InkWell(
                      onTap: () => setState(() => _showVpaInput = !_showVpaInput),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showVpaInput
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.alternate_email_rounded,
                              size: 14,
                              color: const Color(0xFF2563EB),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _showVpaInput ? 'Hide UPI ID input' : 'Or pay using UPI ID / VPA',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_showVpaInput) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _vpaController,
                            keyboardType: TextInputType.emailAddress,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F172A),
                            ),
                            decoration: InputDecoration(
                              hintText: 'username@okicici',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(11),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(11),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(11),
                                borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.4),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 40,
                          child: ElevatedButton(
                            onPressed: _isBusy ? null : _triggerUpiCollect,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0F172A),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                            child: const Text(
                              'Verify & Pay',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: ['@ybl', '@okicici', '@oksbi', '@paytm'].map((suffix) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InkWell(
                              onTap: () {
                                final raw = _vpaController.text.trim();
                                final base = raw.contains('@') ? raw.split('@').first : raw;
                                _vpaController.text = '$base$suffix';
                                _vpaController.selection = TextSelection.fromPosition(
                                  TextPosition(offset: _vpaController.text.length),
                                );
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Text(
                                  suffix,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF475569),
                                  ),
                                ),
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
          ],

          // Row 2: Horizontal 1-Tap UPI Tiles (shown when active or installed UPI apps exist)
          if (displayApps.isNotEmpty) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: displayApps.map((app) {
                    final shortName = RazorpaySdkService.canonicalUpiDisplayName(app);
                    final isHighlighted = initialLower.isNotEmpty &&
                        (app.packageName.toLowerCase().contains(initialLower) ||
                            shortName.toLowerCase().contains(initialLower));

                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: BouncingWidget(
                        onTap: _isBusy
                            ? null
                            : () {
                                if (!app.upiReady) {
                                  _handleInactiveUpiAppTap(app, shortName);
                                  return;
                                }
                                _triggerUpiIntent(
                                  packageName: app.packageName,
                                  label: shortName,
                                );
                              },
                        child: Opacity(
                          opacity: app.upiReady ? 1.0 : 0.78,
                          child: Container(
                            width: 82,
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                            decoration: BoxDecoration(
                              color: isHighlighted
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isHighlighted
                                    ? const Color(0xFF2563EB)
                                    : const Color(0xFFE2E8F0),
                                width: isHighlighted ? 1.4 : 1,
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                UpiAppLogo(
                                  packageOrId: app.packageName,
                                  displayName: shortName,
                                  iconBytes: app.iconBytes,
                                  size: 38,
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  shortName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                if (!app.upiReady) ...[
                                  const SizedBox(height: 2),
                                  const Text(
                                    'Setup',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFD97706),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],

          const Divider(height: 1, color: Color(0xFFF1F5F9)),

          // Row 3: Pay via QR Code [NEW]
          InkWell(
            onTap: _isBusy ? null : () => _switchView(_CheckoutView.qr),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 13),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.qr_code_2_rounded,
                      size: 21,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Flexible(
                              child: Text(
                                'Pay via QR Code',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                'NEW',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF15803D),
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Scan and pay with any UPI app',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: Color(0xFF64748B),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayLaterSkeleton() {
    return _glassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 140,
                    height: 13,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 190,
                    height: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPayLaterCard() {
    final providers = _methods.payLaterProviders;
    return _glassCard(
      child: Column(
        children: [
          for (int i = 0; i < providers.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
            InkWell(
              onTap: _isBusy ? null : () => _triggerPayLater(providers[i]),
              borderRadius: BorderRadius.vertical(
                top: i == 0 ? const Radius.circular(18) : Radius.zero,
                bottom: i == providers.length - 1 ? const Radius.circular(18) : Radius.zero,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
                child: Row(
                  children: [
                    PayLaterLogo(provider: providers[i].provider, size: 38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 7,
                            runSpacing: 4,
                            children: [
                              Text(
                                providers[i].displayName,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFFA7F3D0)),
                                ),
                                child: Text(
                                  providers[i].badge,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF047857),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            providers[i].subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 22,
                      color: Color(0xFF64748B),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCardsEntryCard() {
    return _glassCard(
      child: InkWell(
        onTap: _isBusy ? null : () => _switchView(_CheckoutView.addCard),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.add_rounded,
                  size: 22,
                  color: Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add New Card',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Visa, Mastercard, Rupay & more',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const CardNetworkBadge(network: 'visa', height: 20),
              const SizedBox(width: 4),
              const CardNetworkBadge(network: 'mastercard', height: 20),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: Color(0xFF64748B),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetbankingCard() {
    final allBanks = _methods.netbankingBanks;
    final topBanks = allBanks.take(4).toList();
    final filteredBanks = _bankQuery.isEmpty
        ? allBanks
        : allBanks
            .where((b) =>
                b.name.toLowerCase().contains(_bankQuery) ||
                b.code.toLowerCase().contains(_bankQuery))
            .toList();

    return _glassCard(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: topBanks.map((bank) {
                final shortLabel = _shortBankLabel(bank);
                return Expanded(
                  child: BouncingWidget(
                    onTap: _isBusy ? null : () => _triggerNetbanking(bank),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BankBrandLogo(
                            bankCode: bank.code,
                            bankName: bank.name,
                            size: 40,
                          ),
                          const SizedBox(height: 7),
                          Text(
                            shortLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          if (allBanks.length > 4) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            InkWell(
              onTap: () => setState(() => _showAllBanks = !_showAllBanks),
              borderRadius: _showAllBanks
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(bottom: Radius.circular(18)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _showAllBanks
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        _showAllBanks
                            ? 'Hide More Banks'
                            : 'View More Banks (${allBanks.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          if (_showAllBanks) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  TextField(
                    controller: _bankSearchController,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0F172A),
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search bank (e.g. Kotak, Yes, IDFC, SBI...)',
                      hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Color(0xFF64748B)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: const BorderSide(color: Color(0xFF2563EB)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: filteredBanks.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              'No matching banks found',
                              style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: filteredBanks.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                            itemBuilder: (_, idx) {
                              final b = filteredBanks[idx];
                              return InkWell(
                                onTap: _isBusy ? null : () => _triggerNetbanking(b),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                                  child: Row(
                                    children: [
                                      BankBrandLogo(
                                        bankCode: b.code,
                                        bankName: b.name,
                                        size: 32,
                                      ),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Text(
                                          b.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                      ),
                                      const Icon(
                                        Icons.chevron_right_rounded,
                                        size: 19,
                                        color: Color(0xFF94A3B8),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _shortBankLabel(RazorpayBankOption bank) {
    switch (bank.code.toUpperCase()) {
      case 'HDFC':
        return 'HDFC Bank';
      case 'ICIC':
        return 'ICICI Bank';
      case 'SBIN':
        return 'SBI';
      case 'UTIB':
        return 'Axis Bank';
      default:
        return bank.name;
    }
  }

  Widget _buildWalletsCard() {
    final wallets = _methods.wallets;
    return _glassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: wallets.map((w) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: BouncingWidget(
                  onTap: _isBusy ? null : () => _triggerWallet(w),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UpiAppLogo(
                          packageOrId: w.code,
                          displayName: w.displayName,
                          size: 26,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          w.displayName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // IN-SHEET ADD NEW CARD VIEW
  // =========================================================================

  Widget _buildAddCardView() {
    final cardDigits = RazorpaySdkService.digitsOnly(_cardNumberCtrl.text);
    final isCardNumberValid = RazorpaySdkService.luhnCheck(cardDigits);
    final canPay = _isCardFormValid && !_isBusy;

    return SingleChildScrollView(
      key: const ValueKey('rzp_add_card_view'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: _glassCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Supported:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final net in const ['visa', 'mastercard', 'rupay', 'amex'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Opacity(
                                opacity: _detectedCardNetwork.isEmpty ||
                                        _detectedCardNetwork == net
                                    ? 1.0
                                    : 0.35,
                                child: CardNetworkBadge(network: net, height: 22),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Card Number
              const Text(
                'Card Number',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _cardNumberCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(19),
                  _CardNumberFormatter(),
                ],
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF0F172A),
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                decoration: InputDecoration(
                  hintText: '0000 0000 0000 0000',
                  hintStyle: const TextStyle(color: Color(0xFFCBD5E1), letterSpacing: 0.8),
                  prefixIcon: const Icon(
                    Icons.credit_card_rounded,
                    size: 20,
                    color: Color(0xFF475569),
                  ),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_detectedCardNetwork.isNotEmpty)
                          CardNetworkBadge(network: _detectedCardNetwork, height: 22),
                        if (isCardNumberValid) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: Color(0xFF16A34A),
                          ),
                        ],
                      ],
                    ),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: BorderSide(
                      color: isCardNumberValid
                          ? const Color(0xFF86EFAC)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: Color(0xFF0F172A), width: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Expiry & CVV Row
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Expiry Date',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF334155),
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _expiryCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(4),
                            _ExpiryDateFormatter(),
                          ],
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                          decoration: InputDecoration(
                            hintText: 'MM/YY',
                            hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                            filled: true,
                            fillColor: const Color(0xFFF8FAFC),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFF0F172A), width: 1.4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'CVV',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF334155),
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _cvvCtrl,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(
                              _detectedCardNetwork == 'amex' ? 4 : 3,
                            ),
                          ],
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                          decoration: InputDecoration(
                            hintText: _detectedCardNetwork == 'amex' ? '4 digits' : '•••',
                            hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                            suffixIcon: IconButton(
                              onPressed: () => setState(() => _showCvvInfo = !_showCvvInfo),
                              icon: const Icon(
                                Icons.info_outline_rounded,
                                size: 18,
                                color: Color(0xFF64748B),
                              ),
                              tooltip: 'CVV info',
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF8FAFC),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(13),
                              borderSide: const BorderSide(color: Color(0xFF0F172A), width: 1.4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              if (_showCvvInfo) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'CVV is the 3-digit security code printed on the back of your card (4 digits on the front for American Express).',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF1E40AF), height: 1.35),
                  ),
                ),
              ],

              const SizedBox(height: 14),

              // Cardholder Name
              const Text(
                'Name on Card (Optional)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _cardNameCtrl,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
                decoration: InputDecoration(
                  hintText: 'Cardholder name',
                  hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: Color(0xFF0F172A), width: 1.4),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Full-width pill CTA button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: canPay ? _triggerCardPayment : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    disabledBackgroundColor: const Color(0xFFBAC7D5),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          'Pay ₹$_formattedAmount',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Center(
                child: Text(
                  'Your card goes straight to Razorpay PCI-DSS 3DS authentication.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // IN-SHEET PAY VIA QR CODE VIEW
  // =========================================================================

  Widget _buildQrRetryBox({String? upiQrData, double size = 236}) {
    if (upiQrData != null && upiQrData.isNotEmpty) {
      return QrImageView(
        data: upiQrData,
        version: QrVersions.auto,
        size: size,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Color(0xFF0F172A),
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Color(0xFF0F172A),
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_2_rounded, size: 36, color: Color(0xFF64748B)),
              const SizedBox(height: 8),
              const Text(
                'Dynamic UPI QR unavailable right now. Tap Retry or use UPI ID / Card / Netbanking.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _qrLoading ? null : () => _ensureDynamicQrLoaded(),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text(
                  'Retry QR',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrView() {
    final String? upiQrData =
        (widget.upiUri != null && widget.upiUri!.trim().isNotEmpty)
            ? widget.upiUri!.trim()
            : null;
    final bool showOpenUpiButton =
        !_loadingCapabilities && _upiApps.any((app) => app.upiReady);

    final mins = (_qrSecondsLeft ~/ 60).toString().padLeft(2, '0');
    final secs = (_qrSecondsLeft % 60).toString().padLeft(2, '0');

    return SingleChildScrollView(
      key: const ValueKey('rzp_qr_view'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: _glassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/ropartslogo.png',
                    height: 20,
                    fit: BoxFit.contain,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _qrExpired ? const Color(0xFFFEF3C7) : const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _qrExpired ? const Color(0xFFFDE68A) : const Color(0xFFBBF7D0),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _qrExpired ? Icons.timer_off_outlined : Icons.timer_outlined,
                      size: 14,
                      color: _qrExpired ? const Color(0xFFB45309) : const Color(0xFF15803D),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        _qrExpired
                            ? 'QR Expired • Generate a fresh QR to pay'
                            : 'QR valid for $mins:$secs • Auto-verifying',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _qrExpired ? const Color(0xFFB45309) : const Color(0xFF15803D),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final double frameSide = constraints.maxWidth.clamp(210.0, 286.0);
                  final double innerQrSide = frameSide - 24.0;
                  return Container(
                    width: frameSide,
                    height: frameSide,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFDBEAFE),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0B4DBB).withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _qrExpired
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.qr_code_2_rounded,
                                size: 46,
                                color: Color(0xFF94A3B8),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'QR code expired for security',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF334155),
                                ),
                              ),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                onPressed: _regenerateQr,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0F172A),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.refresh_rounded, size: 16),
                                label: const Text(
                                  'Generate New QR',
                                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                                ),
                              ),
                            ],
                          )
                        : _qrLoading
                            ? const CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Color(0xFF0F172A),
                              )
                            : (_dynamicQrImageUrl != null && _dynamicQrImageUrl!.isNotEmpty)
                                ? _ZoomedRazorpayQr(
                                    imageUrl: _dynamicQrImageUrl!,
                                    size: innerQrSide,
                                    fallback: _buildQrRetryBox(
                                      upiQrData: upiQrData,
                                      size: innerQrSide,
                                    ),
                                  )
                                : _buildQrRetryBox(
                                    upiQrData: upiQrData,
                                    size: innerQrSide,
                                  ),
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                'Scan with any UPI app to pay ₹$_formattedAmount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'GPay • PhonePe • Paytm • BHIM • Any Bank App',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: _qrCheckingNow
                      ? null
                      : () => _pollOrderClearanceOnce(userTriggered: true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: _qrCheckingNow
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.verified_outlined, size: 18),
                  label: Text(
                    _qrCheckingNow ? 'Checking payment...' : "I've Paid • Verify Status",
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (showOpenUpiButton) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _isBusy ? null : () => _triggerUpiIntent(label: 'UPI app'),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text(
                    'Or open a UPI app on this phone',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final sysBottomPad =
        bottomInset > 0 ? 0.0 : MediaQuery.of(context).viewPadding.bottom;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16, 9, 16, 12 + sysBottomPad),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: _currentView == _CheckoutView.qr
            ? [
                const Icon(Icons.lock_rounded, size: 13, color: Color(0xFF64748B)),
                const SizedBox(width: 5),
                const Flexible(
                  child: Text(
                    'Secured UPI Checkout •',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                ClipOval(
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 14,
                    height: 14,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 4),
                const Flexible(
                  child: Text(
                    'ROParts.in',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0B4DBB),
                    ),
                  ),
                ),
              ]
            : const [
                Icon(Icons.lock_rounded, size: 13, color: Color(0xFF64748B)),
                SizedBox(width: 5),
                Flexible(
                  child: Text(
                    'Secured by',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(width: 5),
                RazorpayVerifiedShield(size: 13),
                SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Razorpay',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF072654),
                    ),
                  ),
                ),
              ],
      ),
    );
  }
}

class _CardNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(digits[i]);
    }
    final formatted = buf.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Exact fallback QR crop rectangle matching Razorpay's standard UPI QR poster layout
/// (`https://rzp.io/i/...`), isolating the centered square QR away from Razorpay banners.
@visibleForTesting
Rect fallbackRazorpayQrCropRect(double width, double height) {
  if (width <= 0 || height <= 0) return Rect.zero;
  final double side = width * 0.59;
  return Rect.fromCenter(
    center: Offset(width * 0.50, height * 0.516),
    width: side,
    height: side,
  );
}

/// Detects the black-on-white UPI QR module bounding square inside Razorpay's hosted
/// `image_url` PNG (`rawRgba` bytes) so it renders full-size cleanly without Razorpay
/// header/footer artwork, falling back to [fallbackRazorpayQrCropRect] if uncertain.
@visibleForTesting
Rect detectRazorpayQrCropRect(Uint8List rgbaBytes, int width, int height) {
  if (width <= 0 || height <= 0 || rgbaBytes.length < width * height * 4) {
    return fallbackRazorpayQrCropRect(width.toDouble(), height.toDouble());
  }

  final int x0 = (width * 0.16).floor().clamp(0, width - 1);
  final int x1 = (width * 0.84).ceil().clamp(x0, width - 1);
  final int y0 = (height * 0.30).floor().clamp(0, height - 1);
  final int y1 = (height * 0.72).ceil().clamp(y0, height - 1);

  final int minDarkPerRow = math.max(3, (width * 0.04).round());
  final int maxGap = math.max(1, (height * 0.006).round());

  int bestStart = -1;
  int bestEnd = -1;
  int curStart = -1;
  int gap = 0;

  bool isDarkNeutral(int x, int y) {
    final int idx = (y * width + x) * 4;
    final int r = rgbaBytes[idx];
    final int g = rgbaBytes[idx + 1];
    final int b = rgbaBytes[idx + 2];
    final int a = rgbaBytes[idx + 3];
    return a > 128 && r < 110 && g < 110 && b < 110;
  }

  for (int y = y0; y <= y1; y++) {
    int darkCount = 0;
    for (int x = x0; x <= x1; x++) {
      if (isDarkNeutral(x, y)) {
        darkCount++;
      }
    }
    if (darkCount >= minDarkPerRow) {
      curStart = curStart == -1 ? y : curStart;
      gap = 0;
      if (bestEnd == -1 || (y - curStart) > (bestEnd - bestStart)) {
        bestStart = curStart;
        bestEnd = y;
      }
    } else {
      gap++;
      if (gap > maxGap) {
        curStart = -1;
      }
    }
  }

  if (bestStart == -1) {
    return fallbackRazorpayQrCropRect(width.toDouble(), height.toDouble());
  }

  final int bandH = (bestEnd - bestStart) + 1;
  if (bandH < width * 0.35) {
    return fallbackRazorpayQrCropRect(width.toDouble(), height.toDouble());
  }

  final int minDarkPerCol = math.max(2, (bandH * 0.04).round());
  int qL = x1 + 1;
  int qR = x0 - 1;
  for (int x = x0; x <= x1; x++) {
    int colDark = 0;
    for (int y = bestStart; y <= bestEnd; y++) {
      if (isDarkNeutral(x, y)) {
        colDark++;
      }
    }
    if (colDark >= minDarkPerCol) {
      if (x < qL) qL = x;
      if (x > qR) qR = x;
    }
  }

  final int qW = (qR - qL) + 1;
  if (qL > qR ||
      qW < width * 0.36 ||
      qW > width * 0.78 ||
      (qW - bandH).abs() > math.max(4, (bandH * 0.16).round())) {
    return fallbackRazorpayQrCropRect(width.toDouble(), height.toDouble());
  }

  final double side = math.max(qW, bandH).toDouble();
  final double pad = (side * 0.015).clamp(0.5, 4.0);
  final double cx = (qL + qR + 1) / 2.0;
  final double cy = (bestStart + bestEnd + 1) / 2.0;
  final double half = (side / 2.0) + pad;

  return Rect.fromLTRB(
    (cx - half).clamp(0.0, width - 1.0),
    (cy - half).clamp(0.0, height - 1.0),
    (cx + half).clamp(1.0, width.toDouble()),
    (cy + half).clamp(1.0, height.toDouble()),
  );
}

/// Returns true for every 3rd tick (~3s on 1s timer, aligned with CBM's 2.5s PG throttle)
/// or manual user verification.
@visibleForTesting
bool shouldUseLivePgPoll(int pollTick, {bool userTriggered = false}) {
  if (userTriggered) return true;
  return pollTick > 0 && pollTick % 3 == 0;
}

/// Shared clearance status check used across polling, lifecycle recovery, and SSE wakeup.
@visibleForTesting
bool isCheckoutClearedResponse(Map<String, dynamic> res) {
  final st = (res['status'] ?? '').toString().trim().toUpperCase();
  return res['paid'] == true ||
      res['is_cleared'] == true ||
      res['already_paid'] == true ||
      st == 'CLEARED' ||
      st == 'PAID' ||
      st == 'COMPLETED' ||
      st == 'SETTLED';
}

/// Extracts an explicit bank/gateway failure reason from `/v1/checkout/status?live=true`.
@visibleForTesting
String? extractCheckoutFailureReason(Map<String, dynamic> res) {
  final st = (res['status'] ?? '').toString().trim().toUpperCase();
  final bool isFailureState =
      res['is_failed'] == true || st == 'FAILED' || st == 'EXPIRED';
  if (!isFailureState) return null;

  final session = res['session'];
  final raw = (res['failure_reason'] ??
          (session is Map ? session['failure_reason'] : null) ??
          '')
      .toString()
      .trim();
  if (raw.isEmpty ||
      raw.toUpperCase() == 'PENDING' ||
      raw.toUpperCase() == 'UNKNOWN') {
    return null;
  }
  return raw;
}

final Map<String, Rect> _razorpayQrCropCache = <String, Rect>{};

@visibleForTesting
Rect? cachedRazorpayQrCropForUrl(String imageUrl) => _razorpayQrCropCache[imageUrl];

@visibleForTesting
void cacheRazorpayQrCropForUrl(String imageUrl, Rect rect) {
  if (_razorpayQrCropCache.length >= 24 && !_razorpayQrCropCache.containsKey(imageUrl)) {
    _razorpayQrCropCache.remove(_razorpayQrCropCache.keys.first);
  }
  _razorpayQrCropCache[imageUrl] = rect;
}

/// Downloads and caches both the Flutter image and the detected QR crop rect ahead of tab switch.
void precacheRazorpayQrImage(String imageUrl, BuildContext context) {
  final cleanUrl = imageUrl.trim();
  if (cleanUrl.isEmpty) return;
  final provider = NetworkImage(cleanUrl);
  precacheImage(provider, context);
  if (_razorpayQrCropCache.containsKey(cleanUrl)) return;

  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) async {
      stream.removeListener(listener);
      try {
        final byteData =
            await info.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final Rect rect = byteData != null
            ? detectRazorpayQrCropRect(
                byteData.buffer.asUint8List(),
                info.image.width,
                info.image.height,
              )
            : fallbackRazorpayQrCropRect(
                info.image.width.toDouble(),
                info.image.height.toDouble(),
              );
        cacheRazorpayQrCropForUrl(cleanUrl, rect);
      } catch (_) {
      } finally {
        info.dispose();
      }
    },
    onError: (_, __) {
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
}

class _ZoomedRazorpayQr extends StatefulWidget {
  final String imageUrl;
  final double size;
  final Widget fallback;

  const _ZoomedRazorpayQr({
    required this.imageUrl,
    required this.size,
    required this.fallback,
  });

  @override
  State<_ZoomedRazorpayQr> createState() => _ZoomedRazorpayQrState();
}

class _ZoomedRazorpayQrState extends State<_ZoomedRazorpayQr> {
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;
  ImageInfo? _imageInfo;
  Rect? _cropRect;
  bool _hadError = false;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ZoomedRazorpayQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _resolveImage();
    }
  }

  void _stopListening() {
    if (_imageStream != null && _streamListener != null) {
      _imageStream!.removeListener(_streamListener!);
    }
    _imageStream = null;
    _streamListener = null;
  }

  void _resolveImage() {
    _stopListening();
    _loadToken++;
    final int currentToken = _loadToken;

    final prevInfo = _imageInfo;
    _imageInfo = null;
    _cropRect = cachedRazorpayQrCropForUrl(widget.imageUrl);
    _hadError = false;
    prevInfo?.dispose();

    final provider = NetworkImage(widget.imageUrl);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) async {
        Rect? detected = cachedRazorpayQrCropForUrl(widget.imageUrl);
        if (detected == null) {
          detected = fallbackRazorpayQrCropRect(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          try {
            final byteData =
                await info.image.toByteData(format: ui.ImageByteFormat.rawRgba);
            if (byteData != null) {
              detected = detectRazorpayQrCropRect(
                byteData.buffer.asUint8List(),
                info.image.width,
                info.image.height,
              );
              cacheRazorpayQrCropForUrl(widget.imageUrl, detected);
            }
          } catch (_) {}
        }

        if (!mounted || currentToken != _loadToken) {
          info.dispose();
          return;
        }
        final old = _imageInfo;
        setState(() {
          _imageInfo = info;
          _cropRect = detected;
          _hadError = false;
        });
        old?.dispose();
      },
      onError: (_, __) {
      _stopListening();
        if (!mounted || currentToken != _loadToken) return;
        setState(() => _hadError = true);
      },
    );

    _imageStream = stream;
    _streamListener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _loadToken++;
    _stopListening();
    _imageInfo?.dispose();
    _imageInfo = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hadError) {
      return widget.fallback;
    }
    final info = _imageInfo;
    final crop = _cropRect;
    if (info == null || crop == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: Color(0xFF0F172A),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _QrCropPainter(
          image: info.image,
          srcRect: crop,
        ),
      ),
    );
  }
}

class _QrCropPainter extends CustomPainter {
  final ui.Image image;
  final Rect srcRect;

  const _QrCropPainter({
    required this.image,
    required this.srcRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;
    canvas.drawImageRect(image, srcRect, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _QrCropPainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.srcRect != srcRect;
  }
}

class _ExpiryDateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final clamped = digits.length > 4 ? digits.substring(0, 4) : digits;
    final formatted = clamped.length > 2
        ? '${clamped.substring(0, 2)}/${clamped.substring(2)}'
        : clamped;
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
