import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/catalog_snapshot.dart';
import '../models/product.dart';
import '../utils/phone_normalizer.dart';

class ApiService {
  static const String baseUrl = String.fromEnvironment(
    'ROPARTS_API_URL',
    defaultValue: 'https://api.droppurity.in',
  );
  static const String cbmBaseUrl = String.fromEnvironment(
    'CBM_BASE_URL',
    defaultValue: 'https://payment.droppurity.in',
  );
  static const String olaMapsApiKey = 'Ij1O5SIYeiaVv16retqYB3iD7fmrBiuG6nAB8CUu';
  static const String olaMapsTileUrl = 'https://api.olamaps.io/tiles/v1/styles/default-light-standard/{z}/{x}/{y}.png?api_key=$olaMapsApiKey';
  static const String cartoApiKey = 'cb1_4zau_1_58fcccecd45b307497537294';
  static const String cartoTileUrl = 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=$cartoApiKey';
  static final ApiService _instance = ApiService._internal();
  static http.Client _client = http.Client();
  static String? _authToken;

  @visibleForTesting
  static void setHttpClientForTesting(http.Client client) {
    _client = client;
  }

  @visibleForTesting
  void resetCatalogCacheForTesting() {
    _cachedCatalogSnapshot = null;
    _cachedCbmHighlights = null;
    _lastFetchTime = null;
  }

  /// Updates the active customer Bearer JWT attached to authenticated API requests.
  static void setAuthToken(String? token) {
    final cleaned = token?.trim();
    _authToken = (cleaned != null && cleaned.isNotEmpty) ? cleaned : null;
  }

  static bool get hasAuthToken => _authToken != null && _authToken!.isNotEmpty;

