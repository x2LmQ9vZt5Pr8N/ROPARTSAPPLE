import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

/// Single Source of Truth (SSoT) for Happy Hour Promo Windows.
/// Directly synchronizes with AWS EC2 Fastify API (`/api/happy-hours/status`)
/// backed by PostgreSQL RDS `roparts.happy_hour_schedules` and Redis versioning.
class HappyHourHelper {
  static bool? _backendIsLive;
  static int? _backendFee;
  static DateTime? _backendCheckTime;
  static Map<String, dynamic>? _activeWindow;
  static Map<String, dynamic>? _nextWindow;
  static bool _isMasterEnabled = true;

  /// High-speed ValueNotifier for 0ms reactive UI rebuilds across app
  static final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  /// True if Free Hour is enabled and has either a live or upcoming window
  static bool get isEnabled {
    if (!_isMasterEnabled) return false;
    final isLive = isHappyHourLive();
    final hasNext = _nextWindow != null && _nextWindow!['start_time'] != null;
    return isLive || hasNext;
  }

  /// Hydrates locally cached Happy Hour status immediately (0ms network cost).
  static Future<bool> loadFromLocalCache() async {
    try {
      final cached = await ApiService().readCachedHappyHour();
      if (cached != null) {
        updateFromBackend(cached, persist: false);
        return true;
      }
    } catch (e) {
      debugPrint('[HappyHourHelper] local cache load notice: $e');
    }
    return false;
  }

  /// Fetches real-time status from backend RDS with in-memory caching
  static Future<bool> syncWithBackend({int? serviceAreaId, bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _backendCheckTime != null &&
        DateTime.now().difference(_backendCheckTime!).inSeconds < 15) {
      return isHappyHourLive();
    }

    try {
      final res = await ApiService().getHappyHourStatus(serviceAreaId: serviceAreaId);
      if (res != null) {
        updateFromBackend(res, persist: true);
        return isHappyHourLive();
      }
    } catch (e) {
      debugPrint('[HappyHourHelper] sync error: $e');
    }
    return isHappyHourLive();
  }

  static Map<String, dynamic>? _toStringMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  /// Resolves active window bounds in IST, supporting windows that end at
  /// `00:00:00` or cross midnight (e.g. `22:00:00` -> `02:00:00`).
  static ({DateTime start, DateTime end})? _resolveWindowBounds(
    Map<String, dynamic>? window,
    DateTime nowIst,
  ) {
    if (window == null || window['start_time'] == null || window['end_time'] == null) {
      return null;
    }
    final startToday = _parseTimeToday(window['start_time'].toString(), nowIst);
    var endToday = _parseTimeToday(window['end_time'].toString(), nowIst);
    if (startToday == null || endToday == null) return null;

    if (!endToday.isAfter(startToday)) {
      final prevStart = startToday.subtract(const Duration(days: 1));
      if (!nowIst.isBefore(prevStart) && nowIst.isBefore(endToday)) {
        return (start: prevStart, end: endToday);
      }
      endToday = endToday.add(const Duration(days: 1));
    }
    return (start: startToday, end: endToday);
  }

  /// Updates local state from GET /api/happy-hours/status response or FCM push
  static void updateFromBackend(
    Map<String, dynamic> data, {
    bool persist = true,
    String? version,
  }) {
    _backendIsLive = data['is_happy_hour'] == true;
    _backendFee = (data['current_fee'] is num)
        ? (data['current_fee'] as num).toInt()
        : (int.tryParse(data['current_fee']?.toString() ?? '') ?? (_backendIsLive == true ? 0 : 49));
    _backendCheckTime = DateTime.now();
    _activeWindow = _toStringMap(data['active_window']);
    _nextWindow = _toStringMap(data['next_window']);

    final nowIst = _getIstNow();
    final activeBounds = _resolveWindowBounds(_activeWindow, nowIst);
    if (activeBounds != null && !nowIst.isBefore(activeBounds.end)) {
      _activeWindow = null;
      _backendIsLive = false;
      _backendFee = 49;
    }

    if (data.containsKey('is_enabled')) {
      _isMasterEnabled = data['is_enabled'] == true;
    } else {
      _isMasterEnabled = _activeWindow != null || _nextWindow != null || _backendIsLive == true;
    }

    if (persist) {
      unawaited(ApiService().persistHappyHour(data, version: version));
    }

    // Notify listeners (Banner, Coin Button, etc.) immediately
    changeNotifier.value++;
  }

