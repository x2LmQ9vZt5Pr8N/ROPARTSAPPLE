import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:razorpay_flutter_customui/razorpay_flutter_customui.dart';
import '../utils/phone_normalizer.dart';
import 'api_service.dart';

const MethodChannel _upiBridgeChannel =
    MethodChannel('in.roparts.roparts/upi_apps');

class RazorpayBankOption {
  final String code;
  final String name;

  const RazorpayBankOption({required this.code, required this.name});
}

class RazorpayPayLaterOption {
  final String provider;
  final String displayName;
  final String subtitle;
  final String badge;

  const RazorpayPayLaterOption({
    required this.provider,
    required this.displayName,
    required this.subtitle,
    required this.badge,
  });
}

class RazorpayWalletOption {
  final String code;
  final String displayName;

  const RazorpayWalletOption({required this.code, required this.displayName});
}

class RazorpayUpiAppOption {
  final String packageName;
  final String appName;
  final Uint8List? iconBytes;
  final bool upiReady;

  const RazorpayUpiAppOption({
    required this.packageName,
    required this.appName,
    this.iconBytes,
    this.upiReady = true,
  });
}

class RazorpayAvailableMethods {
  final bool upiEnabled;
  final bool upiIntentEnabled;
  final bool upiCollectEnabled;
  final bool cardEnabled;
  final bool netbankingEnabled;
  final List<RazorpayPayLaterOption> payLaterProviders;
  final List<RazorpayWalletOption> wallets;
  final List<RazorpayBankOption> netbankingBanks;
  final DateTime fetchedAt;

  const RazorpayAvailableMethods({
    required this.upiEnabled,
    required this.upiIntentEnabled,
    required this.upiCollectEnabled,
    required this.cardEnabled,
    required this.netbankingEnabled,
    required this.payLaterProviders,
    required this.wallets,
    required this.netbankingBanks,
    required this.fetchedAt,
  });

  factory RazorpayAvailableMethods.minimalFallback() {
    return RazorpayAvailableMethods(
      upiEnabled: true,
      upiIntentEnabled: true,
      upiCollectEnabled: true,
      cardEnabled: true,
      netbankingEnabled: true,
      payLaterProviders: const [],
      wallets: const [],
      netbankingBanks: const [
        RazorpayBankOption(code: 'HDFC', name: 'HDFC Bank'),
        RazorpayBankOption(code: 'ICIC', name: 'ICICI Bank'),
        RazorpayBankOption(code: 'SBIN', name: 'State Bank of India'),
        RazorpayBankOption(code: 'UTIB', name: 'Axis Bank'),
      ],
      fetchedAt: DateTime.now(),
    );
  }
}

class RazorpaySdkOutcome {
  final bool success;
  final bool isCancelled;
  final bool needsServerStatusCheck;
  final String? paymentId;
  final String? orderId;
  final String? signature;
  final String? errorMessage;

  const RazorpaySdkOutcome({
    required this.success,
    this.isCancelled = false,
    this.needsServerStatusCheck = false,
    this.paymentId,
    this.orderId,
    this.signature,
    this.errorMessage,
  });
}

/// Official Razorpay Custom UI (`razorpay_flutter_customui: 1.5.1`) wrapper.
/// Dynamically queries Razorpay `/v1/methods` + installed UPI apps and submits
/// native Custom UI payments with strict event envelope normalization.
class RazorpaySdkService {
  RazorpaySdkService._();
  static final RazorpaySdkService instance = RazorpaySdkService._();

  static const Duration _methodsCacheTtl = Duration(minutes: 10);

  static const List<String> featuredBankCodes = ['HDFC', 'ICIC', 'SBIN', 'UTIB'];

  static const Map<String, ({String name, String subtitle, String badge})> _payLaterCatalog = {
    'amazonpay': (
      name: 'Amazon Pay Later',
      subtitle: 'Pay next month or EMI via Amazon Pay',
      badge: '0% extra • Instant',
    ),
    'lazypay': (
      name: 'LazyPay',
      subtitle: '1-tap instant credit, settle every 15 days',
      badge: '0% extra • Instant',
    ),
    'simpl': (
      name: 'Simpl Pay Later',
      subtitle: 'Pay later in 1 click at zero cost',
      badge: '0% extra • Instant',
    ),
    'icic': (
      name: 'ICICI PayLater',
      subtitle: 'Zero-fee 45-day ICICI Bank credit line',
      badge: 'Instant',
    ),
    'hdfc': (
      name: 'FlexiPay by HDFC Bank',
      subtitle: 'Buy now, pay later in 15-30 days',
      badge: 'Instant',
    ),
    'epaylater': (
      name: 'ePayLater',
      subtitle: '14-day interest-free credit',
      badge: 'Instant',
    ),
    'kotak': (
      name: 'Kotak PayLater',
      subtitle: 'Instant digital credit line',
      badge: 'Instant',
    ),
  };