  static Map<String, String> jsonHeaders({bool includeAuth = true}) => {
        'Content-Type': 'application/json',
        if (includeAuth && _authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  static Future<String?> Function()? _onUnauthorizedRefresh;

  /// Registers a callback invoked once when an authenticated call returns 401.
  static void setUnauthorizedRefreshHandler(Future<String?> Function()? handler) {
    _onUnauthorizedRefresh = handler;
  }

  Future<Map<String, dynamic>> _postAuthedJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    Future<http.Response> send() => _client
        .post(
          Uri.parse('$baseUrl$path'),
          headers: jsonHeaders(),
          body: json.encode(body),
        )
        .timeout(timeout);

    try {
      var response = await send();
      if (response.statusCode == 401 && _onUnauthorizedRefresh != null) {
        final refreshed = await _onUnauthorizedRefresh!();
        if (refreshed != null && refreshed.isNotEmpty) {
          response = await send();
        }
      }

      Map<String, dynamic> map = <String, dynamic>{};
      final raw = response.body.trim();
      if (raw.isNotEmpty) {
        try {
          final decoded = json.decode(raw);
          if (decoded is Map<String, dynamic>) {
            map = Map<String, dynamic>.from(decoded);
          } else if (decoded is Map) {
            map = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        map.putIfAbsent('success', () => true);
        return map;
      }

      map['success'] = false;
      map['statusCode'] = response.statusCode;
      map.putIfAbsent(
        'message',
        () => map['error']?.toString() ?? 'Request failed (${response.statusCode})',
      );
      return map;
    } catch (e) {
      debugPrint('[ApiService] POST $path failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'message': 'Network error. Please try again.',
      };
    }
  }

  /// Reusable singleton HTTP client enabling persistent TCP connection pooling & TLS Keep-Alive
  static http.Client get client => _client;

  factory ApiService() => _instance;
  ApiService._internal();

  static const String _prefCatalogRefKey = 'ro_catalog_ref_v1';
  static const String _prefCatalogPayloadKey = 'ro_catalog_payload_v1';
  static const String _prefCatalogDirtyRefKey = 'ro_catalog_dirty_ref_v1';
  static const String _prefHappyHourPayloadKey = 'ro_happy_hour_v1';
  static const String _prefHappyHourVerKey = 'ro_happy_hour_ver_v1';
  static const String _prefGuestDeviceIdKey = 'ro_guest_device_id_v1';
  static const String _prefRegisteredFcmPairKey = 'ro_fcm_registered_pair_v1';

  CatalogSnapshot? _cachedCatalogSnapshot;
  Map<String, dynamic>? _cachedCbmHighlights;
  Map<String, dynamic>? _cachedHappyHour;
  DateTime? _lastFetchTime;
  DateTime? _lastVersionGateTime;
  Future<CatalogSnapshot>? _inFlightCatalogFetch;
  bool _inFlightCatalogForceRefresh = false;
  Future<VersionSyncResult>? _inFlightVersionSync;
  Future<bool>? _inFlightFcmRegister;
  Future<CatalogSnapshot?>? _inFlightFcmCatalogSync;
  String? _inFlightFcmTargetRef;
  static const Duration _cacheTtl = Duration(seconds: 45);
  static const Duration _fcmPairRefreshTtl = Duration(days: 6);

  /// Resets in-memory catalog and Redis version-gate caches (used by unit tests).
  void resetVersionSyncCachesForTesting() {
    resetCatalogCacheForTesting();
    _cachedHappyHour = null;
    _lastVersionGateTime = null;
    _inFlightCatalogFetch = null;
    _inFlightCatalogForceRefresh = false;
    _inFlightVersionSync = null;
    _inFlightFcmCatalogSync = null;
    _inFlightFcmTargetRef = null;
  }

  /// Records a pending catalog invalidation ref from background/terminated FCM push.
  static Future<void> markCatalogDirtyInPrefs(String? catalogRef) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cleanRef = (catalogRef ?? '').trim();
      await prefs.setString(
        _prefCatalogDirtyRefKey,
        cleanRef.isNotEmpty ? cleanRef : '__DIRTY__',
      );
    } catch (e) {
      debugPrint('[ApiService] markCatalogDirtyInPrefs warning: $e');
    }
  }

  Future<CatalogSnapshot?> _readPersistedCatalog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawJson = prefs.getString(_prefCatalogPayloadKey);
      if (rawJson == null || rawJson.trim().isEmpty) return null;
      final decoded = json.decode(rawJson);
      if (decoded is Map) {
        final snap = CatalogSnapshot.fromJson(Map<String, dynamic>.from(decoded));
        return snap;
      }
    } catch (e) {
      debugPrint('[ApiService] Read persisted catalog warning: $e');
    }
    return null;
  }

  /// Hydrates local cached catalog snapshot immediately (0ms network cost).
  Future<CatalogSnapshot?> readCachedCatalogSnapshot() async {
    if (_cachedCatalogSnapshot != null) return _cachedCatalogSnapshot;
    final persisted = await _readPersistedCatalog();
    if (persisted != null) {
      _cachedCatalogSnapshot = persisted;
      _cachedCbmHighlights = persisted.cbmHighlights;
    }
    return persisted;
  }

  Future<void> _persistCatalog(String catalogRef, String rawBody) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (catalogRef.isNotEmpty) {
        await prefs.setString(_prefCatalogRefKey, catalogRef);
      }
      await prefs.setString(_prefCatalogPayloadKey, rawBody);
      await prefs.remove(_prefCatalogDirtyRefKey);
    } catch (e) {
      debugPrint('[ApiService] Persist catalog warning: $e');
    }
  }

  /// Hydrates locally persisted Happy Hour banner/pricing status (0ms network cost).
  Future<Map<String, dynamic>?> readCachedHappyHour() async {
    if (_cachedHappyHour != null) return _cachedHappyHour;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefHappyHourPayloadKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = json.decode(raw);
      if (decoded is Map) {
        _cachedHappyHour = Map<String, dynamic>.from(decoded);
        return _cachedHappyHour;
      }
    } catch (e) {
      debugPrint('[ApiService] Read persisted happy hour warning: $e');
    }
    return null;
  }

  Future<void> persistHappyHour(Map<String, dynamic> data, {String? version}) async {
    try {
      final copy = Map<String, dynamic>.from(data);
      _cachedHappyHour = copy;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefHappyHourPayloadKey, json.encode(copy));
      final cleanVer = (version ?? '').trim();
      if (cleanVer.isNotEmpty) {
        await prefs.setString(_prefHappyHourVerKey, cleanVer);
      }
    } catch (e) {
      debugPrint('[ApiService] Persist happy hour warning: $e');
    }
  }

  /// Returns a stable anonymous guest ID for FCM topic/device registration before OTP login.
  Future<String> getOrCreateGuestDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = (prefs.getString(_prefGuestDeviceIdKey) ?? '').trim();
    if (existing.isNotEmpty) return existing;
    final generated =
        'guest-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${identityHashCode(this).toRadixString(36)}';
    await prefs.setString(_prefGuestDeviceIdKey, generated);
    return generated;
  }

  /// Clears memoized FCM entity/token pair (called on logout before switching back to guest).
  Future<void> clearRegisteredFcmPair() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefRegisteredFcmPairKey);
    } catch (_) {}
  }

  /// Registers the FCM token for either the logged-in customer or persistent guest ID,
  /// deduplicating repeat opens while the same (entity, token) pair remains fresh.
  Future<bool> registerCatalogPushToken({
    required String fcmToken,
    String? customerId,
    String platform = 'android',
    bool force = false,
  }) async {
    if (_inFlightFcmRegister != null) {
      try {
        await _inFlightFcmRegister;
      } catch (_) {}
    }

    final future = _registerCatalogPushTokenInternal(
      fcmToken: fcmToken,
      customerId: customerId,
      platform: platform,
      force: force,
    );
    _inFlightFcmRegister = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightFcmRegister, future)) {
        _inFlightFcmRegister = null;
      }
    }
  }

  Future<bool> _registerCatalogPushTokenInternal({
    required String fcmToken,
    String? customerId,
    String platform = 'android',
    bool force = false,
  }) async {
    final cleanToken = fcmToken.trim();
    if (cleanToken.isEmpty) return false;
    final cleanCust = (customerId ?? '').trim();
    final entityId = cleanCust.isNotEmpty ? cleanCust : await getOrCreateGuestDeviceId();

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force) {
        final recorded = prefs.getString(_prefRegisteredFcmPairKey) ?? '';
        final parts = recorded.split('|');
        if (parts.length == 3 && parts[0] == entityId && parts[1] == cleanToken) {
          final ts = int.tryParse(parts[2]) ?? 0;
          if (ts > 0 &&
              DateTime.now().millisecondsSinceEpoch - ts < _fcmPairRefreshTtl.inMilliseconds) {
            return true;
          }
        }
      }

      final ok = await registerDeviceToken(
        entityId: entityId,
        personaType: 'CUSTOMER',
        fcmToken: cleanToken,
        platform: platform,
      );
      if (ok) {
        await prefs.setString(
          _prefRegisteredFcmPairKey,
          '$entityId|$cleanToken|${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      return ok;
    } catch (e) {
      debugPrint('[ApiService] registerCatalogPushToken warning: $e');
      return false;
    }
  }

  /// Fetch real CBM consumable liters & hardware warranty highlights from `/api/catalog`.
  Future<Map<String, dynamic>?> getCatalogHighlights({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedCbmHighlights != null &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _cacheTtl) {
      return _cachedCbmHighlights;
    }
    final snap = await getCatalogSnapshot(forceRefresh: forceRefresh);
    return snap.cbmHighlights ?? _cachedCbmHighlights;
  }

  /// Checks Redis-backed `/api/sync/versions` and fetches `/api/catalog` or `/api/happy-hours/status`
  /// ONLY when local cached versions are missing, marked dirty by FCM, or differ from Redis.
  Future<VersionSyncResult> syncWithRedisVersionsOnly({
    bool bypassCooldown = false,
    bool forceCatalogRefresh = false,
  }) {
    if (_inFlightVersionSync != null && !forceCatalogRefresh) {
      return _inFlightVersionSync!;
    }
    final future = _performVersionSync(
      bypassCooldown: bypassCooldown,
      forceCatalogRefresh: forceCatalogRefresh,
    ).whenComplete(() {
      _inFlightVersionSync = null;
    });
    _inFlightVersionSync = future;
    return future;
  }

  Future<VersionSyncResult> _performVersionSync({
    required bool bypassCooldown,
    required bool forceCatalogRefresh,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    final persistedCatalog = _cachedCatalogSnapshot ?? await _readPersistedCatalog();
    if (persistedCatalog != null) {
      _cachedCatalogSnapshot = persistedCatalog;
      _cachedCbmHighlights = persistedCatalog.cbmHighlights;
    }
    final persistedHappyHour = _cachedHappyHour ?? await readCachedHappyHour();

    final localCatalogRef =
        (persistedCatalog?.catalogRef ?? prefs.getString(_prefCatalogRefKey) ?? '').trim();
    final dirtyRef = (prefs.getString(_prefCatalogDirtyRefKey) ?? '').trim();
    final hasDirtyCatalog =
        dirtyRef.isNotEmpty && (dirtyRef == '__DIRTY__' || dirtyRef != localCatalogRef);
    final hasPopulatedCatalog =
        persistedCatalog != null &&
        (persistedCatalog.products.isNotEmpty || persistedCatalog.kits.isNotEmpty);
    final localHappyHourVer = (prefs.getString(_prefHappyHourVerKey) ?? '').trim();

    if (!bypassCooldown &&
        !forceCatalogRefresh &&
        !hasDirtyCatalog &&
        hasPopulatedCatalog &&
        persistedHappyHour != null &&
        _lastVersionGateTime != null &&
        DateTime.now().difference(_lastVersionGateTime!) < _cacheTtl) {
      return VersionSyncResult(
        catalogUpdated: false,
        happyHourUpdated: false,
        catalog: persistedCatalog,
        happyHour: persistedHappyHour,
        remoteCatalogRef: localCatalogRef,
        remoteHappyHourVersion: localHappyHourVer,
      );
    }

    String? remoteCatalogRef;
    String? remoteHappyHourVer;
    bool versionCheckSucceeded = false;

    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/sync/versions'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        if (decoded is Map && decoded['versions'] is Map) {
          final versions = decoded['versions'] as Map;
          remoteCatalogRef = (versions['catalog_ref'] ?? '').toString().trim();
          remoteHappyHourVer = (versions['happy_hour'] ?? '').toString().trim();
          versionCheckSucceeded = true;
          _lastVersionGateTime = DateTime.now();
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Redis version confirm failed ($e)');
    }

    if (!versionCheckSucceeded && !forceCatalogRefresh && !hasDirtyCatalog && hasPopulatedCatalog) {
      // Offline / transient network error with warm local cache -> zero extra requests.
      return VersionSyncResult(
        catalogUpdated: false,
        happyHourUpdated: false,
        catalog: persistedCatalog,
        happyHour: persistedHappyHour,
        remoteCatalogRef: localCatalogRef,
        remoteHappyHourVersion: localHappyHourVer,
      );
    }

    final needsCatalogFetch = forceCatalogRefresh ||
        hasDirtyCatalog ||
        !hasPopulatedCatalog ||
        (remoteCatalogRef != null &&
            remoteCatalogRef.isNotEmpty &&
            remoteCatalogRef != localCatalogRef);

    final needsHappyHourFetch = persistedHappyHour == null ||
        localHappyHourVer.isEmpty ||
        (remoteHappyHourVer != null &&
            remoteHappyHourVer.isNotEmpty &&
            remoteHappyHourVer != localHappyHourVer);

    CatalogSnapshot? updatedCatalog;
    Map<String, dynamic>? updatedHappyHour;

    await Future.wait([
      if (needsCatalogFetch)
        getCatalogSnapshot(forceRefresh: forceCatalogRefresh || hasDirtyCatalog || remoteCatalogRef != localCatalogRef)
            .then((snap) {
          if (snap.products.isNotEmpty || snap.kits.isNotEmpty || snap.categories.isNotEmpty) {
            updatedCatalog = snap;
          }
        }),
      if (needsHappyHourFetch)
        getHappyHourStatus(expectedVersion: remoteHappyHourVer).then((hh) {
          updatedHappyHour = hh;
        }),
    ]);

    return VersionSyncResult(
      catalogUpdated: updatedCatalog != null,
      happyHourUpdated: updatedHappyHour != null,
      catalog: updatedCatalog ?? persistedCatalog,
      happyHour: updatedHappyHour ?? persistedHappyHour,
      remoteCatalogRef: remoteCatalogRef,
      remoteHappyHourVersion: remoteHappyHourVer,
    );
  }

  /// Handles foreground/emergency `CATALOG_UPDATED` FCM push, deduplicating both
  /// already-loaded refs and concurrent topic+token deliveries for the same ref.
  Future<CatalogSnapshot?> handleCatalogUpdateFcmPush({
    String? catalogRef,
    bool emergency = false,
  }) async {
    final incomingRef = (catalogRef ?? '').trim();
    if (_inFlightFcmCatalogSync != null &&
        (incomingRef.isEmpty || incomingRef == (_inFlightFcmTargetRef ?? ''))) {
      debugPrint('[ApiService] FCM catalog push coalesced while ${incomingRef.isNotEmpty ? incomingRef : "latest"} fetch in flight');
      return null;
    }

    final future = _handleCatalogUpdateFcmPushInternal(
      incomingRef: incomingRef,
      emergency: emergency,
    );
    _inFlightFcmTargetRef = incomingRef;
    _inFlightFcmCatalogSync = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightFcmCatalogSync, future)) {
        _inFlightFcmCatalogSync = null;
        _inFlightFcmTargetRef = null;
      }
    }
  }

  Future<CatalogSnapshot?> _handleCatalogUpdateFcmPushInternal({
    required String incomingRef,
    required bool emergency,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final currentRef = (_cachedCatalogSnapshot?.catalogRef ??
            prefs.getString(_prefCatalogRefKey) ??
            '')
        .trim();

    if (incomingRef.isNotEmpty &&
        incomingRef == currentRef &&
        _cachedCatalogSnapshot != null &&
        (_cachedCatalogSnapshot!.products.isNotEmpty ||
            _cachedCatalogSnapshot!.kits.isNotEmpty)) {
      await prefs.remove(_prefCatalogDirtyRefKey);
      debugPrint('[ApiService] FCM catalog push skipped duplicate ref $incomingRef');
      return null;
    }

    debugPrint(
      '[ApiService] FCM ${emergency ? "EMERGENCY " : ""}catalog sync ($currentRef -> ${incomingRef.isNotEmpty ? incomingRef : "latest"})',
    );
    final snap = await getCatalogSnapshot(forceRefresh: true);
    await prefs.remove(_prefCatalogDirtyRefKey);
    return snap;
  }

  /// Checks lightweight `/api/sync/versions` (`catalog_ref`) and refreshes `/api/catalog` only if version changed.
  Future<CatalogSnapshot?> refreshCatalogIfVersionChanged() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/sync/versions'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        final remoteRef = (decoded is Map && decoded['versions'] is Map)
            ? (decoded['versions']['catalog_ref'] ?? '').toString().trim()
            : '';
        final currentRef = _cachedCatalogSnapshot?.catalogRef ??
            ((await SharedPreferences.getInstance()).getString(_prefCatalogRefKey) ?? '');
        if (remoteRef.isNotEmpty && remoteRef != currentRef) {
          return await getCatalogSnapshot(forceRefresh: true);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fetches live unified catalog (CBM SQL + DynamoDB metadata + S3 photos) with ETag / 304 caching.
  Future<CatalogSnapshot> getCatalogSnapshot({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedCatalogSnapshot != null &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _cacheTtl) {
      return _cachedCatalogSnapshot!;
    }

    if (_inFlightCatalogFetch != null && (!forceRefresh || _inFlightCatalogForceRefresh)) {
      return _inFlightCatalogFetch!;
    }

    _inFlightCatalogForceRefresh = forceRefresh;
    final future = _fetchCatalogSnapshotInternal(forceRefresh: forceRefresh).whenComplete(() {
      _inFlightCatalogFetch = null;
      _inFlightCatalogForceRefresh = false;
    });
    _inFlightCatalogFetch = future;
    return future;
  }

  Future<CatalogSnapshot> _fetchCatalogSnapshotInternal({bool forceRefresh = false}) async {
    final persisted = _cachedCatalogSnapshot ?? await _readPersistedCatalog();
    final knownRef = persisted?.catalogRef ?? '';

    try {
      final catalogUri = forceRefresh
          ? Uri.parse('$baseUrl/api/catalog?fresh=1')
          : Uri.parse('$baseUrl/api/catalog');
      final headers = <String, String>{};
      if (!forceRefresh && knownRef.isNotEmpty) {
        headers['If-None-Match'] = '"$knownRef"';
      }

      final response = await _client
          .get(catalogUri, headers: headers)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 304 && persisted != null) {
        _cachedCatalogSnapshot = persisted;
        _cachedCbmHighlights = persisted.cbmHighlights;
        _lastFetchTime = DateTime.now();
        debugPrint('[ApiService] Catalog ETag 304 Not Modified ($knownRef)');
        return persisted;
      }

      if (response.statusCode == 200) {
        final rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        final decoded = json.decode(rawBody);
        if (decoded is Map) {
          final snap = CatalogSnapshot.fromJson(Map<String, dynamic>.from(decoded));
          _cachedCatalogSnapshot = snap;
          _cachedCbmHighlights = snap.cbmHighlights;
          _lastFetchTime = DateTime.now();
          await _persistCatalog(snap.catalogRef, rawBody);
          debugPrint('[ApiService] Loaded ${snap.products.length} products & ${snap.kits.length} kits (${snap.catalogRef})');
          return snap;
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Catalog fetch error ($e). Using persisted server cache if available.');
    }

    if (persisted != null) {
      _cachedCatalogSnapshot = persisted;
      _cachedCbmHighlights = persisted.cbmHighlights;
      return persisted;
    }

    return CatalogSnapshot.empty();
  }

  /// Fetch live products + kits from backend without any hardcoded mock fallback.
  Future<List<Product>> getCatalog({bool forceRefresh = false}) async {
    final snap = await getCatalogSnapshot(forceRefresh: forceRefresh);
    return snap.allBrowseItems;
  }

  /// Check pincode serviceability against backend location hubs
  Future<Map<String, dynamic>> checkPincode(String pincode) async {
    final cleanPin = pincode.trim();
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/pincodes/${Uri.encodeComponent(cleanPin)}'),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('[ApiService] Pincode check failed ($e)');
    }

    return {
      'pincode': cleanPin,
      'serviceable': false,
      'hub': null,
      'error': 'Unable to verify serviceability right now',
    };
  }

  /// Check Meta-Ad Radius doorstep serviceability against active manager clusters
  Future<Map<String, dynamic>> checkServiceability({
    required double latitude,
    required double longitude,
    String? pincode,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/serviceability/check'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'latitude': latitude,
              'longitude': longitude,
              'pincode': pincode,
            }),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('[ApiService] Serviceability check failed ($e)');
    }

    return {
      'serviceable': false,
      'message': 'Unable to verify service coverage. Please retry.',
    };
  }

  /// Submit customer expansion interest lead ("Coming Soon / Notify Me")
  Future<Map<String, dynamic>> expressExpansionInterest({
    required String addressText,
    required double latitude,
    required double longitude,
    String? customerEntityId,
    String? customerName,
    String? customerPhone,
    String? pincode,
    String? city,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/serviceability/express-interest'),
            headers: jsonHeaders(),
            body: json.encode({
              'customer_entity_id': customerEntityId,
              'customer_name': customerName,
              'customer_phone': customerPhone,
              'latitude': latitude,
              'longitude': longitude,
              'address_text': addressText,
              'pincode': pincode,
              'city': city,
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('[ApiService] expressExpansionInterest failed: $e');
    }
    return {'success': false, 'error': 'Network timeout'};
  }

  /// Book Doorstep RO Service with Preferred Slot
  Future<Map<String, dynamic>> bookServiceVisit({
    required String phone,
    required String address,
    required String pincode,
    String? customerId,
    String? fullName,
    double? latitude,
    double? longitude,
    String? preferredSlot,
    String? promoCode,
  }) async {
    try {
      final idempotencyKey = PhoneNormalizer.generateUniqueRef('srv');
      final resolvedCustId = PhoneNormalizer.toCustomerId(customerId);
      final cleanPromo = (promoCode ?? '').trim().toUpperCase();
      final response = await _client.post(
        Uri.parse('$baseUrl/api/visits'),
        headers: jsonHeaders(),
        body: json.encode({
          'phone': phone,
          if (resolvedCustId.isNotEmpty) 'customer_id': resolvedCustId,
          if (fullName != null && fullName.trim().isNotEmpty)
            'full_name': fullName.trim(),
          'service_address': address,
          'service_pincode': pincode,
          'latitude': latitude,
          'longitude': longitude,
          'booking_type': 'SCHEDULED_SLOT',
          'preferred_slot': preferredSlot,
          if (cleanPromo.isNotEmpty) 'promo_code': cleanPromo,
          'idempotency_key': idempotencyKey,
        }),
      ).timeout(const Duration(seconds: 8));

      final rawBody = response.body.trim();
      if (rawBody.isNotEmpty) {
        final decoded = json.decode(rawBody);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      }
      return {'success': false, 'error': 'Booking failed (${response.statusCode})'};
    } catch (e) {
      debugPrint('[ApiService] Book service failed: $e');
    }
    return {'success': false, 'error': 'Failed to connect to booking server'};
  }

  /// Select customer preferred time slot for next-day scheduled visits
  Future<Map<String, dynamic>> updatePreferredTimeSlot(String visitId, String slot) async {
    try {
      final encodedId = Uri.encodeComponent(visitId.trim());
      final response = await _client.patch(
        Uri.parse('$baseUrl/api/visits/$encodedId/preferred-slot'),
        headers: jsonHeaders(),
        body: json.encode({'preferred_slot': slot}),
      ).timeout(const Duration(seconds: 4));
      return json.decode(response.body);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Respond to a technician-initiated mutual cancellation (APPROVE or REJECT)
  Future<Map<String, dynamic>> respondToMutualCancel(
    String visitId, {
    required String decision,
    String? reason,
  }) {
    final encodedId = Uri.encodeComponent(visitId.trim());
    return _postAuthedJson('/api/visits/$encodedId/mutual-cancel/respond', {
      'decision': decision,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    });
  }

  /// Submit a verified customer star rating + optional written review for a completed visit
  Future<Map<String, dynamic>> rateServiceVisit({
    required String visitId,
    required int rating,
    List<String> tags = const [],
    String? reviewText,
  }) {
    final encodedId = Uri.encodeComponent(visitId.trim());
    return _postAuthedJson('/api/visits/$encodedId/rate', {
      'rating': rating,
      if (tags.isNotEmpty) 'tags': tags,
      if (reviewText != null && reviewText.trim().isNotEmpty) 'review_text': reviewText.trim(),
    });
  }

  /// Fetch real aggregate stats (RDS) & written customer feedback (DynamoDB) for a technician
  Future<Map<String, dynamic>> getTechnicianReviews(String technicianId, {int limit = 20}) async {
    final cleanId = technicianId.trim();
    if (cleanId.isEmpty) {
      return {
        'success': true,
        'rating_avg': null,
        'rating_count': 0,
        'completed_jobs_count': 0,
        'reviews': const [],
      };
    }
    final encoded = Uri.encodeComponent(cleanId);
    return _fetchReviewsUri(Uri.parse('$baseUrl/api/technicians/$encoded/reviews?limit=$limit'));
  }

  /// Fetch technician stats & customer reviews resolved server-side by visit ID (exposes zero technician ID).
  Future<Map<String, dynamic>> getVisitReviews(String visitId, {int limit = 20}) async {
    final cleanId = visitId.trim();
    if (cleanId.isEmpty) {
      return {
        'success': true,
        'rating_avg': null,
        'rating_count': 0,
        'completed_jobs_count': 0,
        'reviews': const [],
      };
    }
    final encoded = Uri.encodeComponent(cleanId);
    return _fetchReviewsUri(Uri.parse('$baseUrl/api/visits/$encoded/reviews?limit=$limit'));
  }

  Future<Map<String, dynamic>> _fetchReviewsUri(Uri uri) async {
    try {
      final response = await _client
          .get(uri, headers: jsonHeaders(includeAuth: false))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
      return {
        'success': false,
        'reviews': const [],
        'error': 'Unable to load reviews (${response.statusCode})',
      };
    } catch (e) {
      debugPrint('[ApiService] _fetchReviewsUri error: $e');
      return {
        'success': false,
        'reviews': const [],
        'error': 'Unable to load reviews right now.',
      };
    }
  }

  /// Upgrade customer service visit to Complete Service (₹149)
  Future<Map<String, dynamic>> upgradeServiceVisit(String visitId) async {
    try {
      final encodedId = Uri.encodeComponent(visitId.trim());
      final response = await _client.post(
        Uri.parse('$baseUrl/api/visits/$encodedId/upgrade-plan'),
        headers: jsonHeaders(),
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      final fallbackRes = await _client.patch(
        Uri.parse('$baseUrl/api/visits/$encodedId/upgrade'),
        headers: jsonHeaders(),
      ).timeout(const Duration(seconds: 5));
      return json.decode(fallbackRes.body);
    } catch (e) {
      debugPrint('[ApiService] upgradeServiceVisit error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Submit in-service support ticket to Hub Manager Panel via Webhook
  Future<Map<String, dynamic>> submitSupportTicket({
    required String visitId,
    required String message,
    String? customerId,
    String? issueType,
  }) async {
    try {
      final resolvedCustomerId = PhoneNormalizer.toCustomerId(customerId);
      final res = await _client.post(
        Uri.parse('$baseUrl/api/support/ticket'),
        headers: jsonHeaders(),
        body: json.encode({
          'visit_id': visitId,
          if (resolvedCustomerId.isNotEmpty) 'customer_id': resolvedCustomerId,
          'message': message,
          'issue_type': issueType ?? 'DOORSTEP_ASSISTANCE',
          'source': 'CUSTOMER_APP_DOORSTEP',
        }),
      ).timeout(const Duration(seconds: 4));
      return json.decode(res.body);
    } catch (e) {
      debugPrint('[ApiService] submitSupportTicket error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Poll live active visit status (reveals 4-digit arrival OTP upon ARRIVED status, or completed visit, supports versioned caching)
  Future<Map<String, dynamic>?> getActiveVisit({
    String? phone,
    String? customerId,
    int? trackingVersion,
  }) async {
    try {
      final queryParams = <String, String>{};
      if (customerId != null && customerId.trim().isNotEmpty) {
        queryParams['customer_id'] = customerId.trim();
      }
      if (phone != null && phone.trim().isNotEmpty) {
        queryParams['phone'] = phone.trim();
      }
      if (trackingVersion != null && trackingVersion > 0) {
        queryParams['tracking_v'] = trackingVersion.toString();
      }
      final uri = Uri.parse('$baseUrl/api/visits/active').replace(
        queryParameters: queryParams.isEmpty ? null : queryParams,
      );
      final response = await _client
          .get(uri, headers: jsonHeaders())
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          if (data['unchanged'] == true) {
            return {
              'unchanged': true,
              'tracking_version': data['tracking_version'],
              'status': data['status'],
            };
          }
          if (data['active_visit'] != null) {
            final active = Map<String, dynamic>.from(data['active_visit']);
            if (data['tracking_version'] != null) {
              active['tracking_version'] = data['tracking_version'];
            }
            return active;
          } else if (data['completed_visit'] != null) {
            final comp = Map<String, dynamic>.from(data['completed_visit']);
            comp['status'] = 'COMPLETED';
            return comp;
          } else if (data['cancelled_visit'] != null) {
            final cancelled = Map<String, dynamic>.from(data['cancelled_visit']);
            cancelled['status'] = (cancelled['status'] ?? 'CANCELLED').toString();
            return cancelled;
          }
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Active visit check failed ($e)');
    }
    return null;
  }

  /// Get verified genuine spares purchases for a service visit (webhook settled)
  Future<Map<String, dynamic>?> getVisitPurchases(String visitId, {String? customerId}) async {
    try {
      final encodedId = Uri.encodeComponent(visitId.trim());
      final resolvedCust = PhoneNormalizer.toCustomerId(customerId);
      final q = resolvedCust.isNotEmpty
          ? '?customer_id=${Uri.encodeComponent(resolvedCust)}'
          : '';
      final res = await _client.get(
        Uri.parse('$baseUrl/api/customer/visit-purchases/$encodedId$q'),
        headers: {
          'Accept': 'application/json',
          if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        },
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[ApiService] Failed fetching visit purchases: $e');
    }
    return null;
  }

  /// Dynamic Happy Hour status check from PostgreSQL RDS
  Future<Map<String, dynamic>?> getHappyHourStatus({
    int? serviceAreaId,
    String? expectedVersion,
  }) async {
    try {
      final query = serviceAreaId != null ? '?service_area_id=$serviceAreaId' : '';
      final response = await _client
          .get(Uri.parse('$baseUrl/api/happy-hours/status$query'))
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map && data['success'] == true) {
          final typed = Map<String, dynamic>.from(data);
          await persistHappyHour(typed, version: expectedVersion);
          return typed;
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Happy hour check failed ($e)');
    }
    return null;
  }

  /// Registers device FCM push token with backend RDS and claims active device status.
  Future<bool> registerDeviceToken({
    required String entityId,
    required String personaType,
    required String fcmToken,
    String platform = 'android',
    String? deviceModel,
    bool isActive = true,
  }) async {
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/notifications/register-token'),
        headers: jsonHeaders(),
        body: json.encode({
          'entity_id': entityId,
          'persona_type': personaType,
          'fcm_token': fcmToken,
          'platform': platform,
          'device_model': deviceModel,
          'is_active': isActive,
        }),
      ).timeout(const Duration(seconds: 4));
      if (res.statusCode == 401 && _onUnauthorizedRefresh != null) {
        final refreshed = await _onUnauthorizedRefresh!();
        if (refreshed != null && refreshed.isNotEmpty) {
          final retryRes = await _client.post(
            Uri.parse('$baseUrl/api/notifications/register-token'),
            headers: jsonHeaders(),
            body: json.encode({
              'entity_id': entityId,
              'persona_type': personaType,
              'fcm_token': fcmToken,
              'platform': platform,
              'device_model': deviceModel,
              'is_active': isActive,
            }),
          ).timeout(const Duration(seconds: 4));
          return retryRes.statusCode == 200;
        }
        return false;
      }
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Unregisters device FCM push token on logout
  Future<bool> unregisterDeviceToken({
    required String entityId,
    required String fcmToken,
  }) async {
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/notifications/unregister-token'),
        headers: jsonHeaders(),
        body: json.encode({
          'entity_id': entityId,
          'fcm_token': fcmToken,
        }),
      ).timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Verify Doorstep Spare QR Code (Kit or Part)
  Future<Map<String, dynamic>?> verifyQr(String serial) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/catalog/verify-qr/${Uri.encodeComponent(serial.trim())}'),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('[ApiService] QR verification failed ($e)');
    }
    return null;
  }

  /// Send live customer OTP (returns dynamic OTP code for on-screen test display)
  Future<Map<String, dynamic>> sendOtp(String phone) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/auth/otp/send'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'phone': phone}),
      ).timeout(const Duration(seconds: 4));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] Send OTP failed: $e');
      return {'success': false, 'error': 'Network connection failed'};
    }
  }

  /// Verify customer OTP and log in
  Future<Map<String, dynamic>> verifyOtp({
    required String phone,
    required String otp,
    String? fullName,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/auth/otp/verify'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'phone': phone,
          'otp': otp,
          'full_name': fullName ?? 'Valued Customer',
        }),
      ).timeout(const Duration(seconds: 4));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] Verify OTP failed: $e');
      return {'success': false, 'error': 'Verification failed'};
    }
  }

  /// Update customer profile (Name, email, default address)
  Future<Map<String, dynamic>> updateProfile({
    required String phone,
    required String fullName,
    String? customerId,
    String? email,
    String? orderNumber,
    String? defaultAddress,
    String? defaultPincode,
  }) async {
    try {
      final payload = <String, dynamic>{
        'phone': phone,
        'full_name': fullName,
      };
      if (customerId != null && customerId.isNotEmpty) payload['customer_id'] = customerId;
      if (email != null) payload['email'] = email.trim();
      if (orderNumber != null && orderNumber.trim().isNotEmpty) payload['order_number'] = orderNumber.trim();
      if (defaultAddress != null) payload['default_address'] = defaultAddress;
      if (defaultPincode != null) payload['default_pincode'] = defaultPincode;

      final response = await _client.post(
        Uri.parse('$baseUrl/api/customers/profile'),
        headers: jsonHeaders(),
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 15));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] Update profile failed: $e');
      return {'success': false, 'error': 'Failed to update profile'};
    }
  }

  /// Fetch customer profile (Name, notification email, default address)
  Future<Map<String, dynamic>> getCustomerProfile({
    String? customerId,
    String? phone,
  }) async {
    try {
      final qp = <String, String>{
        if (customerId != null && customerId.trim().isNotEmpty) 'customer_id': customerId.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      };
      if (qp.isEmpty) return {'success': false};
      final uri = Uri.parse('$baseUrl/api/customers/profile').replace(queryParameters: qp);
      final response = await _client.get(uri, headers: jsonHeaders()).timeout(const Duration(seconds: 8));
      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'success': false};
    } catch (e) {
      debugPrint('[ApiService] getCustomerProfile failed: $e');
      return {'success': false};
    }
  }

  /// Health check
  Future<bool> isBackendHealthy() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Refresh 30-day Access Token using Refresh Token
  Future<Map<String, dynamic>> refreshToken(String refreshToken) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/auth/token/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      ).timeout(const Duration(seconds: 4));

      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        decoded['statusCode'] ??= response.statusCode;
        return decoded;
      }
      if (decoded is Map) {
        return {
          ...Map<String, dynamic>.from(decoded),
          'statusCode': response.statusCode,
        };
      }
      return {
        'success': false,
        'statusCode': response.statusCode,
        'error': 'Invalid refresh response',
      };
    } catch (e) {
      debugPrint('[ApiService] Refresh token failed: $e');
      return {'success': false, 'error': 'Failed to refresh token'};
    }
  }

  /// Send 6-digit WhatsApp OTP to customer
  Future<Map<String, dynamic>> sendCustomerOtp(String phone) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/customer/auth/otp/send'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'phone': phone}),
      ).timeout(const Duration(seconds: 15));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] sendCustomerOtp failed: $e');
      return {'success': false, 'error': 'Network connection failed: $e'};
    }
  }

  /// Verify 6-digit customer OTP and provision via CBM
  Future<Map<String, dynamic>> verifyCustomerOtp({
    required String phone,
    required String otp,
    String? fullName,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/customer/auth/otp/verify'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'phone': phone,
          'otp': otp,
          'full_name': fullName ?? 'Valued Customer',
        }),
      ).timeout(const Duration(seconds: 15));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] verifyCustomerOtp failed: $e');
      return {'success': false, 'error': 'Verification failed: $e'};
    }
  }

  /// Save customer address to CBM DynamoDB Shared Address Book
  Future<Map<String, dynamic>> saveCustomerAddress({
    String? phone,
    String? customerId,
    String? addressId,
    String? sk,
    String? addressType,
    String? recipientName,
    String? recipientPhone,
    String? houseNo,
    String? street,
    String? landmark,
    String? city,
    String? state,
    required String label,
    required String addressLine,
    String? pincode,
    double? latitude,
    double? longitude,
    bool isDefault = false,
  }) async {
    try {
      final target = PhoneNormalizer.toCustomerId(
        (customerId != null && customerId.trim().isNotEmpty) ? customerId : phone,
      );
      if (target.isEmpty) {
        return {'success': false, 'error': 'Customer identity required'};
      }
      final response = await _client.post(
        Uri.parse('$baseUrl/api/customer/addresses'),
        headers: jsonHeaders(),
        body: json.encode({
          'customer_id': target,
          'phone': phone,
          'address_id': addressId,
          'sk': sk,
          if (addressType != null) 'address_type': addressType,
          if (recipientName != null) 'recipient_name': recipientName,
          if (recipientPhone != null) 'recipient_phone': recipientPhone,
          if (houseNo != null) 'house_no': houseNo,
          if (street != null) 'street': street,
          if (landmark != null) 'landmark': landmark,
          if (city != null) 'city': city,
          if (state != null) 'state': state,
          'label': label,
          'address_line': addressLine,
          'pincode': pincode,
          'latitude': latitude,
          'longitude': longitude,
          'is_default': isDefault,
        }),
      ).timeout(const Duration(seconds: 5));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] saveCustomerAddress failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Update an existing customer address in DynamoDB & RDS SSoT (In-Place Mutation)
  Future<Map<String, dynamic>> updateCustomerAddress({
    String? phone,
    String? customerId,
    required String addressId,
    String? sk,
    String? addressType,
    String? recipientName,
    String? recipientPhone,
    String? houseNo,
    String? street,
    String? landmark,
    String? city,
    String? state,
    required String label,
    required String addressLine,
    String? pincode,
    double? latitude,
    double? longitude,
    bool isDefault = false,
  }) async {
    try {
      final target = PhoneNormalizer.toCustomerId(
        (customerId != null && customerId.trim().isNotEmpty) ? customerId : phone,
      );
      if (target.isEmpty) {
        return {'success': false, 'error': 'Customer identity required'};
      }
      final response = await _client.post(
        Uri.parse('$baseUrl/api/customer/addresses/update'),
        headers: jsonHeaders(),
        body: json.encode({
          'customer_id': target,
          'phone': phone,
          'address_id': addressId,
          'sk': sk,
          if (addressType != null) 'address_type': addressType,
          if (recipientName != null) 'recipient_name': recipientName,
          if (recipientPhone != null) 'recipient_phone': recipientPhone,
          if (houseNo != null) 'house_no': houseNo,
          if (street != null) 'street': street,
          if (landmark != null) 'landmark': landmark,
          if (city != null) 'city': city,
          if (state != null) 'state': state,
          'label': label,
          'address_line': addressLine,
          'pincode': pincode,
          'latitude': latitude,
          'longitude': longitude,
          'is_default': isDefault,
        }),
      ).timeout(const Duration(seconds: 5));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] updateCustomerAddress failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Delete customer address permanently from DynamoDB & RDS SSoT
  Future<Map<String, dynamic>> deleteCustomerAddress({
    String? phone,
    String? customerId,
    required String addressId,
    String? sk,
  }) async {
    try {
      final target = PhoneNormalizer.toCustomerId(
        (customerId != null && customerId.trim().isNotEmpty) ? customerId : phone,
      );
      if (target.isEmpty) {
        return {'success': false, 'error': 'Customer identity required'};
      }
      final response = await _client.post(
        Uri.parse('$baseUrl/api/customer/addresses/delete'),
        headers: jsonHeaders(),
        body: json.encode({
          'customer_id': target,
          'phone': phone,
          'address_id': addressId,
          'sk': sk,
        }),
      ).timeout(const Duration(seconds: 5));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] deleteCustomerAddress failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Fetch all saved addresses from DynamoDB SSoT (pk: USER#c-XXXXXXXXXX)
  Future<List<Map<String, dynamic>>> getCustomerAddresses(String phoneOrCustomerId) async {
    try {
      final target = PhoneNormalizer.toCustomerId(phoneOrCustomerId);
      if (target.isEmpty) return [];
      final response = await _client.get(
        Uri.parse(
          '$baseUrl/api/customer/addresses?customer_id=${Uri.encodeComponent(target)}',
        ),
        headers: jsonHeaders(),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['addresses'] is List) {
          return List<Map<String, dynamic>>.from(data['addresses']);
        }
      }
      return [];
    } catch (e) {
      debugPrint('[ApiService] getCustomerAddresses failed: $e');
      return [];
    }
  }

  /// High-accuracy Reverse Geocoding with Ola Maps
  Future<Map<String, String>> reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse(
        'https://api.olamaps.io/places/v1/reverse-geocode?latlng=$lat,$lng&api_key=$olaMapsApiKey',
      );
      final response = await _client.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'ok' && data['results'] != null && (data['results'] as List).isNotEmpty) {
          final first = data['results'][0];
          final formatted = first['formatted_address']?.toString() ?? '';
          String pincode = '';
          String city = '';
          String area = formatted;
          if (first['address_components'] is List) {
            for (final comp in first['address_components']) {
              final types = comp['types'] as List? ?? [];
              if (types.contains('postal_code')) {
                pincode = comp['long_name']?.toString() ?? '';
              }
              if (types.contains('locality') || types.contains('administrative_area_level_2')) {
                city = comp['long_name']?.toString() ?? city;
              }
              if (types.contains('sublocality') || types.contains('neighborhood')) {
                area = comp['long_name']?.toString() ?? area;
              }
            }
          }
          return {
            'area': area,
            'city': city,
            'pincode': pincode,
            'formattedAddress': formatted,
          };
        }
      }
    } catch (e) {
      debugPrint('[ApiService] reverseGeocode fallback: $e');
    }
    return {
      'area': '',
      'city': '',
      'pincode': '',
      'formattedAddress': '',
    };
  }

  /// Book Filter Replacement Service
  Future<Map<String, dynamic>> bookService({
    required String phone,
    required String address,
    required String pincode,
    String? fullName,
    double? latitude,
    double? longitude,
    String? scheduledDate,
    String? slot,
    String? kitSku,
  }) async {
    try {
      final cleanName = fullName?.trim();
      final response = await _client.post(
        Uri.parse('$baseUrl/api/service/book'),
        headers: jsonHeaders(),
        body: json.encode({
          'phone': phone,
          if (cleanName != null && cleanName.isNotEmpty) 'full_name': cleanName,
          'service_address': address,
          'service_pincode': pincode,
          'latitude': latitude,
          'longitude': longitude,
          'scheduled_date': scheduledDate,
          'slot': slot,
          'kit_sku': kitSku ?? 'KIT-2STAGE',
        }),
      ).timeout(const Duration(seconds: 6));

      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] bookService failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  Map<String, dynamic> _normalizeCheckoutStatus(Map<String, dynamic> raw) {
    final normalized = Map<String, dynamic>.from(raw);
    final sessionMap = raw['session'] is Map
        ? Map<String, dynamic>.from(raw['session'] as Map)
        : null;
    final rawStatus = (raw['status'] ?? sessionMap?['status'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    final isCleared = raw['paid'] == true ||
        raw['is_cleared'] == true ||
        raw['already_paid'] == true ||
        rawStatus == 'CLEARED' ||
        rawStatus == 'PAID' ||
        rawStatus == 'COMPLETED' ||
        rawStatus == 'SETTLED';
    final isExpired = raw['is_expired'] == true || rawStatus == 'EXPIRED';
    final isRefunded = raw['is_refunded'] == true || rawStatus == 'REFUNDED';
    final isFailed = raw['is_failed'] == true ||
        isExpired ||
        rawStatus == 'FAILED' ||
        rawStatus == 'CANCELLED' ||
        rawStatus == 'DECLINED';
    final gateway = (raw['gateway'] ??
            raw['payment_gateway'] ??
            sessionMap?['payment_gateway'])
        ?.toString();

    normalized['success'] = raw['success'] ?? true;
    normalized['status'] = rawStatus.isNotEmpty
        ? rawStatus
        : (isCleared ? 'CLEARED' : 'PENDING_PAYMENT');
    normalized['paid'] = isCleared;
    normalized['is_cleared'] = isCleared;
    normalized['already_paid'] = raw['already_paid'] == true || isCleared;
    normalized['is_failed'] = isFailed;
    normalized['is_expired'] = isExpired;
    normalized['is_refunded'] = isRefunded;
    if (gateway != null && gateway.isNotEmpty) {
      normalized['gateway'] = gateway;
    }
    final rzpKeyId = (raw['razorpay_key_id'] ??
            raw['key_id'] ??
            sessionMap?['razorpay_key_id'] ??
            sessionMap?['key_id'])
        ?.toString()
        .trim();
    if (rzpKeyId != null && rzpKeyId.isNotEmpty) {
      normalized['razorpay_key_id'] = rzpKeyId;
    }
    final rzpOrderId = (raw['rzp_order_id'] ??
            raw['razorpay_order_id'] ??
            sessionMap?['rzp_order_id'] ??
            sessionMap?['razorpay_order_id'])
        ?.toString()
        .trim();
    if (rzpOrderId != null && rzpOrderId.isNotEmpty) {
      normalized['rzp_order_id'] = rzpOrderId;
    }
    final gwOrderId = (raw['gateway_order_id'] ?? sessionMap?['gateway_order_id'])
        ?.toString()
        .trim();
    if (gwOrderId != null && gwOrderId.isNotEmpty) {
      normalized['gateway_order_id'] = gwOrderId;
    }
    final upiUri = (raw['upi_uri'] ?? sessionMap?['upi_uri'])?.toString().trim();
    if (upiUri != null && upiUri.isNotEmpty) {
      normalized['upi_uri'] = upiUri;
    }
    if (raw['failover'] is Map) {
      normalized['failover'] = Map<String, dynamic>.from(raw['failover'] as Map);
    }
    if (raw['refund_id'] != null) {
      normalized['refund_id'] = raw['refund_id'].toString();
    }
    return normalized;
  }

  /// Poll Checkout Payment Clearance Status (CBM Unified Status First + EC2 Fallback)
  Future<Map<String, dynamic>> checkCheckoutStatus(
    String refId, {
    bool live = false,
  }) async {
    final encodedRef = Uri.encodeComponent(refId.trim());
    final liveQuery = live ? '?live=1' : '';
    final requestTimeout = Duration(seconds: live ? 4 : 3);
    // 1. Check CBM Unified Checkout Status First
    try {
      final cfResponse = await _client
          .get(Uri.parse('$cbmBaseUrl/v1/checkout/status/$encodedRef$liveQuery'))
          .timeout(requestTimeout);
      if (cfResponse.statusCode == 200) {
        final decoded = json.decode(cfResponse.body);
        if (decoded is Map<String, dynamic>) {
          return _normalizeCheckoutStatus(decoded);
        }
        if (decoded is Map) {
          return _normalizeCheckoutStatus(Map<String, dynamic>.from(decoded));
        }
      } else if (cfResponse.statusCode == 404) {
        debugPrint('[ApiService] CBM checkout status 404 for $refId, falling back to EC2');
      }
    } catch (e) {
      debugPrint('[ApiService] CBM checkout status check failed ($e)');
    }

    // 2. Fallback to EC2 customer checkout status
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/customer/checkout/status/$encodedRef$liveQuery'),
            headers: jsonHeaders(),
          )
          .timeout(requestTimeout);

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) {
          return _normalizeCheckoutStatus(decoded);
        }
        if (decoded is Map) {
          return _normalizeCheckoutStatus(Map<String, dynamic>.from(decoded));
        }
      }
      if (response.statusCode == 404) {
        return {
          'success': false,
          'status': 'NOT_FOUND',
          'paid': false,
          'is_cleared': false,
          'is_failed': false,
          'is_expired': false,
          'gateway': null,
        };
      }
    } catch (e) {
      debugPrint('[ApiService] checkCheckoutStatus failed: $e');
    }

    return {
      'success': false,
      'status': 'PENDING_PAYMENT',
      'paid': false,
      'is_cleared': false,
      'is_failed': false,
      'is_expired': false,
      'gateway': null,
    };
  }

  /// Parses an incoming SSE line stream into structured checkout event maps.
  @visibleForTesting
  static Stream<Map<String, dynamic>> parseCheckoutSseLines(Stream<String> lines) async* {
    String currentEvent = '';
    final dataBuf = StringBuffer();

    await for (final line in lines) {
      if (line.isEmpty) {
        if (dataBuf.isNotEmpty) {
          final rawData = dataBuf.toString().trim();
          dataBuf.clear();
          final ev = currentEvent;
          currentEvent = '';
          try {
            final decoded = json.decode(rawData);
            if (decoded is Map) {
              final map = Map<String, dynamic>.from(decoded);
              if (ev.isNotEmpty) map['_event'] = ev;
              yield map;
            }
          } catch (_) {}
        } else {
          currentEvent = '';
        }
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (dataBuf.isNotEmpty) dataBuf.write('\n');
        dataBuf.write(line.substring(5).trimLeft());
      }
    }

    if (dataBuf.isNotEmpty) {
      try {
        final decoded = json.decode(dataBuf.toString().trim());
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          if (currentEvent.isNotEmpty) map['_event'] = currentEvent;
          yield map;
        }
      } catch (_) {}
    }
  }

  /// Advisory SSE listener backed by EC2 Redis Pub/Sub (`GET /api/customer/checkout/events/:refId`).
  /// Fails silently if upstream is unreachable so authoritative polling continues unaffected.
  Stream<Map<String, dynamic>> watchCheckoutClearanceEvents(String refId) {
    final cleanRef = refId.trim();
    if (cleanRef.isEmpty) return const Stream.empty();

    final encodedRef = Uri.encodeComponent(cleanRef);
    late final StreamController<Map<String, dynamic>> controller;
    StreamSubscription<Map<String, dynamic>>? lineSub;
    bool cancelled = false;

    controller = StreamController<Map<String, dynamic>>(
      onListen: () async {
        try {
          final request = http.Request(
            'GET',
            Uri.parse('$baseUrl/api/customer/checkout/events/$encodedRef'),
          );
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Cache-Control'] = 'no-cache';
          if (_authToken != null) {
            request.headers['Authorization'] = 'Bearer $_authToken';
          }

          final streamed = await _client.send(request).timeout(const Duration(seconds: 6));
          if (cancelled || streamed.statusCode != 200) {
            // Drain/close underlying response stream cleanly if non-200 or already cancelled
            await streamed.stream.drain<void>().catchError((_) {});
            if (!controller.isClosed) await controller.close();
            return;
          }

          final events = parseCheckoutSseLines(
            streamed.stream.transform(utf8.decoder).transform(const LineSplitter()),
          );
          lineSub = events.listen(
            (eventMap) {
              if (!controller.isClosed) {
                controller.add(eventMap);
              }
              final evName = (eventMap['_event'] ?? '').toString().toLowerCase();
              final st = (eventMap['status'] ?? '').toString().toUpperCase();
              if (evName == 'clearance' ||
                  eventMap['is_cleared'] == true ||
                  eventMap['paid'] == true ||
                  st == 'CLEARED' ||
                  st == 'REFUNDED' ||
                  st == 'EXPIRED') {
                if (!controller.isClosed) controller.close();
              }
            },
            onError: (_) {
              if (!controller.isClosed) controller.close();
            },
            onDone: () {
              if (!controller.isClosed) controller.close();
            },
            cancelOnError: true,
          );
        } catch (e) {
          debugPrint('[ApiService] SSE watchCheckoutClearanceEvents fallback: $e');
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await lineSub?.cancel();
        lineSub = null;
      },
    );

    return controller.stream;
  }

  /// Purge failed or cancelled order from DB & Order History
  Future<void> cancelFailedOrder(String orderId) async {
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/api/orders/cancel'),
            headers: jsonHeaders(),
            body: json.encode({'order_id': orderId}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[ApiService] cancelFailedOrder error: $e');
    }
  }

  /// Fetch Customer Active Purifier & 365-Day Warranty Vault Details
  Future<Map<String, dynamic>> getWarrantyVault(String phone) async {
    try {
      final clean = PhoneNormalizer.cleanPhone10(phone);
      if (clean.isEmpty) {
        return {'success': false, 'error': 'Valid customer phone is required'};
      }
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/customer/warranty/${Uri.encodeComponent(clean)}'),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {'success': false, 'error': 'Status ${response.statusCode}'};
    } catch (e) {
      debugPrint('[ApiService] getWarrantyVault failed: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Fetch public coupons separated by channel (TECHNICIAN vs ONLINE)
  Future<List<Map<String, dynamic>>> getCoupons({
    String channel = 'ALL',
    String? customerId,
  }) async {
    try {
      final queryParams = <String, String>{'channel': channel};
      final resolvedCust = PhoneNormalizer.toCustomerId(customerId);
      if (resolvedCust.isNotEmpty) {
        queryParams['customer_id'] = resolvedCust;
      }
      final uri = Uri.parse('$baseUrl/api/coupons').replace(queryParameters: queryParams);
      final response = await _client
          .get(uri, headers: jsonHeaders())
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['coupons'] is List) {
          return List<Map<String, dynamic>>.from(data['coupons']);
        }
      }
    } catch (e) {
      debugPrint('[ApiService] getCoupons failed: $e');
    }
    return [];
  }

  /// Validate coupon code against authoritative server rules & per-user limit
  Future<Map<String, dynamic>> validateCoupon({
    required String code,
    required String channel,
    required double amount,
    required double mrp,
    String? customerId,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/coupons/validate'),
            headers: jsonHeaders(),
            body: json.encode({
              'code': code.trim(),
              'channel': channel,
              'amount': amount,
              'mrp': mrp,
              'customer_id': customerId,
            }),
          )
          .timeout(const Duration(seconds: 6));
      final rawBody = response.body.trim();
      if (rawBody.isEmpty) {
        return {'success': false, 'error': 'Coupon validation failed (${response.statusCode})'};
      }
      final decoded = json.decode(rawBody);
      if (decoded is Map<String, dynamic>) {
        if (response.statusCode >= 400 && decoded['success'] != true) {
          decoded['success'] = false;
          decoded['statusCode'] = response.statusCode;
          decoded['error'] ??= decoded['message'] ?? 'Invalid coupon (${response.statusCode})';
        }
        return decoded;
      }
      return {'success': false, 'error': 'Invalid response from coupon server'};
    } catch (e) {
      debugPrint('[ApiService] validateCoupon failed: $e');
      return {'success': false, 'error': 'Network timeout or server unavailable'};
    }
  }

  /// Verify physical product or kit serial against assigned technician inventory
  Future<Map<String, dynamic>> verifyDoorstepScan({
    required String serialQr,
    int? visitId,
    String? customerId,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/doorstep/scan-verify'),
            headers: jsonHeaders(),
            body: json.encode({
              'serial_qr': serialQr.trim(),
              'visit_id': visitId,
              'customer_id': customerId,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return json.decode(response.body);
    } catch (e) {
      debugPrint('[ApiService] verifyDoorstepScan failed: $e');
      return {'success': false, 'verified': false, 'error': 'Connection timeout. Please retry.'};
    }
  }

  /// Initiate Doorstep Checkout (Razorpay Gateway Integration)
  Future<Map<String, dynamic>> initiateDoorstepCheckout({
    required int visitId,
    required String customerId,
    required List<Map<String, dynamic>> items,
    String? couponCode,
    double? amount,
    double? totalMrp,
    double? discountAmount,
    bool allowZeroComplimentary = false,
  }) async {
    try {
      final normalizedCustomerId = PhoneNormalizer.toCustomerId(customerId);
      if (normalizedCustomerId.isEmpty) {
        return {'success': false, 'error': 'Please log in with mobile number to pay.'};
      }
      final double totalAmount = amount ?? items.fold<double>(
        0.0,
        (sum, item) {
          if (item['is_complimentary'] == true) return sum;
          final p = item['price'] ?? item['mrp'] ?? 0.0;
          final double val = (p is num) ? p.toDouble() : (double.tryParse(p.toString()) ?? 0.0);
          return sum + val;
        },
      );

      final response = await _client
          .post(
            Uri.parse('$cbmBaseUrl/v1/checkout/session/initiate'),
            headers: jsonHeaders(),
            body: json.encode({
              'order_id': PhoneNormalizer.generateUniqueRef('ORD-TECH'),
              'visit_id': visitId,
              'customer_id': normalizedCustomerId,
              'amount': totalAmount,
              'net_payable': totalAmount,
              if (totalMrp != null) 'total_mrp': totalMrp,
              if (discountAmount != null) 'discount_amount': discountAmount,
              if (allowZeroComplimentary) 'allow_zero_complimentary': true,
              'items': items,
              'coupon_code': couponCode,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final rawBody = response.body.trim();
      if (rawBody.isEmpty) {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': 'Checkout failed (${response.statusCode})',
        };
      }
      final dynamic decodedRaw;
      try {
        decodedRaw = json.decode(rawBody);
      } catch (_) {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': 'Invalid checkout response (${response.statusCode})',
        };
      }
      if (decodedRaw is! Map) {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': 'Invalid checkout response from server',
        };
      }

      final decoded = Map<String, dynamic>.from(decodedRaw);
      final statusStr = (decoded['status'] ?? '').toString().trim().toUpperCase();
      if (statusStr.isNotEmpty) {
        decoded['status'] = statusStr;
      }
      final refId = (decoded['cbm_checkout_token'] ?? decoded['order_id'] ?? '')
          .toString()
          .trim();
      if (refId.isNotEmpty) {
        decoded['order_id'] = refId;
        decoded['cbm_checkout_token'] = decoded['cbm_checkout_token'] ?? refId;
      }
      final alreadyPaid = decoded['already_paid'] == true ||
          decoded['paid'] == true ||
          decoded['is_cleared'] == true ||
          statusStr == 'CLEARED' ||
          statusStr == 'PAID' ||
          statusStr == 'COMPLETED' ||
          statusStr == 'SETTLED';
      decoded['already_paid'] = alreadyPaid;

      if (statusStr == 'APPROVED' || decoded['success'] == true) {
        decoded['success'] = true;
        decoded['breakdown'] ??= {
          'mrp': totalAmount,
          'discount': 0,
          'net_payable': decoded['net_payable'] ?? totalAmount,
        };
        decoded['order'] ??= {
          'order_number': refId,
          'customer_id': customerId,
          'status': alreadyPaid ? 'CONFIRMED' : 'PENDING',
          'net_payable': decoded['net_payable'] ?? totalAmount,
        };
      } else if (response.statusCode >= 400 || decoded['success'] == false) {
        decoded['success'] = false;
        decoded['statusCode'] = response.statusCode;
        decoded['error'] ??=
            decoded['message'] ?? 'Checkout failed (${response.statusCode})';
      }
      return decoded;
    } catch (e) {
      debugPrint('[ApiService] initiateDoorstepCheckout failed: $e');
      return {'success': false, 'error': 'Checkout failed ($e)'};
    }
  }

  /// Authoritative server quote for Admin-configurable Pan-India courier charges
  Future<Map<String, dynamic>> fetchOnlineShippingQuote({
    required double subtotal,
    double discount = 0,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/online/shipping-quote').replace(
        queryParameters: {
          'subtotal': subtotal.toStringAsFixed(2),
          'discount': discount.toStringAsFixed(2),
        },
      );
      final response = await _client
          .get(uri, headers: jsonHeaders(includeAuth: false))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (e) {
      debugPrint('[ApiService] fetchOnlineShippingQuote failed: $e');
    }
    return {'success': false};
  }

  /// Pan-India PIN validator (Zero hub-radius barrier for Online E-Commerce)
  Future<Map<String, dynamic>> validateIndianOnlinePincode(String pincode) async {
    final clean = pincode.replaceAll(RegExp(r'\D'), '');
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/online/pincode/$clean'),
            headers: jsonHeaders(includeAuth: false),
          )
          .timeout(const Duration(seconds: 5));
      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      debugPrint('[ApiService] validateIndianOnlinePincode failed: $e');
    }
    return {'success': false, 'valid': false, 'error': 'Unable to validate PIN right now'};
  }

  /// Fetch Pan-India live order tracking timeline & courier details
  Future<Map<String, dynamic>> fetchOnlineOrderTracking(
    String orderNumber, {
    String? phone,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/orders/track/${Uri.encodeComponent(orderNumber)}').replace(
        queryParameters: phone != null && phone.trim().isNotEmpty ? {'phone': phone.trim()} : null,
      );
      final response = await _client
          .get(uri, headers: jsonHeaders())
          .timeout(const Duration(seconds: 6));
      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      debugPrint('[ApiService] fetchOnlineOrderTracking failed: $e');
    }
    return {'success': false, 'error': 'Unable to fetch tracking details'};
  }

  /// Create Online Store Order (COD or Online PG)
  Future<Map<String, dynamic>> createOnlineOrder({
    required String customerId,
    required List<Map<String, dynamic>> items,
    required String address,
    String? pincode,
    String? recipientName,
    String? recipientPhone,
    String? deliveryCity,
    String? deliveryState,
    required String paymentMethod,
    String? couponCode,
    String? email,
    double? expectedNetPayable,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/orders/create'),
            headers: jsonHeaders(),
            body: json.encode({
              'customer_id': customerId,
              'items': items,
              'delivery_address': address,
              'delivery_pincode': pincode,
              if (recipientName != null && recipientName.trim().isNotEmpty) 'recipient_name': recipientName.trim(),
              if (recipientPhone != null && recipientPhone.trim().isNotEmpty) 'recipient_phone': recipientPhone.trim(),
              if (deliveryCity != null && deliveryCity.trim().isNotEmpty) 'delivery_city': deliveryCity.trim(),
              if (deliveryState != null && deliveryState.trim().isNotEmpty) 'delivery_state': deliveryState.trim(),
              'payment_method': paymentMethod,
              'coupon_code': couponCode,
              if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
              if (expectedNetPayable != null) 'expected_net_payable': expectedNetPayable,
            }),
          )
          .timeout(const Duration(seconds: 12));
      final rawBody = response.body.trim();
      if (rawBody.isEmpty) {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': 'Order creation failed (${response.statusCode})',
        };
      }
      final dynamic decodedRaw;
      try {
        decodedRaw = json.decode(rawBody);
      } catch (_) {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': 'Invalid order response (${response.statusCode})',
        };
      }
      if (decodedRaw is! Map) {
        return {'success': false, 'error': 'Invalid order response from server'};
      }
      final decoded = Map<String, dynamic>.from(decodedRaw);
      final orderMap = decoded['order'] is Map
          ? Map<String, dynamic>.from(decoded['order'] as Map)
          : null;
      final orderId = (decoded['order_id'] ?? orderMap?['order_number'] ?? '')
          .toString()
          .trim();
      if (orderId.isNotEmpty) {
        decoded['order_id'] = orderId;
        decoded['order'] = orderMap ?? {'order_number': orderId};
      }
      final statusStr = (decoded['status'] ?? orderMap?['status'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      if (statusStr.isNotEmpty) {
        decoded['status'] = statusStr;
      }
      final alreadyPaid = decoded['already_paid'] == true ||
          (paymentMethod == 'ONLINE_PG' &&
              (decoded['paid'] == true ||
                  decoded['is_cleared'] == true ||
                  statusStr == 'CLEARED' ||
                  statusStr == 'PAID' ||
                  statusStr == 'COMPLETED' ||
                  statusStr == 'SETTLED'));
      decoded['already_paid'] = alreadyPaid;
      if (paymentMethod == 'ONLINE_PG' &&
          orderId.isNotEmpty &&
          (decoded['payment_url'] == null ||
              decoded['payment_url'].toString().trim().isEmpty)) {
        decoded['payment_url'] = '$cbmBaseUrl/checkout/$orderId';
      }
      if (response.statusCode >= 400 && decoded['success'] != true) {
        decoded['success'] = false;
        decoded['statusCode'] = response.statusCode;
        decoded['error'] ??=
            decoded['message'] ?? 'Order creation failed (${response.statusCode})';
      }
      return decoded;
    } catch (e) {
      debugPrint('[ApiService] createOnlineOrder failed: $e');
      return {'success': false, 'error': 'Order creation failed ($e)'};
    }
  }

  /// Get lazy-loaded unified order history with nested kit components
  Future<Map<String, dynamic>> getOrderHistory({
    required String customerId,
    int page = 1,
    int limit = 10,
  }) async {
    try {
      final encodedId = Uri.encodeComponent(customerId.trim());
      final response = await _client
          .get(
            Uri.parse(
              '$baseUrl/api/orders/history?customer_id=$encodedId&page=$page&limit=$limit',
            ),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {
        'success': false,
        'orders': <dynamic>[],
        'total': 0,
        'error': 'Failed to load orders (${response.statusCode})',
      };
    } catch (e) {
      debugPrint('[ApiService] getOrderHistory failed: $e');
      return {
        'success': false,
        'orders': <dynamic>[],
        'total': 0,
        'error': 'Network error loading orders',
      };
    }
  }

  /// Paginated completed service visits history with installed parts, TDS logs, and tech stats
  Future<Map<String, dynamic>> getServiceHistoryPage({
    required String customerId,
    int page = 1,
    int limit = 10,
  }) async {
    try {
      final encodedId = Uri.encodeComponent(customerId.trim());
      final response = await _client
          .get(
            Uri.parse(
                '$baseUrl/api/visits/history?customer_id=$encodedId&page=$page&limit=$limit'),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map && data['success'] == true && data['visits'] is List) {
          final visits = (data['visits'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          final total = int.tryParse('${data['total'] ?? ''}') ?? visits.length;
          final hasMore = data['has_more'] is bool
              ? data['has_more'] as bool
              : (page * limit < total && visits.length >= limit);
          return {
            'success': true,
            'visits': visits,
            'total': total,
            'has_more': hasMore,
          };
        }
      }
      return {
        'success': false,
        'visits': <Map<String, dynamic>>[],
        'total': 0,
        'has_more': false,
        'error': 'Server error loading service history.',
      };
    } catch (e) {
      debugPrint('[ApiService] getServiceHistoryPage failed: $e');
      return {
        'success': false,
        'visits': <Map<String, dynamic>>[],
        'total': 0,
        'has_more': false,
        'error': 'Network error loading service history.',
      };
    }
  }

  /// Get completed service visits history with TDS logs and technician info
  Future<List<Map<String, dynamic>>> getServiceHistory({required String customerId}) async {
    final res = await getServiceHistoryPage(customerId: customerId, page: 1, limit: 50);
    if (res['success'] == true && res['visits'] is List) {
      return List<Map<String, dynamic>>.from(res['visits'] as List);
    }
    return [];
  }

  /// Retry / refresh a Razorpay checkout session (creates fresh gateway attempt if needed, or returns CLEARED/REFUNDED)
  Future<Map<String, dynamic>> retryCheckoutSession(
    String orderId, {
    bool retry = true,
  }) async {
    final encodedOrderId = Uri.encodeComponent(orderId.trim());
    final query = retry ? '?retry=1' : '';
    try {
      final rzpResponse = await _client
          .get(Uri.parse('$cbmBaseUrl/v1/checkout/resolve/$encodedOrderId$query'))
          .timeout(const Duration(seconds: 9));
      final decoded = json.decode(rzpResponse.body);
      if (decoded is Map) {
        final normalized = _normalizeCheckoutStatus(Map<String, dynamic>.from(decoded));
        normalized['statusCode'] = rzpResponse.statusCode;
        return normalized;
      }
    } catch (e) {
      debugPrint('[ApiService] CBM retryCheckoutSession failed ($e), falling back to EC2');
    }

    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/checkout/retry-session/$encodedOrderId'),
            headers: jsonHeaders(),
            body: json.encode({'retry': retry}),
          )
          .timeout(const Duration(seconds: 9));
      final decoded = json.decode(response.body);
      if (decoded is Map) {
        final normalized = _normalizeCheckoutStatus(Map<String, dynamic>.from(decoded));
        normalized['statusCode'] = response.statusCode;
        return normalized;
      }
    } catch (e) {
      debugPrint('[ApiService] EC2 retryCheckoutSession failed: $e');
    }
    return {'success': false, 'error': 'Unable to refresh payment session'};
  }

  /// Verify Razorpay Custom UI payment callback signature and settle checkout on CBM Lambda
  Future<Map<String, dynamic>> verifyRazorpayPayment({
    required String orderId,
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    final cleanOrder = orderId.trim();
    final payload = {
      'checkout_id': cleanOrder,
      'order_id': cleanOrder,
      'razorpay_payment_id': razorpayPaymentId.trim(),
      'razorpay_order_id': razorpayOrderId.trim(),
      'razorpay_signature': razorpaySignature.trim(),
    };
    try {
      final res = await _client
          .post(
            Uri.parse('$cbmBaseUrl/v1/checkout/razorpay/verify'),
            headers: jsonHeaders(),
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 12));

      final rawBody = res.body.trim();
      if (rawBody.isNotEmpty) {
        final decoded = json.decode(rawBody);
        if (decoded is Map) {
          final normalized = _normalizeCheckoutStatus(Map<String, dynamic>.from(decoded));
          normalized['statusCode'] = res.statusCode;
          if (res.statusCode >= 400 && normalized['success'] != true) {
            normalized['success'] = false;
            normalized['error'] ??= normalized['message'] ??
                'Payment signature verification failed (${res.statusCode})';
          }
          return normalized;
        }
      }
      return {
        'success': res.statusCode >= 200 && res.statusCode < 300,
        'statusCode': res.statusCode,
        if (res.statusCode >= 400)
          'error': 'Payment verification failed (${res.statusCode})',
      };
    } catch (e) {
      debugPrint('[ApiService] verifyRazorpayPayment failed: $e');
      return {
        'success': false,
        'error': 'Unable to verify payment with server right now.',
      };
    }
  }

  /// Generate a live Razorpay Dynamic UPI QR linked to the checkout session
  Future<Map<String, dynamic>> createRazorpayQr({required String orderId}) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$cbmBaseUrl/v1/checkout/razorpay/qr'),
            headers: jsonHeaders(),
            body: json.encode({'order_id': orderId.trim()}),
          )
          .timeout(const Duration(seconds: 10));
      final rawBody = res.body.trim();
      if (rawBody.isNotEmpty) {
        final decoded = json.decode(rawBody);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          map['statusCode'] = res.statusCode;
          return map;
        }
      }
      return {
        'success': false,
        'statusCode': res.statusCode,
        'error': 'Unable to generate Razorpay QR (${res.statusCode})',
      };
    } catch (e) {
      debugPrint('[ApiService] createRazorpayQr failed: $e');
      return {
        'success': false,
        'error': 'Network error generating dynamic QR code.',
      };
    }
  }

  /// Request an SMS OTP for customer account deletion verification (Play Store compliance).
  Future<Map<String, dynamic>> requestAccountDeletionOtp(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
    final normalizedPhone = cleanPhone.length >= 10
        ? cleanPhone.substring(cleanPhone.length - 10)
        : cleanPhone;

    if (normalizedPhone.length != 10) {
      return {
        'success': false,
        'error': 'Valid 10-digit mobile number is required.',
      };
    }

    try {
      final res = await _client
          .post(
            Uri.parse('$cbmBaseUrl/v1/account-deletion/request-otp'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'phone': normalizedPhone}),
          )
          .timeout(const Duration(seconds: 12));

      Map<String, dynamic> map = {};
      if (res.body.trim().isNotEmpty) {
        final decoded = json.decode(res.body);
        if (decoded is Map) {
          map = Map<String, dynamic>.from(decoded);
        }
      }
      map['statusCode'] = res.statusCode;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        map['success'] = map['success'] ?? true;
      } else {
        map['success'] = false;
        map['error'] = map['error'] ??
            map['message'] ??
            'Could not send verification OTP (${res.statusCode}).';
      }
      return map;
    } catch (e) {
      debugPrint('[ApiService] requestAccountDeletionOtp failed: $e');
      return {
        'success': false,
        'error': 'Network error requesting deletion OTP.',
      };
    }
  }

  /// Delete customer account and personal data permanently via EC2 JWT or Lambda OTP fallback.
  Future<Map<String, dynamic>> deleteCustomerAccount({
    required String phone,
    String? customerId,
    String? authToken,
    String? otp,
  }) async {
    final cleanDigits = phone.replaceAll(RegExp(r'\D'), '');
    final normalizedPhone = cleanDigits.length >= 10
        ? cleanDigits.substring(cleanDigits.length - 10)
        : cleanDigits;
    final cleanToken = (authToken ?? '').trim();
    final cleanCustomerId = (customerId ?? '').trim();
    final cleanOtp = (otp ?? '').trim();

    if (cleanOtp.isEmpty && cleanToken.isNotEmpty) {
      try {
        final res = await _client
            .post(
              Uri.parse('$baseUrl/api/customer/account/delete'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $cleanToken',
              },
              body: json.encode({
                'phone': normalizedPhone,
                if (cleanCustomerId.isNotEmpty) 'customer_id': cleanCustomerId,
              }),
            )
            .timeout(const Duration(seconds: 12));

        Map<String, dynamic> map = {};
        if (res.body.trim().isNotEmpty) {
          final decoded = json.decode(res.body);
          if (decoded is Map) {
            map = Map<String, dynamic>.from(decoded);
          }
        }
        map['statusCode'] = res.statusCode;

        if (res.statusCode >= 200 &&
            res.statusCode < 300 &&
            map['success'] != false) {
          map['success'] = true;
          return map;
        }

        if (res.statusCode == 404 ||
            res.statusCode == 401 ||
            res.statusCode == 403 ||
            res.statusCode == 501) {
          return {
            'success': false,
            'needs_otp': true,
            'statusCode': res.statusCode,
            'error': map['error'] ??
                map['message'] ??
                'OTP verification required to delete your account.',
          };
        }

        return {
          'success': false,
          'statusCode': res.statusCode,
          'error': map['error'] ??
              map['message'] ??
              'Unable to delete account (${res.statusCode}).',
        };
      } catch (e) {
        debugPrint('[ApiService] EC2 account delete fallback to OTP: $e');
        return {
          'success': false,
          'needs_otp': true,
          'error': 'Please confirm account deletion with OTP.',
        };
      }
    }

    if (cleanOtp.isEmpty) {
      return {
        'success': false,
        'needs_otp': true,
        'error': 'OTP verification is required to confirm account deletion.',
      };
    }

    try {
      final res = await _client
          .post(
            Uri.parse('$cbmBaseUrl/v1/customer/account/delete'),
            headers: {
              'Content-Type': 'application/json',
              if (cleanToken.isNotEmpty) 'Authorization': 'Bearer $cleanToken',
            },
            body: json.encode({
              'phone': normalizedPhone,
              'otp': cleanOtp,
              if (cleanCustomerId.isNotEmpty) 'customer_id': cleanCustomerId,
            }),
          )
          .timeout(const Duration(seconds: 12));

      Map<String, dynamic> map = {};
      if (res.body.trim().isNotEmpty) {
        final decoded = json.decode(res.body);
        if (decoded is Map) {
          map = Map<String, dynamic>.from(decoded);
        }
      }
      map['statusCode'] = res.statusCode;
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          map['success'] != false) {
        map['success'] = true;
      } else {
        map['success'] = false;
        map['error'] = map['error'] ??
            map['message'] ??
            'Account deletion failed (${res.statusCode}).';
      }
      return map;
    } catch (e) {
      debugPrint('[ApiService] Lambda deleteCustomerAccount failed: $e');
      return {
        'success': false,
        'error': 'Network error deleting account. Please retry.',
      };
    }
  }

  Future<Map<String, dynamic>> _getAuthedJson(
    String path, {
    Map<String, String>? queryParams,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: (queryParams != null && queryParams.isNotEmpty) ? queryParams : null,
    );
    Future<http.Response> send() => _client.get(uri, headers: jsonHeaders()).timeout(timeout);

    try {
      var response = await send();
      if (response.statusCode == 401 && _onUnauthorizedRefresh != null) {
        final refreshed = await _onUnauthorizedRefresh!();
        if (refreshed != null && refreshed.isNotEmpty) {
          response = await send();
        }
      }

      Map<String, dynamic> map = <String, dynamic>{};
      final raw = response.body.trim();
      if (raw.isNotEmpty) {
        try {
          final decoded = json.decode(raw);
          if (decoded is Map) {
            map = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        map.putIfAbsent('success', () => true);
        return map;
      }

      map['success'] = false;
      map['statusCode'] = response.statusCode;
      map.putIfAbsent(
        'message',
        () => map['error']?.toString() ?? 'Request failed (${response.statusCode})',
      );
      return map;
    } catch (e) {
      debugPrint('[ApiService] GET $path failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'message': 'Network error. Please try again.',
      };
    }
  }

  /// Fetch visit chat history or unseen delta messages (`afterSeq`) for this booking.
  Future<Map<String, dynamic>> getVisitChatMessages(
    String visitId, {
    int afterSeq = 0,
  }) async {
    final cleanId = visitId.trim();
    if (cleanId.isEmpty) return {'success': false, 'error': 'INVALID_VISIT_ID'};
    return _getAuthedJson(
      '/api/visits/${Uri.encodeComponent(cleanId)}/chat/messages',
      queryParams: afterSeq > 0 ? {'after_seq': '$afterSeq'} : null,
      timeout: const Duration(seconds: 7),
    );
  }

  /// Send a sanitized text or location message in the visit chat.
  Future<Map<String, dynamic>> sendVisitChatMessage({
    required String visitId,
    required Map<String, dynamic> payload,
  }) async {
    final cleanId = visitId.trim();
    if (cleanId.isEmpty) return {'success': false, 'error': 'INVALID_VISIT_ID'};
    return _postAuthedJson(
      '/api/visits/${Uri.encodeComponent(cleanId)}/chat/messages',
      payload,
      timeout: const Duration(seconds: 7),
    );
  }

  /// Mark messages up to `seq` as seen (lightweight monotonic Redis pointer).
  Future<void> markVisitChatSeen(String visitId, int seq) async {
    final cleanId = visitId.trim();
    if (cleanId.isEmpty || seq <= 0) return;
    await _postAuthedJson(
      '/api/visits/${Uri.encodeComponent(cleanId)}/chat/seen',
      {'seq': seq},
      timeout: const Duration(seconds: 4),
    );
  }

  /// Shared authenticated SSE stream connector (supports Bearer refresh & clean teardown).
  Stream<Map<String, dynamic>> _watchAuthedSseStream(
    String path, {
    String logTag = 'SSE',
  }) {
    late final StreamController<Map<String, dynamic>> controller;
    StreamSubscription<Map<String, dynamic>>? lineSub;
    bool cancelled = false;

    controller = StreamController<Map<String, dynamic>>(
      onListen: () async {
        try {
          Future<http.StreamedResponse> openStream() {
            final request = http.Request(
              'GET',
              Uri.parse('$baseUrl$path'),
            );
            request.headers['Accept'] = 'text/event-stream';
            request.headers['Cache-Control'] = 'no-cache';
            if (_authToken != null) {
              request.headers['Authorization'] = 'Bearer $_authToken';
            }
            return _client.send(request).timeout(const Duration(seconds: 8));
          }

          var streamed = await openStream();
          if (!cancelled && streamed.statusCode == 401 && _onUnauthorizedRefresh != null) {
            await streamed.stream.drain<void>().catchError((_) {});
            final refreshed = await _onUnauthorizedRefresh!();
            if (refreshed != null && refreshed.isNotEmpty) {
              streamed = await openStream();
            }
          }

          if (cancelled || streamed.statusCode != 200) {
            await streamed.stream.drain<void>().catchError((_) {});
            if (!controller.isClosed) await controller.close();
            return;
          }

          final events = parseCheckoutSseLines(
            streamed.stream.transform(utf8.decoder).transform(const LineSplitter()),
          );
          lineSub = events.listen(
            (eventMap) {
              if (!controller.isClosed) {
                controller.add(eventMap);
              }
              final evName = (eventMap['_event'] ?? '').toString().toLowerCase();
              if (evName == 'chat_closed' || evName == 'timeout') {
                if (!controller.isClosed) controller.close();
              }
            },
            onError: (_) {
              if (!controller.isClosed) controller.close();
            },
            onDone: () {
              if (!controller.isClosed) controller.close();
            },
            cancelOnError: true,
          );
        } catch (e) {
          debugPrint('[ApiService] SSE $logTag fallback: $e');
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await lineSub?.cancel();
        lineSub = null;
      },
    );

    return controller.stream;
  }

  /// Live SSE listener for assigned technician <-> customer chat updates (header Bearer JWT).
  Stream<Map<String, dynamic>> watchVisitChatEvents(String visitId) {
    final cleanId = visitId.trim();
    if (cleanId.isEmpty) return const Stream.empty();
    return _watchAuthedSseStream(
      '/api/visits/${Uri.encodeComponent(cleanId)}/chat/stream',
      logTag: 'watchVisitChatEvents',
    );
  }

  // --- ZONE-ROUTED CUSTOMER SUPPORT CHAT (Zone Manager / Out-of-Zone HQ) ---

  Future<Map<String, dynamic>> openOrCreateSupportThread({
    String? visitId,
    String? orderId,
    String? issueType,
    String? initialMessage,
    double? lat,
    double? lng,
    bool forceNew = false,
    String? clientMsgId,
  }) async {
    return _postAuthedJson(
      '/api/support/chat/threads',
      {
        if (visitId != null && visitId.trim().isNotEmpty) 'visit_id': visitId.trim(),
        if (orderId != null && orderId.trim().isNotEmpty) 'order_id': orderId.trim(),
        if (issueType != null && issueType.trim().isNotEmpty) 'issue_type': issueType.trim(),
        if (initialMessage != null && initialMessage.trim().isNotEmpty)
          'initial_message': initialMessage.trim(),
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (forceNew) 'force_new': true,
        if (clientMsgId != null && clientMsgId.trim().isNotEmpty)
          'client_msg_id': clientMsgId.trim(),
      },
      timeout: const Duration(seconds: 8),
    );
  }

  Future<Map<String, dynamic>> listSupportThreads() async {
    return _getAuthedJson('/api/support/chat/threads', timeout: const Duration(seconds: 7));
  }

  Future<Map<String, dynamic>> getSupportMessages(
    String threadId, {
    int afterSeq = 0,
  }) async {
    final cleanId = threadId.trim();
    if (cleanId.isEmpty) return {'success': false, 'error': 'INVALID_THREAD_ID'};
    return _getAuthedJson(
      '/api/support/chat/threads/${Uri.encodeComponent(cleanId)}/messages',
      queryParams: afterSeq > 0 ? {'after_seq': '$afterSeq'} : null,
      timeout: const Duration(seconds: 7),
    );
  }

  Future<Map<String, dynamic>> sendSupportMessage({
    required String threadId,
    required String text,
    String? clientMsgId,
  }) async {
    final cleanId = threadId.trim();
    if (cleanId.isEmpty) return {'success': false, 'error': 'INVALID_THREAD_ID'};
    return _postAuthedJson(
      '/api/support/chat/threads/${Uri.encodeComponent(cleanId)}/messages',
      {
        'text': text,
        if (clientMsgId != null && clientMsgId.trim().isNotEmpty)
          'client_msg_id': clientMsgId.trim(),
      },
      timeout: const Duration(seconds: 7),
    );
  }

  Future<void> markSupportSeen(String threadId, int seq) async {
    final cleanId = threadId.trim();
    if (cleanId.isEmpty || seq <= 0) return;
    await _postAuthedJson(
      '/api/support/chat/threads/${Uri.encodeComponent(cleanId)}/seen',
      {'seq': seq},
      timeout: const Duration(seconds: 4),
    );
  }

  Stream<Map<String, dynamic>> watchSupportChatEvents(String threadId) {
    final cleanId = threadId.trim();
    if (cleanId.isEmpty) return const Stream.empty();
    return _watchAuthedSseStream(
      '/api/support/chat/threads/${Uri.encodeComponent(cleanId)}/stream',
      logTag: 'watchSupportChatEvents',
    );
  }

  /// Fetches customer's active 7-day saved online cart / failed-payment draft (ONLINE_ECOM only)
  Future<Map<String, dynamic>?> fetchActiveOnlineDraft() async {
    if (_authToken == null || _authToken!.isEmpty) return null;
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/online/drafts/active'),
            headers: jsonHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded['draft'] is Map) {
          return Map<String, dynamic>.from(decoded['draft'] as Map);
        }
      }
      return null;
    } catch (e) {
      debugPrint('[ApiService] fetchActiveOnlineDraft warning: $e');
      return null;
    }
  }

  /// Syncs active online cart + delivery address to RDS 7-day resumable draft
  Future<Map<String, dynamic>> syncOnlineCartDraft(
      Map<String, dynamic> payload) async {
    if (_authToken == null || _authToken!.isEmpty) {
      return {'success': false, 'skipped': true};
    }
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/online/drafts/sync'),
            headers: jsonHeaders(),
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 6));
      final decoded = json.decode(response.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'success': false};
    } catch (e) {
      debugPrint('[ApiService] syncOnlineCartDraft warning: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Live re-prices saved 7-day draft against current catalog, shipping & coupon rules
  Future<Map<String, dynamic>> resumeOnlineDraft({
    String draftId = 'active',
    String? couponCode,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/online/drafts/$draftId/resume'),
            headers: jsonHeaders(),
            body: json.encode({
              if (couponCode != null) 'coupon_code': couponCode,
            }),
          )
          .timeout(const Duration(seconds: 8));
      final decoded = json.decode(response.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'success': false, 'error': 'Invalid resume response'};
    } catch (e) {
      return {'success': false, 'error': 'Network error: $e'};
    }
  }

  /// Reports failed/cancelled/abandoned PG payment to schedule +1h & Next-Day IST reminders
  Future<Map<String, dynamic>> reportOnlinePaymentFailure(
      Map<String, dynamic> payload) async {
    if (_authToken == null || _authToken!.isEmpty) {
      return {'success': false, 'skipped': true};
    }
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/online/drafts/payment-failed'),
            headers: jsonHeaders(),
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 6));
      final decoded = json.decode(response.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'success': false};
    } catch (e) {
      debugPrint('[ApiService] reportOnlinePaymentFailure warning: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Dismisses customer's 7-day online recovery draft & cancels pending nudges
  Future<bool> dismissOnlineDraft({
    String? draftId,
    String reason = 'CUSTOMER_DISMISSED',
  }) async {
    if (_authToken == null || _authToken!.isEmpty) return false;
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/online/drafts/dismiss'),
            headers: jsonHeaders(),
            body: json.encode({
              if (draftId != null && draftId.isNotEmpty) 'draft_id': draftId,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Revoke customer session on server
  Future<void> logout(String refreshToken) async {
    try {
      await _client.post(
        Uri.parse('$baseUrl/api/auth/logout'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      ).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[ApiService] Logout call failed: $e');
    }
  }
}

class VersionSyncResult {
  final bool catalogUpdated;
  final bool happyHourUpdated;
  final CatalogSnapshot? catalog;
  final Map<String, dynamic>? happyHour;
  final String? remoteCatalogRef;
  final String? remoteHappyHourVersion;

  const VersionSyncResult({
    required this.catalogUpdated,
    required this.happyHourUpdated,
    this.catalog,
    this.happyHour,
    this.remoteCatalogRef,
    this.remoteHappyHourVersion,
  });
}