  static DateTime _getIstNow() {
    final utc = DateTime.now().toUtc();
    final ist = utc.add(const Duration(hours: 5, minutes: 30));
    return DateTime.utc(ist.year, ist.month, ist.day, ist.hour, ist.minute, ist.second);
  }

  /// Evaluates whether Happy Hour is live right now in Indian Standard Time (IST).
  /// Strictly checks current clock against active window start & end times.
  static bool isHappyHourLive([DateTime? mockTime]) {
    if (!_isMasterEnabled) return false;
    final now = mockTime ?? _getIstNow();

    final bounds = _resolveWindowBounds(_activeWindow, now);
    if (bounds != null) {
      return !now.isBefore(bounds.start) && now.isBefore(bounds.end);
    }

    return false;
  }

  /// Checks if current active window has expired and transitions state.
  /// Automatically fetches the next upcoming window from backend.
  static bool checkAndHandleExpiration() {
    final now = _getIstNow();
    final bounds = _resolveWindowBounds(_activeWindow, now);
    if (bounds != null && !now.isBefore(bounds.end)) {
      _activeWindow = null;
      _backendIsLive = false;
      _backendFee = 49;
      unawaited(syncWithBackend(forceRefresh: true));
      changeNotifier.value++;
      return true;
    }
    return false;
  }

  /// Current Inspection Fee (₹0 during Happy Hour, ₹49 otherwise)
  static int get currentInspectionFee => isHappyHourLive() ? 0 : (_backendFee ?? 49);

  /// Current Active Window details
  static Map<String, dynamic>? get activeWindow => _activeWindow;

  /// Next Upcoming Window details
  static Map<String, dynamic>? get nextWindow => _nextWindow;

  static String get activeWindowTitle =>
      _activeWindow?['title']?.toString() ?? 'Happy Hour';

  static String get nextWindowTitle =>
      _nextWindow?['title']?.toString() ?? 'Happy Hour';

  static String get activeWindowStartTime =>
      _formatTimeShort(_activeWindow?['start_time']?.toString() ?? '09:00:00');

  static String get activeWindowEndTime =>
      _formatTimeShort(_activeWindow?['end_time']?.toString() ?? '10:00:00');

  static String get nextWindowStartTime =>
      _formatTimeShort(_nextWindow?['start_time']?.toString() ?? '09:00:00');

  static String get nextWindowEndTime =>
      _formatTimeShort(_nextWindow?['end_time']?.toString() ?? '10:00:00');

  /// Formats HH:MM:SS to 12-hour format e.g. "02:43 PM"
  static String _formatTimeShort(String timeStr) {
    try {
      final parts = timeStr.split(':');
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final period = h >= 12 ? 'PM' : 'AM';
      final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
      final mStr = m.toString().padLeft(2, '0');
      return '$hour12:$mStr $period';
    } catch (_) {
      return timeStr.length >= 5 ? timeStr.substring(0, 5) : timeStr;
    }
  }

  /// Calculates dynamic time remaining in active window (ENDS IN) or until next window (STARTS IN)
  static Duration timeUntilWindow([DateTime? mockTime]) {
    final now = mockTime ?? _getIstNow();

    // Case A: Happy Hour is LIVE right now -> countdown until active window ENDS
    if (isHappyHourLive(mockTime)) {
      final bounds = _resolveWindowBounds(_activeWindow, now);
      if (bounds != null) {
        final diff = bounds.end.difference(now);
        return diff.isNegative ? Duration.zero : diff;
      }
    }

    // Case B: Happy Hour is NOT live -> countdown until next window STARTS
    if (_nextWindow != null && _nextWindow!['start_time'] != null) {
      final startToday = _parseTimeToday(_nextWindow!['start_time'].toString(), now);
      if (startToday != null) {
        if (now.isBefore(startToday)) {
          return startToday.difference(now);
        } else {
          // Window is tomorrow
          final startTomorrow = startToday.add(const Duration(days: 1));
          return startTomorrow.difference(now);
        }
      }
    }

    // If no window exists or campaign is disabled, return zero
    return Duration.zero;
  }

  static DateTime? _parseTimeToday(String timeStr, DateTime nowIst) {
    try {
      final parts = timeStr.split(':');
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final s = parts.length > 2 ? int.parse(parts[2].split('.').first) : 0;
      return DateTime.utc(nowIst.year, nowIst.month, nowIst.day, h, m, s);
    } catch (_) {
      return null;
    }
  }
}