  static const Map<String, String> _walletLabels = {
    'amazonpay': 'Amazon Pay Balance',
    'phonepe': 'PhonePe Wallet',
    'mobikwik': 'MobiKwik',
    'payzapp': 'HDFC PayZapp',
    'airtelmoney': 'Airtel Payments Bank',
    'olamoney': 'Ola Money',
    'freecharge': 'Freecharge',
    'jiomoney': 'JioMoney',
  };

  static const List<String> _preferredUpiOrder = [
    'com.google.android.apps.nbu.paisa.user',
    'tez',
    'gpay',
    'com.phonepe.app',
    'phonepe',
    'net.one97.paytm',
    'paytmmp',
    'paytm',
    'in.org.npci.upiapp',
    'bhim',
    'com.dreamplug.androidapp',
    'credpay',
    'cred',
    'in.amazon.mShop.android.shopping',
    'amazonpay',
    'com.whatsapp',
    'whatsapp',
  ];

  Razorpay? _razorpay;
  bool _listenersAttached = false;
  String? _initializedKey;
  final Map<String, RazorpayAvailableMethods> _methodsCache = {};
  Completer<RazorpaySdkOutcome>? _activeCompleter;

  void _ensureListeners(String keyId) {
    final cleanKey = keyId.trim();
    if (_razorpay == null) {
      _razorpay = Razorpay();
      _listenersAttached = false;
    }
    if (!_listenersAttached) {
      _razorpay!.on(
        Razorpay.EVENT_PAYMENT_SUCCESS,
        _onPaymentSuccess,
        unwrapData: false,
      );
      _razorpay!.on(
        Razorpay.EVENT_PAYMENT_ERROR,
        _onPaymentError,
        unwrapData: false,
      );
      _listenersAttached = true;
    }
    if (cleanKey.isNotEmpty && _initializedKey != cleanKey) {
      // Note: In razorpay_flutter_customui 1.5.1 Android native plugin,
      // initilizeSDK does not reply to MethodChannel.Result — never await it.
      _razorpay!.initilizeSDK(cleanKey);
      _initializedKey = cleanKey;
    }
  }

  /// Unwraps Android `{type, data}` envelope OR iOS flat map safely.
  Map<String, dynamic> _unwrapResponse(dynamic raw) {
    if (raw is! Map) return const {};
    final outer = Map<String, dynamic>.from(raw);
    final inner = outer['data'];
    if (inner is Map) {
      return Map<String, dynamic>.from(inner);
    }
    return outer;
  }

  RazorpaySdkOutcome _outcomeFromSuccessMap(Map<String, dynamic> map) {
    final paymentId = (map['razorpay_payment_id'] ?? '').toString().trim();
    final orderId = (map['razorpay_order_id'] ?? '').toString().trim();
    final signature = (map['razorpay_signature'] ?? '').toString().trim();

    debugPrint('[RazorpaySDK] Payment success event: paymentId=$paymentId orderId=$orderId');

    return RazorpaySdkOutcome(
      success: paymentId.isNotEmpty,
      paymentId: paymentId,
      orderId: orderId,
      signature: signature,
      errorMessage: paymentId.isEmpty
          ? 'Payment reference was missing from gateway callback.'
          : null,
    );
  }

