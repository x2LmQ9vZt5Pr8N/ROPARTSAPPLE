import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/product.dart';
import '../models/cart_item.dart';
import '../models/user_address.dart';
import '../models/coupon.dart';
import '../services/coupon_registry.dart';
import '../services/api_service.dart';
import '../services/local_cache_vault.dart';
import '../services/fcm_service.dart';
import '../utils/phone_normalizer.dart';

class CartState extends ChangeNotifier {
  Future<String?>? _refreshInFlight;
  DateTime? _lastActiveClaimAt;

  CartState() {
    ApiService.setUnauthorizedRefreshHandler(_refreshAccessTokenOnUnauthorized);
  }

  static bool _isAuthRejectionResponse(Map<String, dynamic> res) {
    final status = res['statusCode'];
    if (status == 401 || status == 403) return true;
    final code = (res['code'] ?? '').toString().trim().toUpperCase();
    final err = (res['error'] ?? '').toString().trim().toUpperCase();
    final errCode = (res['error_code'] ?? '').toString().trim().toUpperCase();
    return code == 'SESSION_LIMIT_EXCEEDED' ||
        err == 'SESSION_EVICTED' ||
        err == 'REFRESH_REVOKED' ||
        err == 'CUSTOMER_BLOCKED' ||
        errCode == 'CUSTOMER_BLOCKED';
  }

  Future<String?> _refreshAccessTokenOnUnauthorized() async {
    if (_refreshInFlight != null) return _refreshInFlight;
    final ref = _refreshToken;
    if (!_isLoggedIn || ref == null || ref.isEmpty) return null;

    final completer = Completer<String?>();
    _refreshInFlight = completer.future;
    try {
      final res = await ApiService().refreshToken(ref);
      final newToken = (res['token'] ?? res['access_token'])?.toString().trim();
      if (res['success'] == true && newToken != null && newToken.isNotEmpty) {
        _authToken = newToken;
        _refreshToken = (res['refresh_token'] as String?) ?? ref;
        final expSec = (res['expires_in'] as int?) ?? (86400 * 30);
        _tokenExpiresAt = DateTime.now().millisecondsSinceEpoch + (expSec * 1000);
        ApiService.setAuthToken(newToken);
        await _persistAuth();
        completer.complete(newToken);
        return newToken;
      }
      if (_isAuthRejectionResponse(res)) {
        unawaited(logout(notifyServer: false));
      }
      completer.complete(null);
      return null;
    } catch (e) {
      debugPrint('[CartState] Unauthorized token refresh failed: $e');
      completer.complete(null);
      return null;
    } finally {
      _refreshInFlight = null;
    }
  }

  final Map<String, CartItem> _items = {};
  String _activeSegment = 'domestic';
  String _deliveryPincode = '560034';
  String _deliveryCity = 'Bengaluru';

  Coupon? _appliedCoupon;
  double? _serverCouponDiscount;
  List<Coupon> _availableCoupons = [];
  bool _isLoadingCoupons = false;
  bool _isValidatingCoupon = false;
  String? _couponError;

  static const int maxSavedAddresses = 8;

  final List<UserAddress> _addresses = [];
  UserAddress? _activeAddress;

  // Dynamic Pan-India Courier & COD Policy (fetched live from CBM Admin system_settings)
  bool _shippingQuoteLoaded = false;
  bool _shippingEnabled = false;
  int _standardCourierCharge = 0;
  int _freeShippingMinOrder = 0;
  String _shippingThresholdBasis = 'BEFORE_COUPON';

  // 7-Day Resumable Online Checkout Draft State (ONLINE_ECOM only)
  Timer? _draftSyncDebounce;
  Map<String, dynamic>? _activeRecoveryDraft;
  bool _isHydratingDraft = false;
  bool _codEnabled = true;
  int _maxCodOrderAmount = 15000;
  int _shippingQuoteSeq = 0;

  // Unified User Profile & Auth
  String _userName = '';
  String _userPhone = '';
  String? _authToken;
  String? _refreshToken;
  int? _tokenExpiresAt;
  String? _customerId;
  String? _userEmail;
  bool _isLoggedIn = false;
  bool _isSessionInitialized = false;

  // Background Pre-Warmed GPS Location
  Position? _cachedLocation;
  Position? get cachedLocation => _cachedLocation;

  // Persistence managed by LocalCacheVault (strictly namespaced cust_<id>_*)

