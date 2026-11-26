import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_address.dart';

/// Production-grade Local Cache & Identity Vault for ROParts Customer App.
/// 
/// Guarantees:
/// 1. Strict Actor-ID namespacing (`cust_<id>_*`).
/// 2. Zero-Trust cross-identity leak prevention (foreign keys are auto-purged on boot).
/// 3. Deep-clean logout protocol wiping persistent, in-memory, and image caches.
class LocalCacheVault {
  static const String keyActiveActorId = 'ro_active_actor_id';
  static const String keyActiveActorType = 'ro_active_actor_type';
  static const String _securePendingPhoneKey = 'ro_pending_auth_phone';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static final Map<String, String> _memorySecureFallback = <String, String>{};

  static String _secureTokenKey(String customerId) => 'cust_${customerId}_token';
  static String _secureRefreshKey(String customerId) => 'cust_${customerId}_refresh_token';

  static Future<void> _writeSecure(String key, String value) async {
    _memorySecureFallback[key] = value;
    try {
      await _secureStorage.write(key: key, value: value);
    } on MissingPluginException {
      // Widget/unit tests without native plugin registration
    } on PlatformException catch (e) {
      debugPrint('[LocalCacheVault] Secure write fallback ($key): $e');
    }
  }

  static Future<String?> _readSecure(String key) async {
    try {
      final val = await _secureStorage.read(key: key);
      if (val != null) {
        _memorySecureFallback[key] = val;
        return val;
      }
    } on MissingPluginException {
      return _memorySecureFallback[key];
    } on PlatformException catch (e) {
      debugPrint('[LocalCacheVault] Secure read fallback ($key): $e');
    }
    return _memorySecureFallback[key];
  }

  static Future<void> _deleteSecure(String key) async {
    _memorySecureFallback.remove(key);
    try {
      await _secureStorage.delete(key: key);
    } on MissingPluginException {
      // Ignore in test environments
    } on PlatformException catch (e) {
      debugPrint('[LocalCacheVault] Secure delete fallback ($key): $e');
    }
  }

  static Future<void> _purgeSecureTokens({String? keepCustomerId}) async {
    final keepTokenKey =
        keepCustomerId != null ? _secureTokenKey(keepCustomerId) : null;
    final keepRefreshKey =
        keepCustomerId != null ? _secureRefreshKey(keepCustomerId) : null;
    _memorySecureFallback.removeWhere((key, _) {
      if (key == _securePendingPhoneKey) return false;
      if (keepCustomerId != null && (key == keepTokenKey || key == keepRefreshKey)) {
        return false;
      }
      return key.startsWith('cust_') || key.startsWith('tech_') || key.startsWith('ro_');
    });
    try {
      final all = await _secureStorage.readAll();
      for (final key in all.keys) {
        if (key == _securePendingPhoneKey) continue;
        if (keepCustomerId != null && (key == keepTokenKey || key == keepRefreshKey)) {
          continue;
        }
        if (key.startsWith('cust_') || key.startsWith('tech_') || key.startsWith('ro_')) {
          await _secureStorage.delete(key: key);
        }
      }
    } on MissingPluginException {
      // Ignore in test environments
    } on PlatformException catch (e) {
      debugPrint('[LocalCacheVault] Secure bulk purge error: $e');
    }
  }

  /// Stores or updates JWT access/refresh tokens in FlutterSecureStorage.
  static Future<void> saveAuthTokens(
    String customerId, {
    String? token,
    String? refreshToken,
  }) async {
    final cleanId = customerId.trim();
    if (cleanId.isEmpty) return;
    if (token != null && token.trim().isNotEmpty) {
      await _writeSecure(_secureTokenKey(cleanId), token.trim());
    }
    if (refreshToken != null && refreshToken.trim().isNotEmpty) {
      await _writeSecure(_secureRefreshKey(cleanId), refreshToken.trim());
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = _prefix(cleanId);
      await prefs.remove('${p}token');
      await prefs.remove('${p}refresh_token');
    } catch (_) {}
  }