  RazorpaySdkOutcome _outcomeFromErrorMap(
    Map<String, dynamic> map, {
    required bool treatZeroAsCancelled,
  }) {
    final rawCode = map['code'];
    final int? code = rawCode is int ? rawCode : int.tryParse(rawCode?.toString() ?? '');
    final rawMessage = (map['message'] ??
            map['description'] ??
            (map['error'] is String ? map['error'] : null) ??
            '')
        .toString()
        .trim();
    final extractedDesc = _extractSdkErrorDescription(rawMessage);
    final lowerMsg = (extractedDesc ?? rawMessage).toLowerCase();

    // BaseRazorpay emits PAYMENT_ERROR (5 -> 100 in RazorpayDelegate) with
    // "You may have canceled the payment or the payment would have timed out"
    // on empty `{}` WebView callbacks (including post-OTP bank declines).
    final bool isAmbiguousCallback =
        lowerMsg.contains('may have canceled') ||
        lowerMsg.contains('may have cancelled') ||
        lowerMsg.contains('would have timed out');

    final bool hasExplicitCancelPhrase =
        !isAmbiguousCallback &&
        (lowerMsg.contains('cancelled by user') ||
            lowerMsg.contains('canceled by user') ||
            lowerMsg.contains('user pressed back') ||
            lowerMsg.contains('closed by user') ||
            lowerMsg.contains('payment aborted') ||
            lowerMsg.contains('payment cancelled') ||
            lowerMsg.contains('payment canceled') ||
            lowerMsg.contains('dismiss'));

    // BaseRazorpay.PAYMENT_CANCELED == 0; Dart Razorpay.PAYMENT_CANCELLED == 2.
    final bool isCancelled =
        !isAmbiguousCallback &&
        ((treatZeroAsCancelled && code == 0) ||
            code == 2 ||
            code == Razorpay.PAYMENT_CANCELLED ||
            hasExplicitCancelPhrase);

    // Query backend S2S status when an attempted payment ends in an ambiguous
    // callback or gateway decline, skipping pre-submit local validation errors.
    final bool needsServerStatusCheck =
        isAmbiguousCallback ||
        (!isCancelled && code != -1 && code != 1 && code != 3);

    final friendly = _sanitizeSdkErrorMessage(
      extractedDesc ?? rawMessage,
      isCancelled: isCancelled,
      isAmbiguousCallback: isAmbiguousCallback,
    );
    debugPrint(
      '[RazorpaySDK] Payment error event: code=$code cancelled=$isCancelled checkServer=$needsServerStatusCheck msg=$rawMessage',
    );

    return RazorpaySdkOutcome(
      success: false,
      isCancelled: isCancelled,
      needsServerStatusCheck: needsServerStatusCheck,
      errorMessage: friendly,
    );
  }