  // Items, Addresses and Profile Getters
  Map<String, CartItem> get items => Map.unmodifiable(_items);
  String get activeSegment => _activeSegment;
  String get deliveryPincode => _deliveryPincode;
  String get deliveryCity => _deliveryCity;
  List<UserAddress> get addresses => List.unmodifiable(_addresses);
  List<UserAddress> get doorstepAddresses => addresses;
  List<UserAddress> get onlineShippingAddresses => addresses;
  UserAddress? get activeAddress => _activeAddress ?? (_addresses.isNotEmpty ? _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first) : null);
  UserAddress? get activeOnlineAddress => activeAddress;
  bool get canAddAddress => _addresses.length < maxSavedAddresses;

  String get userName => _userName;
  String get userPhone => _userPhone;
  String? get authToken => _authToken;
  String? get refreshToken => _refreshToken;
  int? get tokenExpiresAt => _tokenExpiresAt;
  String? get customerId => _customerId;
  String? get userEmail => _userEmail;
  bool get isLoggedIn => _isLoggedIn;
  bool get isSessionInitialized => _isSessionInitialized;

  /// Initializes persistent 30-day session and addresses from LocalCacheVault
  Future<void> initSession() async {
    try {
      // 1. Enforce strict boundary check on boot and attempt to load active session
      final session = await LocalCacheVault.loadActiveSession();

      if (session != null) {
        final token = session['token'] as String;
        final refToken = session['refresh_token'] as String?;
        final phone = session['phone'] as String;
        final name = session['name'] as String;
        final custId = session['customer_id'] as String;
        final email = session['email'] as String?;
        final expiresAt = session['expires_at'] as int?;

        final now = DateTime.now().millisecondsSinceEpoch;
        final hasExpired = expiresAt != null && expiresAt <= now;
        final isNearExpiry = expiresAt != null && expiresAt <= (now + 86400000 * 2);

        if (hasExpired && (refToken == null || refToken.isEmpty)) {
          await logout();
          return;
        }

        if ((hasExpired || isNearExpiry) && refToken != null && refToken.isNotEmpty) {
          try {
            final res = await ApiService().refreshToken(refToken);
            if (res['success'] == true && res['token'] != null) {
              _authToken = res['token'];
              _refreshToken = res['refresh_token'] ?? refToken;
              final expSec = (res['expires_in'] as int?) ?? (86400 * 30);
              _tokenExpiresAt = now + (expSec * 1000);
              _userName = name;
              _userPhone = phone;
              _customerId = custId;
              _userEmail = email;
              _isLoggedIn = true;
              ApiService.setAuthToken(_authToken);
              await _persistAuth();
            } else if (hasExpired || _isAuthRejectionResponse(res)) {
              await logout(notifyServer: false);
              return;
            } else {
              _authToken = token;
              _refreshToken = refToken;
              _tokenExpiresAt = expiresAt;
              _userName = name;
              _userPhone = phone;
              _customerId = custId;
              _userEmail = email;
              _isLoggedIn = true;
              ApiService.setAuthToken(_authToken);
            }
          } catch (e) {
            debugPrint('[CartState] Error during token refresh: $e');
            if (hasExpired) {
              await logout();
              return;
            }
            _authToken = token;
            _refreshToken = refToken;
            _tokenExpiresAt = expiresAt;
            _userName = name;
            _userPhone = phone;
            _customerId = custId;
            _userEmail = email;
            _isLoggedIn = true;
            ApiService.setAuthToken(_authToken);
          }
        } else {
          _authToken = token;
          _refreshToken = refToken;
          _tokenExpiresAt = expiresAt;
          _userName = name;
          _userPhone = phone;
          _customerId = custId;
          _userEmail = email;
          _isLoggedIn = true;
          ApiService.setAuthToken(_authToken);
        }

        // 2. Load Customer's partitioned addresses
        _addresses.clear();
        _addresses.addAll(await LocalCacheVault.loadAddresses(custId));
        final activeId = await LocalCacheVault.loadActiveAddressId(custId);
        if (_addresses.isNotEmpty) {
          _activeAddress = _addresses.firstWhere(
            (a) => a.id == activeId,
            orElse: () => _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first),
          );
        }

        // 3. Load Customer's delivery location
        final loc = await LocalCacheVault.loadDeliveryLocation(custId);
        _deliveryPincode = _activeAddress?.pincode ?? loc['pincode']!;
        _deliveryCity = _activeAddress?.city ?? loc['city']!;

        unawaited(loadActiveOnlineDraft());
      } else {
        // No valid session: Enforce zero-personal-data guest mode
        _isLoggedIn = false;
        _addresses.clear();
        _activeAddress = null;
        await LocalCacheVault.enforceBoundary(null);
        final loc = await LocalCacheVault.loadDeliveryLocation(null);
        _deliveryPincode = loc['pincode']!;
        _deliveryCity = loc['city']!;
      }
    } catch (e) {
      debugPrint('[CartState] initSession failed: $e');
    } finally {
      _isSessionInitialized = true;
      notifyListeners();
      if (_isLoggedIn) {
        unawaited(syncAddressesFromServer());
        unawaited(syncProfileFromServer());
        unawaited(_registerFcmToken());
      }
      unawaited(prewarmLocation());
    }
  }

  Future<void> _persistAuth() async {
    try {
      if (_isLoggedIn && _authToken != null && _customerId != null && _customerId!.isNotEmpty) {
        await LocalCacheVault.saveCustomerSession(
          customerId: _customerId!,
          name: _userName,
          phone: _userPhone,
          email: _userEmail,
          token: _authToken,
          refreshToken: _refreshToken,
          expiresAt: _tokenExpiresAt,
        );
      } else {
        if (_customerId != null && _customerId!.isNotEmpty) {
          await LocalCacheVault.purgeCustomer(_customerId!);
        } else {
          await LocalCacheVault.purgeAllPersonalData();
        }
      }
    } catch (e) {
      debugPrint('[CartState] _persistAuth failed: $e');
    }
  }

  Future<void> _persistAddresses() async {
    try {
      if (_customerId != null && _customerId!.isNotEmpty) {
        await LocalCacheVault.saveAddresses(
          customerId: _customerId!,
          addresses: _addresses,
          activeAddressId: _activeAddress?.id,
          pincode: _deliveryPincode,
          city: _deliveryCity,
        );
      } else {
        await LocalCacheVault.saveDeliveryLocation(null, _deliveryPincode, _deliveryCity);
      }
    } catch (e) {
      debugPrint('[CartState] _persistAddresses failed: $e');
    }
  }

  Future<void> login({
    required String name,
    required String phone,
    String? token,
    String? refreshToken,
    String? customerId,
    String? email,
    String? defaultAddress,
    String? defaultPincode,
    int? expiresInSeconds,
  }) async {
    _userName = name.trim();
    _userPhone = phone.trim();
    _authToken = token;
    _refreshToken = refreshToken;
    _customerId = customerId;
    _userEmail = email;
    _isLoggedIn = true;
    ApiService.setAuthToken(_authToken);

    // 30-day default login duration
    final expSec = expiresInSeconds ?? (86400 * 30);
    _tokenExpiresAt = DateTime.now().millisecondsSinceEpoch + (expSec * 1000);

    if (defaultPincode != null && defaultPincode.isNotEmpty) {
      _deliveryPincode = defaultPincode;
    }

    // Load any existing addresses for this customer from vault
    if (customerId != null && customerId.isNotEmpty) {
      _addresses.clear();
      _addresses.addAll(await LocalCacheVault.loadAddresses(customerId));
      final activeId = await LocalCacheVault.loadActiveAddressId(customerId);
      if (_addresses.isNotEmpty) {
        _activeAddress = _addresses.firstWhere(
          (a) => a.id == activeId,
          orElse: () => _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first),
        );
      }
    }


    await _persistAddresses();
    await _persistAuth();
    notifyListeners();
    unawaited(syncAddressesFromServer());
    unawaited(syncProfileFromServer());
    unawaited(loadActiveOnlineDraft());
    unawaited(prewarmLocation());
    unawaited(FcmService().syncBroadcastTopic(subscribed: true));
    unawaited(_registerFcmToken());
  }

  String get _fcmPlatform {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    return 'android';
  }

  Future<void> claimActivePushDeviceIfLoggedIn({bool bypassThrottle = false}) async {
    if (!_isLoggedIn || _customerId == null || _customerId!.isEmpty) return;
    final now = DateTime.now();
    if (!bypassThrottle &&
        _lastActiveClaimAt != null &&
        now.difference(_lastActiveClaimAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastActiveClaimAt = now;
    try {
      await FcmService().syncCatalogTokenWithAuth(
        customerId: _customerId,
        force: true,
      );
    } catch (e) {
      debugPrint('[CartState] claimActivePushDeviceIfLoggedIn notice: $e');
    }
  }

  Future<void> _registerFcmToken([String? tokenOverride]) async {
    try {
      await FcmService().initialize(
        onTokenRefresh: (newToken) {
          if (_isLoggedIn) unawaited(_registerFcmToken(newToken));
        },
      );
      final custId = _customerId;
      if (custId != null && custId.isNotEmpty) {
        await FcmService().syncCatalogTokenWithAuth(
          customerId: custId,
          force: tokenOverride != null,
        );
      }
    } catch (e) {
      debugPrint('[CartState] _registerFcmToken notice: $e');
    }
  }

  static final RegExp _notificationEmailRegex = RegExp(
    r'^[^\s@<>()[\]\\,;:"\x27]+@[^\s@<>()[\]\\,;:"\x27]+\.[^\s@<>()[\]\\,;:"\x27]{2,}$',
  );

  static bool isValidNotificationEmail(String email) {
    final trimmed = email.trim();
    return trimmed.isNotEmpty && trimmed.length <= 160 && _notificationEmailRegex.hasMatch(trimmed);
  }

  Future<void> updateName(String name) async {
    _userName = name.trim();
    await _persistAuth();
    notifyListeners();
  }

  Future<void> syncProfileFromServer() async {
    if (!isLoggedIn) return;
    final res = await ApiService().getCustomerProfile(
      customerId: customerId,
      phone: userPhone,
    );
    if (res['success'] != true) return;
    final profile = res['profile'];
    if (profile is! Map) return;
    final serverEmail = profile['email']?.toString().trim();
    final serverName = profile['full_name']?.toString().trim();
    bool changed = false;
    if (serverEmail != null && serverEmail.isNotEmpty && serverEmail != _userEmail) {
      _userEmail = serverEmail;
      changed = true;
    }
    if (serverName != null &&
        serverName.isNotEmpty &&
        serverName.toLowerCase() != 'valued customer' &&
        (userName.isEmpty || userName.toLowerCase() == 'valued customer')) {
      _userName = serverName;
      changed = true;
    }
    if (changed) {
      if (_isLoggedIn && _authToken != null && _customerId != null && _customerId!.isNotEmpty) {
        await _persistAuth();
      }
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> updateUserEmail(String rawEmail, {String? orderNumber}) async {
    final cleaned = rawEmail.trim().toLowerCase();
    if (cleaned.isNotEmpty && !isValidNotificationEmail(cleaned)) {
      return {
        'success': false,
        'error': 'Please enter a valid email address.',
      };
    }

    if (isLoggedIn && userPhone.trim().isNotEmpty) {
      final res = await ApiService().updateProfile(
        phone: userPhone.trim(),
        fullName: userName.trim().isNotEmpty ? userName.trim() : 'Valued Customer',
        customerId: customerId,
        email: cleaned,
        orderNumber: orderNumber,
      );
      if (res['success'] != true) {
        return res;
      }
      final serverEmail = (res['customer'] is Map) ? res['customer']['email']?.toString().trim() : null;
      _userEmail = (serverEmail != null && serverEmail.isNotEmpty) ? serverEmail : (cleaned.isEmpty ? null : cleaned);
      if (_isLoggedIn && _authToken != null && _customerId != null && _customerId!.isNotEmpty) {
        await _persistAuth();
      }
      notifyListeners();
      return res;
    }

    _userEmail = cleaned.isEmpty ? null : cleaned;
    notifyListeners();
    return {'success': true, 'email': _userEmail};
  }

  Future<void> logout({bool notifyServer = true}) async {
    final ref = _refreshToken;
    final cid = _customerId;
    final fcmToken = FcmService().fcmToken;

    if (notifyServer && fcmToken != null && cid != null && cid.isNotEmpty) {
      try {
        await ApiService().unregisterDeviceToken(entityId: cid, fcmToken: fcmToken);
      } catch (e) {
        debugPrint('[CartState] unregisterDeviceToken error: $e');
      }
      await ApiService().clearRegisteredFcmPair();
      unawaited(FcmService().syncCatalogTokenWithAuth(customerId: null, force: true));
    } else if (cid != null && cid.isNotEmpty) {
      await ApiService().clearRegisteredFcmPair();
    }
    unawaited(FcmService().syncBroadcastTopic(subscribed: false));

    if (notifyServer && ref != null && ref.isNotEmpty) {
      try {
        await ApiService().logout(ref);
      } catch (e) {
        debugPrint('[CartState] backend logout error: $e');
      }
    }

    ApiService.setAuthToken(null);
    _draftSyncDebounce?.cancel();
    _draftSyncDebounce = null;
    _activeRecoveryDraft = null;
    _userName = '';
    _userPhone = '';
    _authToken = null;
    _refreshToken = null;
    _tokenExpiresAt = null;
    _customerId = null;
    _userEmail = null;
    _isLoggedIn = false;
    _addresses.clear();
    _activeAddress = null;
    _items.clear();
    _appliedCoupon = null;
    _serverCouponDiscount = null;
    _couponError = null;

    if (cid != null && cid.isNotEmpty) {
      await LocalCacheVault.purgeCustomer(cid);
    } else {
      await LocalCacheVault.purgeAllPersonalData();
    }

    notifyListeners();
  }

  Coupon? get appliedCoupon => _appliedCoupon;
  List<Coupon> get availableCoupons => List.unmodifiable(_availableCoupons);
  bool get isLoadingCoupons => _isLoadingCoupons;
  bool get isValidatingCoupon => _isValidatingCoupon;
  String? get couponError => _couponError;

  int get itemCount => _items.values.fold(0, (sum, item) => sum + item.quantity);

  /// Selling price subtotal before coupon discounts
  int get totalAmount => _items.values.fold(0, (sum, item) => sum + item.totalPrice);
  int get subtotalSellingPrice => totalAmount;

  /// Original manufacturer MRP subtotal
  int get totalMrp => _items.values.fold(0, (sum, item) => sum + (item.product.mrp * item.quantity));

  /// Base direct-factory savings before extra coupon
  int get totalSavings => totalMrp - totalAmount;

  /// Total maximum discount allowed across all items in cart (CBM Poka-Yoke Guardrail)
  int get maxDiscountAllowed {
    int maxDiscount = 0;
    for (final item in _items.values) {
      maxDiscount += item.product.maxDiscountAllowed * item.quantity;
    }
    return maxDiscount > 0 ? maxDiscount : 500;
  }

  /// Instant discount deducted via applied coupon (Authoritative server-verified value)
  int get couponDiscountAmount {
    if (_appliedCoupon == null) return 0;
    final raw = _serverCouponDiscount ?? _appliedCoupon!.calculateDiscount(totalAmount).toDouble();
    final clamped = raw < 0 ? 0.0 : (raw > totalAmount ? totalAmount.toDouble() : raw);
    return clamped.round();
  }

  bool get shippingQuoteLoaded => _shippingQuoteLoaded;
  bool get shippingFeeEnabled => _shippingEnabled;
  int get standardCourierCharge => _standardCourierCharge;
  int get freeShippingMinOrder => _freeShippingMinOrder;
  String get shippingThresholdBasis => _shippingThresholdBasis;
  bool get isCodPolicyEnabled => _codEnabled;
  int get maxCodOrderAmount => _maxCodOrderAmount;

  int get _shippingBasisAmount {
    if (_shippingThresholdBasis == 'AFTER_COUPON') {
      final v = totalAmount - couponDiscountAmount;
      return v > 0 ? v : 0;
    }
    return totalAmount;
  }

  /// Dynamic courier fee matching CBM Admin online_shipping_policy
  int get onlineDeliveryFee {
    if (!_shippingQuoteLoaded || _items.isEmpty) return 0;
    if (!_shippingEnabled || _standardCourierCharge <= 0) return 0;
    if (_freeShippingMinOrder <= 0 || _shippingBasisAmount >= _freeShippingMinOrder) return 0;
    return _standardCourierCharge;
  }

  bool get isFreeShippingUnlocked => _shippingQuoteLoaded && _items.isNotEmpty && onlineDeliveryFee == 0;

  void applyOnlineShippingPolicy(Map<String, dynamic> res) {
    _shippingQuoteLoaded = true;
    _shippingEnabled = res['shipping_enabled'] != false;
    final sc = num.tryParse((res['standard_courier_charge'] ?? '0').toString())?.round();
    if (sc != null && sc >= 0) _standardCourierCharge = sc;
    final fm = num.tryParse((res['free_shipping_min_order'] ?? '0').toString())?.round();
    if (fm != null && fm >= 0) _freeShippingMinOrder = fm;
    final tb = (res['threshold_basis'] ?? 'BEFORE_COUPON').toString().toUpperCase();
    _shippingThresholdBasis = tb == 'AFTER_COUPON' ? 'AFTER_COUPON' : 'BEFORE_COUPON';

    if (res['cod_policy'] is Map) {
      final cp = Map<String, dynamic>.from(res['cod_policy'] as Map);
      _codEnabled = cp['enabled'] != false;
      final cm = num.tryParse((cp['max_order_amount'] ?? '15000').toString())?.round();
      if (cm != null && cm >= 0) _maxCodOrderAmount = cm;
    }
    notifyListeners();
  }

  int get amountRemainingForFreeShipping {
    if (!_shippingEnabled || _standardCourierCharge <= 0 || _freeShippingMinOrder <= 0) return 0;
    final rem = _freeShippingMinOrder - _shippingBasisAmount;
    return rem > 0 ? rem : 0;
  }

  /// Final net amount payable after applying factory rates, coupon & server courier rule
  int get finalPayableAmount {
    final net = totalAmount - couponDiscountAmount + onlineDeliveryFee;
    return net > 0 ? net : 0;
  }

  bool get isCodAmountEligible =>
      _codEnabled && (_maxCodOrderAmount <= 0 || finalPayableAmount <= _maxCodOrderAmount);

  Future<void> refreshOnlineShippingQuote() async {
    final seq = ++_shippingQuoteSeq;
    try {
      final res = await ApiService().fetchOnlineShippingQuote(
        subtotal: totalAmount.toDouble(),
        discount: couponDiscountAmount.toDouble(),
      );
      if (seq != _shippingQuoteSeq || res['success'] != true) return;
      applyOnlineShippingPolicy(res);
    } catch (_) {}
  }

  /// Total combined savings (factory cut + coupon)
  int get combinedTotalSavings => totalSavings + couponDiscountAmount;

  bool get hasScannedItems => false;
  List<CartItem> get scannedItems => const [];
  List<CartItem> get catalogItems => _items.values.toList();
  bool get isCodEligibleForAllItems => _items.values.every((i) => i.product.codEnabled) && isCodAmountEligible;

  int getQuantity(String productId) {
    return _items[productId]?.quantity ?? 0;
  }

  /// Adds an online-sellable product/kit to the Online Selling Cart.
  /// Strictly isolated from doorstep technician QR custody checkout.
  bool addToCart(Product product, {bool isScanned = false}) {
    if (isScanned || !product.inStock || !product.isActive || !product.onlineSellingEnabled) {
      return false;
    }
    if (_items.containsKey(product.id)) {
      final current = _items[product.id]!;
      _items[product.id] = CartItem(
        product: product,
        quantity: current.quantity + 1,
        isScanned: false,
      );
    } else {
      _items[product.id] = CartItem(
        product: product,
        quantity: 1,
        isScanned: false,
      );
    }
    _revalidateCoupon();
    notifyListeners();
    _scheduleOnlineDraftSync();
    return true;
  }

  /// Deprecated: Doorstep QR spares now use dedicated DoorstepCheckoutVerificationScreen.
  void addScannedItem(dynamic scannedItem) {
    // Intentionally a no-op to preserve strict separation between Online Cart and Doorstep QR Checkout.
  }

  void decrementQuantity(Product product) {
    if (!_items.containsKey(product.id)) return;
    if (_items[product.id]!.quantity > 1) {
      final current = _items[product.id]!;
      _items[product.id] = CartItem(
        product: product,
        quantity: current.quantity - 1,
        isScanned: current.isScanned,
      );
    } else {
      _items.remove(product.id);
    }
    _revalidateCoupon();
    notifyListeners();
    _scheduleOnlineDraftSync();
  }

  void removeFromCart(String productId) {
    _items.remove(productId);
    _revalidateCoupon();
    notifyListeners();
    _scheduleOnlineDraftSync();
  }

  void clearCart({bool syncDismiss = false}) {
    _draftSyncDebounce?.cancel();
    _items.clear();
    _appliedCoupon = null;
    _serverCouponDiscount = null;
    _couponError = null;
    _activeRecoveryDraft = null;
    notifyListeners();
    if (syncDismiss && _isLoggedIn && _authToken != null && _authToken!.isNotEmpty) {
      unawaited(ApiService().syncOnlineCartDraft({'items': const []}));
    }
  }

  /// Syncs cart items with authoritative server catalog pricing (at checkout initiation).
  /// Returns true if any item's MRP or selling price differed from the displayed values.
  bool syncCartPrices(
    List<dynamic> serverItems, {
    double? updatedCouponDiscount,
  }) {
    if (_items.isEmpty || serverItems.isEmpty) return false;
    final bySku = <String, Map<String, dynamic>>{};
    for (final raw in serverItems) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final sku = (map['sku'] ?? map['product_sku'] ?? '').toString().trim().toUpperCase();
      if (sku.isNotEmpty) bySku[sku] = map;
    }
    if (bySku.isEmpty) return false;

    bool changed = false;
    for (final key in _items.keys.toList()) {
      final cartItem = _items[key]!;
      final skuKey = cartItem.product.sku.trim().toUpperCase();
      final idKey = cartItem.product.id.trim().toUpperCase();
      final matched = bySku[skuKey] ?? bySku[idKey];
      if (matched == null) continue;

      final srvMrpRaw = double.tryParse((matched['unit_mrp'] ?? matched['mrp'] ?? '').toString());
      final srvSellingRaw = double.tryParse((matched['unit_selling_price'] ?? matched['selling_price'] ?? '').toString());
      final srvName = (matched['name'] ?? '').toString().trim();

      final nextMrp = (srvMrpRaw != null && srvMrpRaw > 0) ? srvMrpRaw.round() : cartItem.product.mrp;
      final nextSelling = (srvSellingRaw != null && srvSellingRaw > 0) ? srvSellingRaw.round() : cartItem.product.sellingPrice;

      if (nextMrp != cartItem.product.mrp || nextSelling != cartItem.product.sellingPrice) {
        changed = true;
        _items[key] = CartItem(
          product: cartItem.product.copyWith(
            name: srvName.isNotEmpty ? srvName : cartItem.product.name,
            mrp: nextMrp,
            sellingPrice: nextSelling,
          ),
          quantity: cartItem.quantity,
          isScanned: cartItem.isScanned,
        );
      }
    }

    if (updatedCouponDiscount != null && _appliedCoupon != null) {
      _serverCouponDiscount = updatedCouponDiscount < 0 ? 0.0 : updatedCouponDiscount;
    }

    if (changed || updatedCouponDiscount != null) {
      notifyListeners();
    }
    return changed;
  }

  // --- Coupon Logic (Authoritative Server APIs) ---

  int _couponValidationSeq = 0;

  /// Fetches active public ONLINE coupons from backend, annotated with per-user exhaustion.
  Future<void> refreshAvailableCoupons() async {
    if (_isLoadingCoupons) return;
    _isLoadingCoupons = true;
    notifyListeners();
    try {
      final rows = await ApiService().getCoupons(
        channel: 'ONLINE',
        customerId: _customerId,
      );
      _availableCoupons = rows.map((row) => Coupon.fromJson(row)).toList();
    } catch (e) {
      debugPrint('[CartState] refreshAvailableCoupons error: $e');
    } finally {
      _isLoadingCoupons = false;
      notifyListeners();
    }
  }

  /// Validates and applies a coupon code live against backend /api/coupons/validate.
  Future<bool> applyCoupon(String rawCode) async {
    _couponError = null;
    final cleanCode = CouponRegistry.normalizeScannedCode(rawCode);
    if (cleanCode == null) {
      _couponError = 'Please enter a valid coupon code';
      notifyListeners();
      return false;
    }

    if (_items.isEmpty) {
      _couponError = 'Add items to cart before applying a coupon';
      notifyListeners();
      return false;
    }

    final seq = ++_couponValidationSeq;
    _isValidatingCoupon = true;
    notifyListeners();

    try {
      final res = await ApiService().validateCoupon(
        code: cleanCode,
        channel: 'ONLINE',
        amount: totalAmount.toDouble(),
        mrp: totalMrp.toDouble(),
        customerId: _customerId,
      );

      if (seq != _couponValidationSeq) return false;

      if (res['success'] == true) {
        _appliedCoupon = Coupon.fromJson(res);
        final discVal = res['discount'];
        _serverCouponDiscount = (discVal is num)
            ? discVal.toDouble()
            : (double.tryParse(discVal?.toString() ?? '') ?? 0.0);
        _couponError = null;
        return true;
      } else {
        _appliedCoupon = null;
        _serverCouponDiscount = null;
        _couponError = (res['error'] ?? 'Coupon not eligible').toString();
        return false;
      }
    } catch (e) {
      if (seq != _couponValidationSeq) return false;
      _couponError = 'Unable to verify coupon right now. Please retry.';
      return false;
    } finally {
      if (seq == _couponValidationSeq) {
        _isValidatingCoupon = false;
        notifyListeners();
      }
    }
  }

  void removeCoupon() {
    _couponValidationSeq++;
    _appliedCoupon = null;
    _serverCouponDiscount = null;
    _couponError = null;
    notifyListeners();
  }

  void _revalidateCoupon() {
    if (_appliedCoupon == null) return;
    if (_items.isEmpty) {
      _couponValidationSeq++;
      _appliedCoupon = null;
      _serverCouponDiscount = null;
      _couponError = null;
      return;
    }
    if (totalAmount < _appliedCoupon!.minOrderValue) {
      _couponValidationSeq++;
      _couponError = 'Coupon ${_appliedCoupon!.code} removed (Min order ₹${_appliedCoupon!.minOrderValue.toInt()})';
      _appliedCoupon = null;
      _serverCouponDiscount = null;
      return;
    }
    unawaited(_revalidateAppliedCouponAsync(_appliedCoupon!.code));
  }

  Future<void> _revalidateAppliedCouponAsync(String code) async {
    final seq = ++_couponValidationSeq;
    try {
      final res = await ApiService().validateCoupon(
        code: code,
        channel: 'ONLINE',
        amount: totalAmount.toDouble(),
        mrp: totalMrp.toDouble(),
        customerId: _customerId,
      );
      if (seq != _couponValidationSeq) return;
      if (res['success'] == true) {
        _appliedCoupon = Coupon.fromJson(res);
        final discVal = res['discount'];
        _serverCouponDiscount = (discVal is num)
            ? discVal.toDouble()
            : (double.tryParse(discVal?.toString() ?? '') ?? 0.0);
        _couponError = null;
      } else {
        _appliedCoupon = null;
        _serverCouponDiscount = null;
        _couponError = (res['error'] ?? 'Coupon removed after cart update').toString();
      }
      notifyListeners();
    } catch (_) {}
  }

  void setSegment(String segment) {
    if (_activeSegment != segment) {
      _activeSegment = segment;
      notifyListeners();
    }
  }

  void setLocation(String pincode, String city) {
    _deliveryPincode = pincode;
    _deliveryCity = city;
    _persistAddresses();
    notifyListeners();
  }

  void setPincode(String pincode) {
    _deliveryPincode = pincode;
    _persistAddresses();
    notifyListeners();
  }

  String? get _resolvedCustomerId {
    if (_customerId != null && _customerId!.isNotEmpty) {
      return _customerId;
    }
    final derived = PhoneNormalizer.toCustomerId(_userPhone);
    return derived.isNotEmpty ? derived : null;
  }

  void setDefaultGpsAddress({
    required String pincode,
    required String city,
    required String area,
    required double latitude,
    required double longitude,
  }) {
    _deliveryPincode = pincode;
    _deliveryCity = city;
    if (_activeAddress != null && _activeAddress!.pincode != pincode) {
      _activeAddress = null;
    }
    _persistAddresses();
    notifyListeners();
  }

  void selectOnlineAddress(UserAddress address) {
    selectAddress(address);
  }

  String _addressDedupSignature(UserAddress a) {
    final pin = a.pincode.trim().toLowerCase();
    final cleanAddr = '${a.flatNo} ${a.streetArea}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return '$pin#$cleanAddr';
  }

  bool addAddress(UserAddress address) {
    final incomingSig = _addressDedupSignature(address);
    final dupIdx = _addresses.indexWhere(
      (a) => a.id == address.id || (incomingSig.length > 2 && _addressDedupSignature(a) == incomingSig),
    );

    if (dupIdx != -1) {
      final existing = _addresses[dupIdx];
      final merged = address.copyWith(
        id: existing.id,
        sk: existing.sk ?? address.sk,
        addressType: 'UNIFIED',
        latitude: address.hasMapPin ? address.latitude : existing.latitude,
        longitude: address.hasMapPin ? address.longitude : existing.longitude,
        isDefault: address.isDefault || existing.isDefault || _addresses.length == 1,
      );
      if (merged.isDefault) {
        for (var i = 0; i < _addresses.length; i++) {
          _addresses[i] = _addresses[i].copyWith(isDefault: i == dupIdx);
        }
      }
      _addresses[dupIdx] = merged;
      selectAddress(merged);
      _syncAddressSaveToServer(merged, isUpdate: true);
      return true;
    }

    if (_addresses.length >= maxSavedAddresses) {
      return false;
    }

    final makeDefault = address.isDefault || _addresses.isEmpty;
    if (makeDefault) {
      for (var i = 0; i < _addresses.length; i++) {
        _addresses[i] = _addresses[i].copyWith(isDefault: false);
      }
    }
    final finalAddr = address.copyWith(
      addressType: 'UNIFIED',
      isDefault: makeDefault,
    );
    _addresses.insert(0, finalAddr);
    selectAddress(finalAddr);
    _syncAddressSaveToServer(finalAddr, isUpdate: false);
    return true;
  }

  void _syncAddressSaveToServer(UserAddress finalAddr, {required bool isUpdate}) {
    final cid = _resolvedCustomerId;
    if (cid == null || !_isLoggedIn || _authToken == null || _authToken!.isEmpty) return;

    final cityState = [finalAddr.city, if ((finalAddr.stateName ?? '').isNotEmpty) finalAddr.stateName!]
        .where((s) => s.trim().isNotEmpty)
        .join(', ');
    final line = [finalAddr.flatNo, finalAddr.streetArea, cityState]
        .where((s) => s.trim().isNotEmpty)
        .join(', ');

    final future = isUpdate
        ? ApiService().updateCustomerAddress(
            customerId: cid,
            phone: _userPhone,
            addressId: finalAddr.id,
            sk: finalAddr.sk,
            addressType: 'UNIFIED',
            recipientName: finalAddr.recipientName,
            recipientPhone: finalAddr.recipientPhone,
            houseNo: finalAddr.flatNo,
            street: finalAddr.streetArea,
            landmark: finalAddr.landmark,
            city: finalAddr.city,
            state: finalAddr.stateName,
            label: finalAddr.tag,
            addressLine: line,
            pincode: finalAddr.pincode,
            latitude: finalAddr.hasMapPin ? finalAddr.latitude : null,
            longitude: finalAddr.hasMapPin ? finalAddr.longitude : null,
            isDefault: finalAddr.isDefault,
          )
        : ApiService().saveCustomerAddress(
            customerId: cid,
            phone: _userPhone,
            addressId: finalAddr.id,
            sk: finalAddr.sk,
            addressType: 'UNIFIED',
            recipientName: finalAddr.recipientName,
            recipientPhone: finalAddr.recipientPhone,
            houseNo: finalAddr.flatNo,
            street: finalAddr.streetArea,
            landmark: finalAddr.landmark,
            city: finalAddr.city,
            state: finalAddr.stateName,
            label: finalAddr.tag,
            addressLine: line,
            pincode: finalAddr.pincode,
            latitude: finalAddr.hasMapPin ? finalAddr.latitude : null,
            longitude: finalAddr.hasMapPin ? finalAddr.longitude : null,
            isDefault: finalAddr.isDefault,
          );

    unawaited(
      future.then((res) {
        if (_resolvedCustomerId != cid) return;
        if (res['success'] == true && res['address'] != null) {
          final serverSk = res['address']['sk']?.toString();
          if (serverSk != null && serverSk.isNotEmpty) {
            final idx = _addresses.indexWhere((a) => a.id == finalAddr.id);
            if (idx != -1) {
              _addresses[idx] = _addresses[idx].copyWith(sk: serverSk);
              _persistAddresses();
            }
          }
        }
      }).catchError((e) {
        debugPrint('[CartState] address async sync error: $e');
      }),
    );
  }

  /// Synchronize DynamoDB address book from Central Server to local device.
  /// Server is the Single Source of Truth (SSoT).
  Future<void> syncAddressesFromServer() async {
    final cid = _resolvedCustomerId;
    if (cid == null || cid.isEmpty) return;

    try {
      final rawList = await ApiService().getCustomerAddresses(cid);
      if (_resolvedCustomerId != cid) return;
      final serverAddresses = <UserAddress>[];
      for (final item in rawList) {
        try {
          serverAddresses.add(UserAddress.fromDynamo(item));
        } catch (_) {}
      }

      // Authoritative SSoT reconciliation:
      // Replace local cache with verified server records
      _addresses.clear();
      _addresses.addAll(serverAddresses);

      if (_addresses.isNotEmpty) {
        if (_activeAddress != null) {
          final matchIdx = _addresses.indexWhere(
            (a) => a.id == _activeAddress!.id || (a.sk != null && a.sk == _activeAddress!.sk),
          );
          _activeAddress = matchIdx != -1
              ? _addresses[matchIdx]
              : _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first);
        } else {
          _activeAddress = _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first);
        }
        _deliveryPincode = _activeAddress!.pincode;
        _deliveryCity = _activeAddress!.city;
      } else {
        _activeAddress = null;
      }

      await _persistAddresses();
      notifyListeners();
    } catch (e) {
      debugPrint('[CartState] syncAddressesFromServer error: $e');
    }
  }

  /// Pre-warm GPS location in background on app startup/idle with instant cached hit first
  Future<void> prewarmLocation({bool requestIfDenied = false}) async {
    await getCurrentOrCachedPosition(requestPermission: requestIfDenied);
  }

  /// Reliable GPS position getter with cached instant hit, permission request fallback, and timeout
  Future<Position?> getCurrentOrCachedPosition({bool requestPermission = false}) async {
    try {
      final isServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isServiceEnabled) return _cachedLocation;

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && requestPermission) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return _cachedLocation;
      }

      // 1. Instant cached hit
      _cachedLocation ??= await Geolocator.getLastKnownPosition();
      if (_cachedLocation != null) return _cachedLocation;

      // 2. Fresh GPS fix with generous 5-second timeout for hardware lock
      _cachedLocation = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
      debugPrint('[CartState] Acquired GPS location: ${_cachedLocation?.latitude}, ${_cachedLocation?.longitude}');
      return _cachedLocation;
    } catch (e) {
      debugPrint('[CartState] Location acquisition warning: $e');
      return _cachedLocation;
    }
  }

  void updateAddress(String id, UserAddress updated) {
    final index = _addresses.indexWhere((a) => a.id == id);
    if (index != -1) {
      final oldAddr = _addresses[index];
      if (updated.isDefault) {
        for (var i = 0; i < _addresses.length; i++) {
          _addresses[i] = _addresses[i].copyWith(isDefault: false);
        }
      }
      final finalUpdated = updated.copyWith(
        sk: updated.sk ?? oldAddr.sk,
        addressType: 'UNIFIED',
        latitude: updated.hasMapPin ? updated.latitude : oldAddr.latitude,
        longitude: updated.hasMapPin ? updated.longitude : oldAddr.longitude,
      );

      // 1. OPTIMISTIC UI: Instantly update in memory (0ms) and notify listeners
      _addresses[index] = finalUpdated;
      if (_activeAddress?.id == id) {
        selectAddress(finalUpdated);
      } else {
        _persistAddresses();
        notifyListeners();
      }

      // 2. BACKGROUND ASYNC DB SYNC: Modify in DynamoDB & RDS SSoT
      _syncAddressSaveToServer(finalUpdated, isUpdate: true);
    }
  }

  void deleteAddress(String id) {
    final index = _addresses.indexWhere((a) => a.id == id);
    if (index == -1) return;
    final toDelete = _addresses[index];

    // 1. OPTIMISTIC UI: Remove from list in 0ms, promote default/active cleanly
    _addresses.removeAt(index);
    if (toDelete.isDefault && _addresses.isNotEmpty && !_addresses.any((a) => a.isDefault)) {
      _addresses[0] = _addresses[0].copyWith(isDefault: true);
    }
    if (_activeAddress?.id == id) {
      _activeAddress = _addresses.isNotEmpty
          ? _addresses.firstWhere((a) => a.isDefault, orElse: () => _addresses.first)
          : null;
      if (_activeAddress != null) {
        _deliveryPincode = _activeAddress!.pincode;
        _deliveryCity = _activeAddress!.city;
      }
    }
    _persistAddresses();
    notifyListeners();

    // 2. BACKGROUND ASYNC DB SYNC: Delete from DynamoDB & RDS
    final cid = _resolvedCustomerId;
    if (cid != null && _isLoggedIn && _authToken != null && _authToken!.isNotEmpty) {
      unawaited(
        ApiService().deleteCustomerAddress(
          customerId: cid,
          phone: _userPhone,
          addressId: id,
          sk: toDelete.sk,
        ).then((res) {
          debugPrint('[CartState] Address $id deleted from DB successfully');
        }).catchError((e) {
          debugPrint('[CartState] deleteAddress async sync error: $e');
        }),
      );
    }
  }

  void selectAddress(UserAddress address) {
    _activeAddress = address;
    if (address.pincode.isNotEmpty) {
      _deliveryPincode = address.pincode;
    }
    if (address.city.isNotEmpty) {
      _deliveryCity = address.city;
    }
    _persistAddresses();
    notifyListeners();
    _scheduleOnlineDraftSync();
  }

  String buildWhatsAppOrderMessage({String? customerName, String? address}) {
    final buffer = StringBuffer();
    buffer.writeln("💧 *NEW ORDER - ROPARTS.IN*");
    buffer.writeln("────────────────────────");
    if (customerName != null && customerName.isNotEmpty) {
      buffer.writeln("👤 *Customer:* $customerName");
    }
    if (address != null && address.isNotEmpty) {
      buffer.writeln("📍 *Delivery Address:* $address (PIN: $_deliveryPincode)");
    } else {
      buffer.writeln("📍 *Delivery PIN:* $_deliveryPincode");
    }
    buffer.writeln("📦 *Items:*");

    for (final item in _items.values) {
      final tag = item.isScanned ? " [✓ Genuine Scanned Spare]" : "";
      buffer.writeln(
        "• ${item.product.name}$tag x${item.quantity} = ₹${item.totalPrice}",
      );
    }
    buffer.writeln("────────────────────────");
    buffer.writeln("🧾 *Subtotal:* ₹$totalAmount");
    if (_appliedCoupon != null && couponDiscountAmount > 0) {
      buffer.writeln("🏷️ *Coupon Applied (${_appliedCoupon!.code}):* -₹$couponDiscountAmount");
    }
    buffer.writeln("💰 *Total Payable:* ₹$finalPayableAmount");
    buffer.writeln("🏷️ *Total Savings:* ₹$combinedTotalSavings");
    buffer.writeln("🚚 *Delivery:* FREE Shipping (Factory Direct)");
    buffer.writeln("Please confirm dispatch details.");
    return buffer.toString();
  }

  Map<String, dynamic>? get activeRecoveryDraft => _activeRecoveryDraft;

  bool get hasActiveRecoveryDraft {
    if (_activeRecoveryDraft == null) return false;
    final status = (_activeRecoveryDraft!['status'] ?? '').toString().toUpperCase();
    if (status == 'CONVERTED' || status == 'DISMISSED' || status == 'EXPIRED') {
      return false;
    }
    final items = _activeRecoveryDraft!['items'];
    return items is List && items.isNotEmpty;
  }

  int get recoveryDraftDaysRemaining {
    final days = int.tryParse((_activeRecoveryDraft?['days_remaining'] ?? '').toString());
    if (days != null) return days;
    final rawExp = _activeRecoveryDraft?['expires_at']?.toString();
    final exp = rawExp != null ? DateTime.tryParse(rawExp) : null;
    if (exp == null) return 7;
    final hours = exp.difference(DateTime.now()).inHours;
    return hours <= 0 ? 0 : (hours / 24).ceil();
  }

  int get recoveryDraftPayable {
    final raw = double.tryParse((_activeRecoveryDraft?['estimated_payable'] ?? '').toString());
    if (raw != null && raw > 0) return raw.round();
    return finalPayableAmount;
  }

  bool get isRecoveryDraftPaymentFailed =>
      (_activeRecoveryDraft?['status'] ?? '').toString().toUpperCase() == 'PAYMENT_FAILED';

  Map<String, dynamic> _buildDraftSyncPayload({String? statusOverride}) {
    final onlineAddr = activeOnlineAddress;
    final rawPin = (onlineAddr?.pincode.isNotEmpty == true ? onlineAddr!.pincode : _deliveryPincode)
        .replaceAll(RegExp(r'\D'), '');
    final addressText = onlineAddr?.fullAddress.trim() ?? '';
    return {
      if (statusOverride != null) 'status': statusOverride,
      'items': _items.values
          .map((ci) => {
                'sku': ci.product.sku,
                'name': ci.product.name,
                'qty': ci.quantity,
                'selling_price': ci.product.mrp,
                'mrp': ci.product.mrp,
                'type': ci.product.itemType,
                'image_url': ci.product.image,
              })
          .toList(),
      if (addressText.isNotEmpty) 'delivery_address': addressText,
      if (RegExp(r'^[1-9][0-9]{5}$').hasMatch(rawPin)) 'delivery_pincode': rawPin,
      if ((onlineAddr?.city ?? _deliveryCity).trim().isNotEmpty)
        'delivery_city': (onlineAddr?.city ?? _deliveryCity).trim(),
      if ((onlineAddr?.stateName ?? '').trim().isNotEmpty)
        'delivery_state': onlineAddr!.stateName!.trim(),
      if (_userName.isNotEmpty) 'recipient_name': _userName,
      if (_userPhone.isNotEmpty) 'recipient_phone': _userPhone,
      if (_appliedCoupon != null) 'coupon_code': _appliedCoupon!.code,
      if (couponDiscountAmount > 0) 'discount_amount': couponDiscountAmount,
    };
  }

  void _scheduleOnlineDraftSync() {
    if (_isHydratingDraft) return;
    if (!_isLoggedIn || _authToken == null || _authToken!.isEmpty) return;
    _draftSyncDebounce?.cancel();
    _draftSyncDebounce = Timer(const Duration(seconds: 3), () async {
      await syncOnlineDraftNow();
    });
  }

  Future<void> syncOnlineDraftNow({String? statusOverride}) async {
    if (!_isLoggedIn || _authToken == null || _authToken!.isEmpty) return;
    if (_items.isEmpty) {
      await ApiService().syncOnlineCartDraft({'items': const []});
      _activeRecoveryDraft = null;
      notifyListeners();
      return;
    }
    final res = await ApiService().syncOnlineCartDraft(
      _buildDraftSyncPayload(statusOverride: statusOverride),
    );
    if (res['success'] == true && res['draft'] is Map) {
      _activeRecoveryDraft = Map<String, dynamic>.from(res['draft'] as Map);
      notifyListeners();
    }
  }

  Future<void> loadActiveOnlineDraft() async {
    if (!_isLoggedIn || _authToken == null || _authToken!.isEmpty) return;
    final draft = await ApiService().fetchActiveOnlineDraft();
    if (draft == null) {
      if (_activeRecoveryDraft != null) {
        _activeRecoveryDraft = null;
        notifyListeners();
      }
      return;
    }
    _activeRecoveryDraft = draft;
    final draftPin = (draft['delivery_pincode'] ?? '').toString().trim();
    if (RegExp(r'^[1-9][0-9]{5}$').hasMatch(draftPin)) {
      _deliveryPincode = draftPin;
    }
    final draftCity = (draft['delivery_city'] ?? '').toString().trim();
    if (draftCity.isNotEmpty) {
      _deliveryCity = draftCity;
    }
    if (_items.isEmpty && draft['items'] is List && (draft['items'] as List).isNotEmpty) {
      hydrateItemsFromDraft(draft['items'] as List);
    } else {
      notifyListeners();
    }
  }

  void hydrateItemsFromDraft(List<dynamic> rawItems) {
    _isHydratingDraft = true;
    try {
      _items.clear();
      for (final entry in rawItems) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        final sku = (m['sku'] ?? m['recipe_id'] ?? m['product_sku'] ?? '').toString().trim().toUpperCase();
        if (sku.isEmpty) continue;
        final qty = (int.tryParse((m['qty'] ?? m['quantity'] ?? '1').toString()) ?? 1).clamp(1, 99);
        final selling = (double.tryParse((m['unit_selling_price'] ?? m['selling_price'] ?? m['price'] ?? '0').toString()) ?? 0).round();
        final mrpRaw = (double.tryParse((m['unit_mrp'] ?? m['mrp'] ?? '$selling').toString()) ?? selling).round();
        final mrp = mrpRaw >= selling ? mrpRaw : selling;
        final name = (m['name'] ?? sku).toString().trim();
        final type = (m['type'] ?? (sku.startsWith('KIT-') ? 'KIT' : 'PRODUCT')).toString().toUpperCase();
        final img = (m['image_url'] ?? m['image'] ?? '').toString().trim();

        final product = Product(
          id: sku,
          sku: sku,
          name: name.isNotEmpty ? name : sku,
          slug: sku.toLowerCase(),
          brand: 'DropAqua',
          sellingPrice: selling,
          mrp: mrp,
          image: img,
          categoryId: (m['category'] ?? 'spares').toString().toLowerCase().replaceAll(' ', '_'),
          shortDescription: (m['category'] ?? 'Genuine CBM Online Spare').toString(),
          categoryName: (m['category'] ?? 'RO Spares').toString(),
          segment: _activeSegment,
          inStock: true,
          isActive: true,
          onlineSellingEnabled: true,
          codEnabled: true,
          itemType: type,
        );
        _items[product.id] = CartItem(product: product, quantity: qty, isScanned: false);
      }
      notifyListeners();
    } finally {
      _isHydratingDraft = false;
    }
  }

  Future<Map<String, dynamic>> resumeActiveOnlineDraft({String? draftId}) async {
    final targetId = (draftId != null && draftId.isNotEmpty)
        ? draftId
        : (_activeRecoveryDraft?['draft_id']?.toString() ?? 'active');
    final res = await ApiService().resumeOnlineDraft(draftId: targetId);
    if (res['success'] == true) {
      if (res['draft'] is Map) {
        _activeRecoveryDraft = Map<String, dynamic>.from(res['draft'] as Map);
        final draftPin = (_activeRecoveryDraft?['delivery_pincode'] ?? '').toString().trim();
        if (RegExp(r'^[1-9][0-9]{5}$').hasMatch(draftPin)) {
          _deliveryPincode = draftPin;
        }
        final draftCity = (_activeRecoveryDraft?['delivery_city'] ?? '').toString().trim();
        if (draftCity.isNotEmpty) {
          _deliveryCity = draftCity;
        }
      }
      final live = res['live_pricing'] is Map
          ? Map<String, dynamic>.from(res['live_pricing'] as Map)
          : null;
      if (live != null) {
        if (live['processed_items'] is List && (live['processed_items'] as List).isNotEmpty) {
          hydrateItemsFromDraft(live['processed_items'] as List);
        }
        if (live['shipping_quote'] is Map) {
          applyOnlineShippingPolicy({
            'shipping_policy': live['shipping_quote'],
          });
        }
      }
      notifyListeners();
    }
    return res;
  }

  Future<void> reportOnlinePaymentFailure({
    String? orderNumber,
    required String reason,
    String? deliveryAddress,
    String? deliveryPincode,
    String? deliveryCity,
    String? deliveryState,
  }) async {
    if (!_isLoggedIn || _authToken == null || _authToken!.isEmpty) return;
    final payload = {
      ..._buildDraftSyncPayload(),
      if (orderNumber != null && orderNumber.isNotEmpty) 'order_number': orderNumber,
      'reason': reason,
      'estimated_payable': finalPayableAmount,
      if (deliveryAddress != null && deliveryAddress.isNotEmpty) 'delivery_address': deliveryAddress,
      if (deliveryPincode != null && deliveryPincode.isNotEmpty) 'delivery_pincode': deliveryPincode,
      if (deliveryCity != null && deliveryCity.isNotEmpty) 'delivery_city': deliveryCity,
      if (deliveryState != null && deliveryState.isNotEmpty) 'delivery_state': deliveryState,
    };
    final res = await ApiService().reportOnlinePaymentFailure(payload);
    if (res['success'] == true && res['draft'] is Map) {
      _activeRecoveryDraft = Map<String, dynamic>.from(res['draft'] as Map);
      notifyListeners();
    }
  }

  Future<void> dismissOnlineRecoveryDraft({String reason = 'CUSTOMER_DISMISSED'}) async {
    final id = _activeRecoveryDraft?['draft_id']?.toString();
    _activeRecoveryDraft = null;
    notifyListeners();
    await ApiService().dismissOnlineDraft(draftId: id, reason: reason);
  }

  @override
  void dispose() {
    _draftSyncDebounce?.cancel();
    super.dispose();
  }
}
