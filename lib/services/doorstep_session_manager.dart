import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight persistent session shield for Doorstep Product Scans
/// Guaranteed anti-back-button loss: Saves scanned items & verification status
/// under key `doorstep_cart_session_<visit_id>` in SharedPreferences.
class DoorstepSessionManager {
  static String _key(dynamic visitId, {String? customerId}) {
    final cleanCust = (customerId ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final custScope = cleanCust.isNotEmpty ? cleanCust : 'guest';
    return 'doorstep_cart_session_${custScope}_${visitId ?? "default"}';
  }

  /// Normalized sorted serial/QR signature for matching active temporary sessions
  static List<String> itemCodesSignature(List<dynamic> items) {
    final codes = <String>[];
    for (final raw in items) {
      if (raw is Map) {
        final code = (raw['code'] ??
                raw['serial_qr'] ??
                raw['kit_qr'] ??
                raw['component_qr'] ??
                raw['serial'] ??
                '')
            .toString()
            .trim()
            .toUpperCase();
        if (code.isNotEmpty) codes.add(code);
      }
    }
    codes.sort();
    return codes;
  }

  static bool signaturesMatch(List<String> a, List<String> b) {
    if (a.isEmpty || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Save scanned items, verification state, and optional temporary checkout ref to persistent storage
  static Future<void> saveSession({
    required dynamic visitId,
    String? customerId,
    required List<Map<String, dynamic>> items,
    String? appliedCoupon,
    String? pendingCheckoutRefId,
    double? pendingPayableAmount,
    bool clearPendingCheckout = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storageKey = _key(visitId, customerId: customerId);
      if (items.isEmpty) {
        await prefs.remove(storageKey);
        debugPrint('[DoorstepSessionManager] Cleared empty session for visit $visitId');
        return;
      }

      final currentSignature = itemCodesSignature(items);
      String? resolvedRefId =
          (pendingCheckoutRefId != null && pendingCheckoutRefId.trim().isNotEmpty)
              ? pendingCheckoutRefId.trim()
              : null;
      double? resolvedPayable =
          (pendingPayableAmount != null && pendingPayableAmount > 0)
              ? pendingPayableAmount
              : null;
      List<String> resolvedSignature =
          resolvedRefId != null ? currentSignature : <String>[];

      if (!clearPendingCheckout && resolvedRefId == null) {
        final existingRaw = prefs.getString(storageKey);
        if (existingRaw != null && existingRaw.isNotEmpty) {
          try {
            final existingMap = json.decode(existingRaw) as Map<String, dynamic>;
            final existingRef =
                (existingMap['pending_checkout_ref_id'] ?? '').toString().trim();
            if (existingRef.isNotEmpty) {
              final existingSigRaw = existingMap['pending_item_signature'] is List
                  ? (existingMap['pending_item_signature'] as List)
                      .map((e) => e.toString().trim().toUpperCase())
                      .where((e) => e.isNotEmpty)
                      .toList()
                  : itemCodesSignature(
                      existingMap['items'] is List
                          ? existingMap['items'] as List
                          : const [],
                    );
              existingSigRaw.sort();
              if (signaturesMatch(existingSigRaw, currentSignature)) {
                resolvedRefId = existingRef;
                resolvedSignature = existingSigRaw;
                final rawAmt = existingMap['pending_payable_amount'];
                if (rawAmt is num && rawAmt > 0) {
                  resolvedPayable = rawAmt.toDouble();
                } else if (rawAmt != null) {
                  final parsed = double.tryParse(rawAmt.toString());
                  if (parsed != null && parsed > 0) resolvedPayable = parsed;
                }
              }
            }
          } catch (_) {}
        }
      }

      final data = <String, dynamic>{
        'visit_id': visitId,
        'saved_at': DateTime.now().millisecondsSinceEpoch,
        'items': items,
        'applied_coupon': appliedCoupon,
        if (!clearPendingCheckout && resolvedRefId != null) ...{
          'pending_checkout_ref_id': resolvedRefId,
          'pending_item_signature': resolvedSignature,
          if (resolvedPayable != null && resolvedPayable > 0)
            'pending_payable_amount': resolvedPayable,
        },
      };
      await prefs.setString(_key(visitId, customerId: customerId), json.encode(data));
      debugPrint('[DoorstepSessionManager] Auto-saved ${items.length} items for visit $visitId');
    } catch (e) {
      debugPrint('[DoorstepSessionManager] saveSession error: $e');
    }
  }

  /// Load active session if user exited or pressed back (12h TTL)
  static Future<Map<String, dynamic>?> loadSession(
    dynamic visitId, {
    String? customerId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storageKey = _key(visitId, customerId: customerId);
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw) as Map<String, dynamic>;
        final savedAtRaw = decoded['saved_at'];
        final savedAt = savedAtRaw is num
            ? savedAtRaw.toInt()
            : int.tryParse(savedAtRaw?.toString() ?? '');
        if (savedAt != null &&
            DateTime.now().millisecondsSinceEpoch - savedAt > 12 * 3600 * 1000) {
          await prefs.remove(storageKey);
          debugPrint('[DoorstepSessionManager] Expired stale session for visit $visitId');
          return null;
        }
        debugPrint('[DoorstepSessionManager] Restored active session for visit $visitId');
        return decoded;
      }
    } catch (e) {
      debugPrint('[DoorstepSessionManager] loadSession error: $e');
    }
    return null;
  }

  /// Clear session upon confirmed payment success or explicit user dismissal
  static Future<void> clearSession(
    dynamic visitId, {
    String? customerId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(visitId, customerId: customerId));
      debugPrint('[DoorstepSessionManager] Cleared session for visit $visitId');
    } catch (e) {
      debugPrint('[DoorstepSessionManager] clearSession error: $e');
    }
  }
}