  void _onPaymentSuccess(dynamic raw) {
    final outcome = _outcomeFromSuccessMap(_unwrapResponse(raw));

    final completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(outcome);
    }
  }

  void _onPaymentError(dynamic raw) {
    final outcome = parseSdkErrorResponse(_unwrapResponse(raw));

    final completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(outcome);
    }
  }

  String? _extractSdkErrorDescription(String raw) {
    if (!(raw.startsWith('{') || raw.contains('"description"') || raw.contains('"reason"'))) {
      return null;
    }
    try {
      final parsed = json.decode(raw);
      if (parsed is Map) {
        final errObj = parsed['error'] is Map ? parsed['error'] as Map : parsed;
        final desc = (errObj['description'] ?? errObj['reason'] ?? '').toString().trim();
        if (desc.isNotEmpty && !desc.contains('{')) {
          return desc;
        }
      }
    } catch (_) {}
    return null;
  }

  String _sanitizeSdkErrorMessage(
    String raw, {
    required bool isCancelled,
    bool isAmbiguousCallback = false,
  }) {
    if (isCancelled) {
      return 'Payment was cancelled. Select any payment method below to try again.';
    }
    if (isAmbiguousCallback) {
      return 'Payment was not completed or timed out. Please retry or choose another method.';
    }
    if (raw.isEmpty) {
      return 'Payment could not be completed. Please try again or use another method.';
    }

    // Razorpay sometimes returns JSON strings like `{"error":{"description":"..."}}`
    if (raw.startsWith('{') || raw.contains('"description"')) {
      final desc = _extractSdkErrorDescription(raw);
      if (desc != null) {
        return desc;
      }
      return 'Bank or gateway declined this request. Please retry or switch to UPI.';
    }

    final lower = raw.toLowerCase();
    if (lower.contains('network') || lower.contains('timeout')) {
      return 'Network unstable during payment. Please check your connection and retry.';
    }
    if (lower.contains('invalid vpa')) {
      return 'Entered UPI ID is invalid or inactive. Please check and retry.';
    }
    if (lower.contains('undefined') || lower.contains('exception')) {
      return 'Payment could not be processed. Please try another option.';
    }
    return raw;
  }

  /// Dynamically fetch enabled payment methods, PayLater providers, Wallets, and Netbanking banks
  /// directly from Razorpay `/v1/methods?key_id=...` (plus native `getPaymentMethods()` fallback).
  Future<RazorpayAvailableMethods> fetchSupportedMethods(
    String keyId, {
    bool forceRefresh = false,
  }) async {
    final cleanKey = keyId.trim();
    if (cleanKey.isEmpty) {
      return RazorpayAvailableMethods.minimalFallback();
    }

    final cached = _methodsCache[cleanKey];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _methodsCacheTtl) {
      return cached;
    }

    Map<String, dynamic>? rawMethods;
    try {
      final res = await ApiService.client
          .get(Uri.parse('https://api.razorpay.com/v1/methods?key_id=${Uri.encodeComponent(cleanKey)}'))
          .timeout(const Duration(seconds: 7));
      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final decoded = json.decode(res.body);
        if (decoded is Map) {
          rawMethods = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (e) {
      debugPrint('[RazorpaySDK] /v1/methods HTTP fetch failed: $e');
    }

    if (rawMethods == null) {
      try {
        final proxyRes = await ApiService.client
            .get(Uri.parse(
                '${ApiService.cbmBaseUrl}/v1/checkout/razorpay/methods?key_id=${Uri.encodeComponent(cleanKey)}'))
            .timeout(const Duration(seconds: 6));
        if (proxyRes.statusCode == 200 && proxyRes.body.isNotEmpty) {
          final decoded = json.decode(proxyRes.body);
          if (decoded is Map && decoded['methods'] is Map) {
            rawMethods = Map<String, dynamic>.from(decoded['methods'] as Map);
          }
        }
      } catch (e) {
        debugPrint('[RazorpaySDK] proxy /v1/checkout/razorpay/methods fallback failed: $e');
      }
    }

    if (rawMethods == null) {
      try {
        _ensureListeners(cleanKey);
        final sdkMap = await _razorpay!
            .getPaymentMethods()
            .timeout(const Duration(seconds: 4));
        if (sdkMap.isNotEmpty) {
          rawMethods = Map<String, dynamic>.from(sdkMap);
        }
      } catch (e) {
        debugPrint('[RazorpaySDK] getPaymentMethods() fallback failed: $e');
      }
    }

    if (rawMethods == null) {
      return cached ?? RazorpayAvailableMethods.minimalFallback();
    }

    final parsed = parseMethodsPayload(rawMethods);
    _methodsCache[cleanKey] = parsed;
    return parsed;
  }

  @visibleForTesting
  RazorpayAvailableMethods parseMethodsPayload(Map<String, dynamic> raw) {
    final upiEnabled = raw['upi'] != false;
    final upiType = raw['upi_type'] is Map ? raw['upi_type'] as Map : const {};
    final upiIntentEnabled =
        raw['upi_intent'] == true || upiType['intent'] == 1 || upiType['intent'] == true;
    final upiCollectEnabled =
        upiEnabled && (upiType.isEmpty || upiType['collect'] == 1 || upiType['collect'] == true);
    final cardEnabled = raw['card'] != false &&
        (raw['credit_card'] != false || raw['debit_card'] != false);

    // Strictly include PayLater providers where Razorpay returns `true`
    final List<RazorpayPayLaterOption> payLaterList = [];
    final rawPayLater = raw['paylater'];
    if (rawPayLater is Map) {
      for (final entry in rawPayLater.entries) {
        if (entry.value == true) {
          final code = entry.key.toString().trim().toLowerCase();
          final meta = _payLaterCatalog[code];
          payLaterList.add(
            RazorpayPayLaterOption(
              provider: code,
              displayName: meta?.name ?? _humanizeCode(code, suffix: 'Pay Later'),
              subtitle: meta?.subtitle ?? 'Buy now, pay later via Razorpay',
              badge: meta?.badge ?? 'Instant',
            ),
          );
        }
      }
    }

    // Strictly include Wallets where Razorpay returns `true`
    final List<RazorpayWalletOption> walletList = [];
    final rawWallets = raw['wallet'];
    if (rawWallets is Map) {
      for (final entry in rawWallets.entries) {
        if (entry.value == true) {
          final code = entry.key.toString().trim().toLowerCase();
          walletList.add(
            RazorpayWalletOption(
              code: code,
              displayName: _walletLabels[code] ?? _humanizeCode(code),
            ),
          );
        }
      }
    }

    // Parse active Netbanking banks (skipping null entries like KKBK: null)
    final List<RazorpayBankOption> banks = [];
    final rawNb = raw['netbanking'];
    if (rawNb is Map) {
      for (final entry in rawNb.entries) {
        final bankCode = entry.key.toString().trim();
        final bankName = entry.value?.toString().trim() ?? '';
        if (bankCode.isNotEmpty && bankName.isNotEmpty && bankName != 'null') {
          banks.add(RazorpayBankOption(code: bankCode, name: bankName));
        }
      }
    }
    banks.sort((a, b) {
      final idxA = featuredBankCodes.indexOf(a.code);
      final idxB = featuredBankCodes.indexOf(b.code);
      if (idxA != -1 && idxB != -1) return idxA.compareTo(idxB);
      if (idxA != -1) return -1;
      if (idxB != -1) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return RazorpayAvailableMethods(
      upiEnabled: upiEnabled,
      upiIntentEnabled: upiIntentEnabled,
      upiCollectEnabled: upiCollectEnabled,
      cardEnabled: cardEnabled,
      netbankingEnabled: banks.isNotEmpty,
      payLaterProviders: payLaterList,
      wallets: walletList,
      netbankingBanks: banks,
      fetchedAt: DateTime.now(),
    );
  }

  static String _humanizeCode(String code, {String? suffix}) {
    if (code.isEmpty) return suffix ?? 'Pay Later';
    final titled = code[0].toUpperCase() + code.substring(1);
    return suffix != null ? '$titled $suffix' : titled;
  }

  @visibleForTesting
  List<RazorpayUpiAppOption> parseNativeUpiApps(List<dynamic> rawList) {
    final Map<String, RazorpayUpiAppOption> byPkg = {};
    for (final item in rawList) {
      if (item is Map) {
        final pkg = (item['packageName'] ?? '').toString().trim();
        final name = (item['appName'] ?? pkg).toString().trim();
        final bool upiReady = item['upiReady'] != false;
        final dynamic rawIcon = item['iconBytes'];
        Uint8List? iconBytes;
        if (rawIcon is Uint8List) {
          iconBytes = rawIcon;
        } else if (rawIcon is List) {
          iconBytes = Uint8List.fromList(rawIcon.cast<int>());
        }
        if (pkg.isNotEmpty) {
          byPkg[pkg] = RazorpayUpiAppOption(
            packageName: pkg,
            appName: name.isNotEmpty ? name : pkg,
            iconBytes: iconBytes,
            upiReady: upiReady,
          );
        }
      }
    }
    return _sortUpiApps(byPkg.values);
  }

  List<RazorpayUpiAppOption> _sortUpiApps(Iterable<RazorpayUpiAppOption> apps) {
    final sorted = apps.toList();
    sorted.sort((a, b) {
      if (a.upiReady != b.upiReady) {
        return a.upiReady ? -1 : 1;
      }
      final idxA = _preferredUpiOrder.indexOf(a.packageName);
      final idxB = _preferredUpiOrder.indexOf(b.packageName);
      if (idxA != -1 && idxB != -1) return idxA.compareTo(idxB);
      if (idxA != -1) return -1;
      if (idxB != -1) return 1;
      return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
    });
    return sorted;
  }

  @visibleForTesting
  RazorpaySdkOutcome parseSdkErrorResponse(Map<String, dynamic> map) {
    return _outcomeFromErrorMap(map, treatZeroAsCancelled: true);
  }

  @visibleForTesting
  RazorpaySdkOutcome parseSeamlessUpiResponse(Map<String, dynamic> map) {
    if (map['status'] == 'success') {
      return _outcomeFromSuccessMap(map);
    }
    return _outcomeFromErrorMap(map, treatZeroAsCancelled: false);
  }

  /// Queries installed UPI apps natively via Android PackageManager (preserving
  /// genuine device launcher icons and enabled `upi://pay` readiness), falling back
  /// to `razorpay_flutter_customui` if unavailable.
  Future<List<RazorpayUpiAppOption>> getInstalledUpiApps(String keyId) async {
    final Map<String, RazorpayUpiAppOption> byPkg = {};
    bool nativeSucceeded = false;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final rawList = await _upiBridgeChannel
            .invokeListMethod<dynamic>('getInstalledUpiApps')
            .timeout(const Duration(seconds: 2));
        nativeSucceeded = true;
        if (rawList != null) {
          return parseNativeUpiApps(rawList);
        }
      } catch (e) {
        debugPrint('[RazorpaySDK] native getInstalledUpiApps fallback: $e');
      }
    }

    if (!nativeSucceeded) {
      try {
        _ensureListeners(keyId);
        final dynamic raw = await _razorpay!
            .getAppsWhichSupportUpi()
            .timeout(const Duration(seconds: 2));
        return parseSdkUpiApps(raw);
      } catch (e) {
        debugPrint('[RazorpaySDK] getAppsWhichSupportUpi failed: $e');
      }
    }

    return _sortUpiApps(byPkg.values);
  }

  /// Parses `razorpay_flutter_customui`'s cross-platform `getAppsWhichSupportUpi` output:
  /// Android returns a `Map` or `List<Map>`, whereas iOS often returns `List<String>` schemes (`tez`, `phonepe`, `paytm`, ...).
  @visibleForTesting
  List<RazorpayUpiAppOption> parseSdkUpiApps(dynamic raw) {
    final Map<String, RazorpayUpiAppOption> byPkg = {};
    void addNormalized(String rawId, String? rawName) {
      final pkg = rawId.replaceAll(RegExp(r':/*$'), '').trim();
      if (pkg.isEmpty) return;
      final cleanName = (rawName ?? '').trim();
      final display = cleanName.isNotEmpty
          ? cleanName
          : canonicalUpiDisplayName(
              RazorpayUpiAppOption(packageName: pkg, appName: pkg),
            );
      byPkg[pkg] = RazorpayUpiAppOption(packageName: pkg, appName: display);
    }

    if (raw is Map) {
      for (final entry in raw.entries) {
        addNormalized(entry.key.toString(), entry.value?.toString());
      }
    } else if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final pkg = (item['packageName'] ??
                  item['package_name'] ??
                  item['app_scheme'] ??
                  item['scheme'] ??
                  item['appName'] ??
                  item['name'] ??
                  '')
              .toString();
          final name = (item['appName'] ?? item['name'] ?? '').toString();
          addNormalized(pkg, name);
        } else if (item != null) {
          addNormalized(item.toString(), null);
        }
      }
    }

    return _sortUpiApps(byPkg.values);
  }

  /// Opens an installed UPI app directly so the user can activate/link a bank account.
  Future<bool> openUpiAppForSetup(String packageName) async {
    if (kIsWeb || !Platform.isAndroid || packageName.trim().isEmpty) {
      return false;
    }
    try {
      final opened = await _upiBridgeChannel.invokeMethod<bool>(
        'openApp',
        {'packageName': packageName.trim()},
      );
      return opened ?? false;
    } catch (e) {
      debugPrint('[RazorpaySDK] openUpiAppForSetup failed: $e');
      return false;
    }
  }

  /// Pre-allocates a blank 1x1 hidden WebView before user taps a UPI app.
  Future<void> warmupCheckout() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _upiBridgeChannel.invokeMethod<bool>('warmupCheckout');
    } catch (_) {}
  }

  /// Releases any unused pre-warmed blank WebView when checkout sheet closes.
  Future<void> releaseCheckoutWarmup() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _upiBridgeChannel.invokeMethod<bool>('releaseCheckoutWarmup');
    } catch (_) {}
  }

  static String canonicalUpiDisplayName(RazorpayUpiAppOption app) {
    final pkg = app.packageName.toLowerCase();
    final name = app.appName.toLowerCase();
    if (pkg.contains('paisa') ||
        pkg == 'tez' ||
        pkg == 'gpay' ||
        name.contains('google pay') ||
        name == 'tez' ||
        name == 'gpay') {
      return 'GPay';
    }
    if (pkg.contains('phonepe') || pkg == 'ppe' || name.contains('phonepe')) {
      return 'PhonePe';
    }
    if (pkg.contains('paytm') || name.contains('paytm')) return 'Paytm';
    if (pkg.contains('npci') || pkg.contains('bhim') || name.contains('bhim')) {
      return 'BHIM';
    }
    if (pkg.contains('dreamplug') || pkg.contains('cred') || name == 'cred') {
      return 'CRED';
    }
    if (pkg.contains('amazon') || name.contains('amazon')) return 'Amazon Pay';
    if (pkg.contains('whatsapp') || name.contains('whatsapp')) return 'WhatsApp';
    return app.appName;
  }

  // ---- Card & VPA Validation Helpers ----

  static String digitsOnly(String input) => input.replaceAll(RegExp(r'\D'), '');

  static String detectCardNetworkLocal(String rawNumber) {
    final digits = digitsOnly(rawNumber);
    if (digits.isEmpty) return '';
    if (digits.startsWith('4')) return 'visa';
    if (RegExp(r'^3[47]').hasMatch(digits)) return 'amex';
    // RuPay common BIN prefixes before generic 5/6 checks
    if (RegExp(r'^(607|608|6521|6522|508[5-9]|81|82)').hasMatch(digits)) {
      return 'rupay';
    }
    if (RegExp(r'^5[1-5]').hasMatch(digits)) return 'mastercard';
    if (digits.length >= 4) {
      final first4 = int.tryParse(digits.substring(0, 4)) ?? 0;
      if (first4 >= 2221 && first4 <= 2720) return 'mastercard';
    }
    if (digits.startsWith('60') || digits.startsWith('65')) return 'rupay';
    if (RegExp(r'^(30[0-5]|36|38)').hasMatch(digits)) return 'diners';
    return '';
  }

  static bool luhnCheck(String rawNumber) {
    final digits = digitsOnly(rawNumber);
    if (digits.length < 13 || digits.length > 19) return false;
    int sum = 0;
    bool alternate = false;
    for (int i = digits.length - 1; i >= 0; i--) {
      int n = digits.codeUnitAt(i) - 48;
      if (alternate) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
      alternate = !alternate;
    }
    return sum % 10 == 0;
  }

  static bool isValidExpiry(String rawExpiry) {
    final clean = digitsOnly(rawExpiry);
    if (clean.length != 4) return false;
    final mm = int.tryParse(clean.substring(0, 2)) ?? 0;
    final yy = int.tryParse(clean.substring(2, 4)) ?? -1;
    if (mm < 1 || mm > 12 || yy < 0) return false;
    final now = DateTime.now();
    final fullYear = 2000 + yy;
    if (fullYear < now.year) return false;
    if (fullYear == now.year && mm < now.month) return false;
    return true;
  }

  static bool isValidCvv(String rawCvv, String network) {
    final clean = digitsOnly(rawCvv);
    if (network == 'amex') return clean.length == 4;
    if (network.isEmpty) return clean.length == 3 || clean.length == 4;
    return clean.length == 3;
  }

  Future<bool> isValidVpa(String keyId, String vpa) async {
    final clean = vpa.trim();
    if (!PhoneNormalizer.isValidUpiVpaFormat(clean)) {
      return false;
    }
    try {
      _ensureListeners(keyId);
      final res = await _razorpay!
          .isValidVpa(clean)
          .timeout(const Duration(seconds: 4));
      if (res['success'] == true || res['vpa'] != null) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[RazorpaySDK] isValidVpa check failed: $e');
      return false;
    }
  }

  // ---- Payment Submission Builders ----

  Map<String, dynamic> _baseOptions({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
  }) {
    final cleanPhone = _sanitizePhone(contact);
    final cleanEmail = sanitizeEmail(email);
    final int amountPaise = (amountRupees * 100).round().clamp(100, 1000000000);

    return {
      'key': keyId.trim(),
      'amount': amountPaise,
      'currency': 'INR',
      'order_id': rzpOrderId.trim(),
      if (cleanPhone.isNotEmpty) 'contact': cleanPhone,
      'email': cleanEmail,
      'description': description,
    };
  }

  static String _sanitizePhone(String raw) {
    return PhoneNormalizer.cleanPhone10(raw);
  }

  static String sanitizeEmail(String raw) {
    final clean = raw.trim();
    if (clean.contains('@') && clean.contains('.')) return clean;
    return 'void@razorpay.com';
  }

  Future<RazorpaySdkOutcome> _submitInternal({
    required String keyId,
    required Map<String, dynamic> options,
  }) async {
    // Cancel any stale suspended completer
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.complete(
        const RazorpaySdkOutcome(
          success: false,
          isCancelled: true,
          errorMessage: 'Previous payment attempt was superseded.',
        ),
      );
    }

    _ensureListeners(keyId);
    final completer = Completer<RazorpaySdkOutcome>();
    _activeCompleter = completer;

    try {
      debugPrint('[RazorpaySDK] submit method=${options['method']} flow=${options['_[flow]']} order=${options['order_id']}');
      _razorpay!.submit(options);
    } catch (e) {
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
      return RazorpaySdkOutcome(
        success: false,
        errorMessage: _sanitizeSdkErrorMessage(e.toString(), isCancelled: false),
      );
    }

    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        if (identical(_activeCompleter, completer)) {
          _activeCompleter = null;
        }
        return const RazorpaySdkOutcome(
          success: false,
          needsServerStatusCheck: true,
          errorMessage: 'Payment response timed out. Checking status with server...',
        );
      },
    );
  }

  /// Launch UPI Intent (direct seamless host on Android when targeting an installed UPI app,
  /// or standard chooser fallback when `upiAppPackageName` is null).
  Future<RazorpaySdkOutcome> submitUpiIntent({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    String? upiAppPackageName,
  }) async {
    final targetPkg = upiAppPackageName?.trim();
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'upi',
      '_[flow]': 'intent',
      if (targetPkg != null && targetPkg.isNotEmpty)
        'upi_app_package_name': targetPkg,
    };

    if (!kIsWeb &&
        Platform.isAndroid &&
        targetPkg != null &&
        targetPkg.isNotEmpty) {
      try {
        debugPrint(
            '[RazorpaySDK] seamless UPI intent package=$targetPkg order=${options['order_id']}');
        final raw = await _upiBridgeChannel.invokeMapMethod<String, dynamic>(
          'submitSeamlessUpiIntent',
          {
            'keyId': keyId.trim(),
            'options': options,
          },
        );
        if (raw != null) {
          return parseSeamlessUpiResponse(Map<String, dynamic>.from(raw));
        }
      } on MissingPluginException {
        debugPrint('[RazorpaySDK] seamless channel unavailable; using standard SDK');
      } catch (e) {
        debugPrint('[RazorpaySDK] seamless intent error: $e');
      }
    }

    return _submitInternal(keyId: keyId, options: options);
  }

  /// Launch UPI Collect via VPA ID (e.g. `name@ybl`).
  Future<RazorpaySdkOutcome> submitUpiCollect({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    required String vpa,
  }) {
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'upi',
      '_[flow]': 'collect',
      'vpa': vpa.trim(),
    };
    return _submitInternal(keyId: keyId, options: options);
  }

  /// Launch Card payment via Razorpay Custom UI (handles 3DS / OTP natively for PCI compliance).
  Future<RazorpaySdkOutcome> submitCard({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    required String cardNumber,
    required String expiryMonth,
    required String expiryYearTwoDigits,
    required String cvv,
    String? cardHolderName,
  }) {
    final holder = (cardHolderName ?? '').trim();
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'card',
      'card[number]': digitsOnly(cardNumber),
      'card[expiry_month]': expiryMonth.padLeft(2, '0'),
      'card[expiry_year]': expiryYearTwoDigits.padLeft(2, '0'),
      'card[cvv]': digitsOnly(cvv),
      'card[name]': holder.isNotEmpty ? holder : 'RO Parts Customer',
    };
    return _submitInternal(keyId: keyId, options: options);
  }

  /// Launch Netbanking flow for bank code (`HDFC`, `ICIC`, `SBIN`, `UTIB`, etc.).
  Future<RazorpaySdkOutcome> submitNetbanking({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    required String bankCode,
  }) {
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'netbanking',
      'bank': bankCode.trim(),
    };
    return _submitInternal(keyId: keyId, options: options);
  }

  /// Launch PayLater flow for Razorpay-verified provider (`amazonpay`, etc.).
  Future<RazorpaySdkOutcome> submitPayLater({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    required String provider,
  }) {
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'paylater',
      'provider': provider.trim(),
    };
    return _submitInternal(keyId: keyId, options: options);
  }

  /// Launch Wallet flow for Razorpay-verified wallet (`amazonpay`, `phonepe`, etc.).
  Future<RazorpaySdkOutcome> submitWallet({
    required String keyId,
    required String rzpOrderId,
    required double amountRupees,
    required String contact,
    required String email,
    required String description,
    required String walletCode,
  }) {
    final options = {
      ..._baseOptions(
        keyId: keyId,
        rzpOrderId: rzpOrderId,
        amountRupees: amountRupees,
        contact: contact,
        email: email,
        description: description,
      ),
      'method': 'wallet',
      'wallet': walletCode.trim(),
    };
    return _submitInternal(keyId: keyId, options: options);
  }

  bool get hasPendingAttempt =>
      _activeCompleter != null && !(_activeCompleter!.isCompleted);

  void cancelPendingAttempt({String message = 'Checkout closed.'}) {
    final completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        RazorpaySdkOutcome(
          success: false,
          isCancelled: true,
          errorMessage: message,
        ),
      );
    }
  }

  void dispose() {
    cancelPendingAttempt();
    _razorpay?.clear();
    _razorpay = null;
    _initializedKey = null;
  }
}