  // Guest Fallback Keys (Zero Personal Identifiers)
  static const String keyGuestPincode = 'guest_delivery_pincode';
  static const String keyGuestCity = 'guest_delivery_city';

  // Legacy Keys (For backward-compatibility migration & auto-cleanup)
  static const List<String> legacyKeys = [
    'ro_auth_token',
    'ro_refresh_token',
    'ro_token_expires_at',
    'ro_user_name',
    'ro_user_phone',
    'ro_customer_id',
    'ro_user_email',
    'ro_saved_addresses',
    'ro_active_address_id',
    'ro_delivery_pincode',
    'ro_delivery_city',
  ];

  static String _prefix(String customerId) => 'cust_${customerId}_';

  /// Scans all local storage keys and aggressively purges any cache that does not
  /// belong to [activeCustomerId]. If [activeCustomerId] is null, ALL personal caches are wiped.
  static Future<void> enforceBoundary(String? activeCustomerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allKeys = prefs.getKeys().toList();

      final targetPrefix = (activeCustomerId != null && activeCustomerId.isNotEmpty)
          ? _prefix(activeCustomerId)
          : null;

      final toRemove = <String>[];
      for (final key in allKeys) {
        // 1. Always purge legacy un-namespaced personal keys
        if (legacyKeys.contains(key)) {
          toRemove.add(key);
          continue;
        }

        // 2. Wipe technician keys if accidentally left on shared device
        if (key.startsWith('tech_')) {
          toRemove.add(key);
          continue;
        }

        // 3. Purge customer keys belonging to a different customer ID
        if (key.startsWith('cust_')) {
          if (targetPrefix == null || !key.startsWith(targetPrefix)) {
            toRemove.add(key);
          }
          continue;
        }

        // 4. Purge doorstep cart sessions belonging to another customer/guest
        if (key.startsWith('doorstep_cart_session_')) {
          final allowedScope =
              (activeCustomerId != null && activeCustomerId.isNotEmpty)
                  ? 'doorstep_cart_session_${activeCustomerId}_'
                  : null;
          if (allowedScope == null || !key.startsWith(allowedScope)) {
            toRemove.add(key);
          }
          continue;
        }

        // 5. Purge pre-arrival notification flags when logged out
        if (targetPrefix == null && key.startsWith('pre_arrival_notified_')) {
          toRemove.add(key);
        }
      }

      if (toRemove.isNotEmpty) {
        await Future.wait(toRemove.map((key) => prefs.remove(key)));
      }

      await _purgeSecureTokens(
        keepCustomerId:
            (activeCustomerId != null && activeCustomerId.isNotEmpty)
                ? activeCustomerId
                : null,
      );

      if (targetPrefix == null) {
        await prefs.remove(keyActiveActorId);
        await prefs.remove(keyActiveActorType);
      }
    } catch (e) {
      debugPrint('[LocalCacheVault] Boundary enforcement failed: $e');
    }
  }

  /// Persists full authenticated session details under the customer's ID namespace.
  static Future<void> saveCustomerSession({
    required String customerId,
    required String name,
    required String phone,
    String? email,
    String? token,
    String? refreshToken,
    int? expiresAt,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = _prefix(customerId);

      await prefs.setString(keyActiveActorId, customerId);
      await prefs.setString(keyActiveActorType, 'CUSTOMER');

      await prefs.setString('${p}name', name.trim());
      await prefs.setString('${p}phone', phone.trim());
      if (email != null && email.isNotEmpty) {
        await prefs.setString('${p}email', email.trim());
      } else {
        await prefs.remove('${p}email');
      }

      if (token != null || refreshToken != null) {
        await saveAuthTokens(
          customerId,
          token: token,
          refreshToken: refreshToken,
        );
      }
      if (expiresAt != null) await prefs.setInt('${p}expires_at', expiresAt);

      // Clean out any foreign keys
      await enforceBoundary(customerId);
    } catch (e) {
      debugPrint('[LocalCacheVault] saveCustomerSession error: $e');
    }
  }

  /// Loads the active authenticated session if present and valid.
  static Future<Map<String, dynamic>?> loadActiveSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeId = prefs.getString(keyActiveActorId);

      if (activeId == null || activeId.isEmpty) {
        await enforceBoundary(null);
        return null;
      }

      final p = _prefix(activeId);
      String? token = await _readSecure(_secureTokenKey(activeId));
      String? refreshToken = await _readSecure(_secureRefreshKey(activeId));
      final legacyToken = prefs.getString('${p}token');
      final legacyRefresh = prefs.getString('${p}refresh_token');

      if ((token == null || token.isEmpty) &&
          legacyToken != null &&
          legacyToken.isNotEmpty) {
        token = legacyToken;
        refreshToken = legacyRefresh ?? refreshToken;
        await saveAuthTokens(
          activeId,
          token: token,
          refreshToken: refreshToken,
        );
      } else if (legacyToken != null || legacyRefresh != null) {
        await prefs.remove('${p}token');
        await prefs.remove('${p}refresh_token');
      }

      final phone = prefs.getString('${p}phone');

      if (token == null || token.isEmpty || phone == null || phone.isEmpty) {
        await purgeCustomer(activeId);
        return null;
      }

      // Enforce boundary to ensure no stray keys remain
      await enforceBoundary(activeId);

      return {
        'customer_id': activeId,
        'token': token,
        'refresh_token': refreshToken,
        'expires_at': prefs.getInt('${p}expires_at'),
        'name': prefs.getString('${p}name') ?? '',
        'phone': phone,
        'email': prefs.getString('${p}email'),
      };
    } catch (e) {
      debugPrint('[LocalCacheVault] loadActiveSession error: $e');
      return null;
    }
  }

  /// Persists delivery addresses strictly partitioned under [customerId].
  static Future<void> saveAddresses({
    required String customerId,
    required List<UserAddress> addresses,
    String? activeAddressId,
    required String pincode,
    required String city,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = _prefix(customerId);

      final listJson = addresses.map((a) => a.toJson()).toList();
      await prefs.setString('${p}saved_addresses', jsonEncode(listJson));

      if (activeAddressId != null && activeAddressId.isNotEmpty) {
        await prefs.setString('${p}active_address_id', activeAddressId);
      } else {
        await prefs.remove('${p}active_address_id');
      }

      await prefs.setString('${p}pincode', pincode);
      await prefs.setString('${p}city', city);
    } catch (e) {
      debugPrint('[LocalCacheVault] saveAddresses error: $e');
    }
  }

  /// Loads addresses strictly from [customerId]'s partition.
  static Future<List<UserAddress>> loadAddresses(String customerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = _prefix(customerId);
      final raw = prefs.getString('${p}saved_addresses');

      if (raw == null || raw.isEmpty) return [];

      final List<dynamic> list = jsonDecode(raw);
      final result = <UserAddress>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          result.add(UserAddress.fromJson(item));
        }
      }
      return result;
    } catch (e) {
      debugPrint('[LocalCacheVault] loadAddresses error: $e');
      return [];
    }
  }

  /// Loads active address ID for [customerId].
  static Future<String?> loadActiveAddressId(String customerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('${_prefix(customerId)}active_address_id');
    } catch (_) {
      return null;
    }
  }

  /// Loads delivery location (Pincode & City).
  static Future<Map<String, String>> loadDeliveryLocation(String? customerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (customerId != null && customerId.isNotEmpty) {
        final p = _prefix(customerId);
        final pin = prefs.getString('${p}pincode');
        final city = prefs.getString('${p}city');
        if (pin != null && pin.isNotEmpty && city != null && city.isNotEmpty) {
          return {'pincode': pin, 'city': city};
        }
      }
      // Guest fallback
      return {
        'pincode': prefs.getString(keyGuestPincode) ?? '560034',
        'city': prefs.getString(keyGuestCity) ?? 'Bengaluru',
      };
    } catch (_) {
      return {'pincode': '560034', 'city': 'Bengaluru'};
    }
  }

  /// Saves delivery location (Pincode & City).
  static Future<void> saveDeliveryLocation(String? customerId, String pincode, String city) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (customerId != null && customerId.isNotEmpty) {
        final p = _prefix(customerId);
        await prefs.setString('${p}pincode', pincode);
        await prefs.setString('${p}city', city);
      } else {
        await prefs.setString(keyGuestPincode, pincode);
        await prefs.setString(keyGuestCity, city);
      }
    } catch (e) {
      debugPrint('[LocalCacheVault] saveDeliveryLocation error: $e');
    }
  }

  /// Completely purges all persistent data, image caches, and memory for [customerId].
  static Future<void> purgeCustomer(String customerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = _prefix(customerId);
      final allKeys = prefs.getKeys().toList();

      for (final key in allKeys) {
        if (key.startsWith(p) ||
            key.startsWith('doorstep_cart_session_${customerId}_') ||
            key.startsWith('pre_arrival_notified_')) {
          await prefs.remove(key);
        }
      }

      await _deleteSecure(_secureTokenKey(customerId));
      await _deleteSecure(_secureRefreshKey(customerId));

      final activeId = prefs.getString(keyActiveActorId);
      if (activeId == customerId) {
        await prefs.remove(keyActiveActorId);
        await prefs.remove(keyActiveActorType);
      }

      // Purge Flutter image memory cache so photos/proofs do not linger
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (e) {
      debugPrint('[LocalCacheVault] purgeCustomer error: $e');
    }
  }

  /// Emergency full purge of all personal data (used on explicit logout or account switch).
  static Future<void> purgeAllPersonalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allKeys = prefs.getKeys().toList();

      for (final key in allKeys) {
        if (key.startsWith('cust_') ||
            key.startsWith('tech_') ||
            key.startsWith('doorstep_cart_session_') ||
            key.startsWith('pre_arrival_notified_') ||
            legacyKeys.contains(key)) {
          await prefs.remove(key);
        }
      }

      await _purgeSecureTokens();
      await clearPendingAuth();
      await prefs.remove(keyActiveActorId);
      await prefs.remove(keyActiveActorType);

      // Flush image cache
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (e) {
      debugPrint('[LocalCacheVault] purgeAllPersonalData error: $e');
    }
  }

  // --- PENDING AUTH RESUMPTION STATE (ANTI-DISMISSAL ON MINIMIZE/WHATSAPP) ---
  static const String keyPendingAuthPhone = 'ro_pending_auth_phone';
  static const String keyPendingAuthTimestamp = 'ro_pending_auth_timestamp';

  static Future<void> savePendingAuth(String phone) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _writeSecure(_securePendingPhoneKey, phone.trim());
      await prefs.remove(keyPendingAuthPhone);
      await prefs.setInt(keyPendingAuthTimestamp, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<String?> getPendingAuthPhone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(keyPendingAuthTimestamp);
      if (ts == null) return null;
      final elapsed = DateTime.now().millisecondsSinceEpoch - ts;
      if (elapsed > 5 * 60 * 1000) { // 5 minutes TTL
        await clearPendingAuth();
        return null;
      }
      final securePhone = await _readSecure(_securePendingPhoneKey);
      if (securePhone != null && securePhone.isNotEmpty) {
        return securePhone;
      }
      final legacyPhone = prefs.getString(keyPendingAuthPhone);
      if (legacyPhone != null && legacyPhone.isNotEmpty) {
        await _writeSecure(_securePendingPhoneKey, legacyPhone);
        await prefs.remove(keyPendingAuthPhone);
        return legacyPhone;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> getPendingAuthTimestamp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(keyPendingAuthTimestamp);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingAuth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyPendingAuthPhone);
      await prefs.remove(keyPendingAuthTimestamp);
      await _deleteSecure(_securePendingPhoneKey);
    } catch (_) {}
  }
}
