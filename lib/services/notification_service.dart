import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/display_sanitizer.dart';

/// Singleton service managing Android system notification bar alerts
/// for technician en-route and doorstep arrival milestones.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  final Set<String> _preArrivalNotifiedVisits = {};
  final Set<String> _doorstepNotifiedVisits = {};
  Function(String? payload)? _onNotificationClick;

  static const String arrivalChannelId = 'roparts_arrival_alerts';
  static const String arrivalChannelName = 'Technician Arrival Alerts';
  static const String arrivalChannelDesc =
      'Live notifications when your RO technician is about to reach or arrives at your doorstep.';

  static const String chatChannelId = 'roparts_chat_messages_v1';
  static const String chatChannelName = 'Technician Chat Messages';
  static const String recoveryChannelId = 'roparts_online_recovery_v1';
  static const String recoveryChannelName = 'Order & Payment Reminders';
  static const String recoveryChannelDesc =
      'Reminders for incomplete online store payments & 7-day saved carts.';
  static const String updatesChannelId = 'roparts_updates_v1';
  static const String updatesChannelName = 'Order & Delivery Updates';
  static const String updatesChannelDesc =
      'Status updates for confirmed, dispatched, and delivered online orders.';
  static const String chatChannelDesc =
      'Direct messages from your assigned RO technician during an active doorstep visit.';

  int _stableNotifId(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }

  Future<void> initialize({Function(String? payload)? onNotificationClick}) async {
    _onNotificationClick = onNotificationClick ?? _onNotificationClick;
    if (kIsWeb) {
      _isInitialized = true;
      return;
    }
    if (_isInitialized) return;

    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinInit = DarwinInitializationSettings();
      const initSettings = InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
      );

      await _plugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('[NotificationService] Notification tapped: ${response.payload}');
          _onNotificationClick?.call(response.payload);
        },
      );

      // Create high-importance notification channel for Android 8.0+
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        // Request runtime permission on Android 13+ (API 33+)
        await androidPlugin.requestNotificationsPermission();

        const channel = AndroidNotificationChannel(
          arrivalChannelId,
          arrivalChannelName,
          description: arrivalChannelDesc,
          importance: Importance.max,
          enableVibration: true,
          playSound: true,
        );
        await androidPlugin.createNotificationChannel(channel);

        const chatChannel = AndroidNotificationChannel(
          chatChannelId,
          chatChannelName,
          description: chatChannelDesc,
          importance: Importance.high,
          enableVibration: true,
          playSound: true,
        );
        await androidPlugin.createNotificationChannel(chatChannel);

        const recoveryChannel = AndroidNotificationChannel(
          recoveryChannelId,
          recoveryChannelName,
          description: recoveryChannelDesc,
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        );
        await androidPlugin.createNotificationChannel(recoveryChannel);

        const updatesChannel = AndroidNotificationChannel(
          updatesChannelId,
          updatesChannelName,
          description: updatesChannelDesc,
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        );
        await androidPlugin.createNotificationChannel(updatesChannel);
      }

      // Request iOS notification alert/badge/sound permissions explicitly when needed
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (iosPlugin != null) {
        await iosPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      _isInitialized = true;
      debugPrint('[NotificationService] Initialized successfully');
    } catch (e) {
      debugPrint('[NotificationService] Initialization error: $e');
    }
  }

  /// Builds human-readable pre-arrival copy with unambiguous distance (m/km)
  /// and ETA (min/mins) units so meters and minutes never collide.
  static String buildPreArrivalBody({
    required String technicianName,
    double? distanceMeters,
    int? etaMinutes,
  }) {
    final cleanName = DisplaySanitizer.technicianName(
      technicianName,
      fallback: 'Your technician',
    );
    final distText = (distanceMeters != null && distanceMeters > 0)
        ? (distanceMeters >= 1000
            ? '~${(distanceMeters / 1000).toStringAsFixed(1)}km away'
            : '~${distanceMeters.round()}m away')
        : null;
    final etaText = (etaMinutes != null && etaMinutes > 0)
        ? (etaMinutes == 1 ? '~1 min' : '~$etaMinutes mins')
        : (distText == null ? '~2-3 mins' : null);

    final prefix = etaText != null ? 'is arriving in $etaText' : 'is arriving shortly';
    final distSuffix = distText != null ? ' ($distText)' : '';
    return '$cleanName $prefix$distSuffix. Please ensure your water purifier area is clear.';
  }

  /// Triggers a heads-up system notification in the notification bar
  /// when the technician is within ~500m / 2-3 mins away.
  Future<void> showPreArrivalAlert({
    required String visitId,
    required String technicianName,
    double? distanceMeters,
    int? etaMinutes,
  }) async {
    if (visitId.isEmpty) return;

    // In-memory + disk deduplication: strictly fire ONCE per visit
    if (_preArrivalNotifiedVisits.contains(visitId)) return;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('pre_arrival_notified_$visitId') == true) {
        _preArrivalNotifiedVisits.add(visitId);
        return;
      }
    } catch (e) {
      debugPrint('[NotificationService] prefs read error: $e');
    }

    final cleanName = DisplaySanitizer.technicianName(
      technicianName,
      fallback: 'Your technician',
    );
    const title = '🛵 Technician is about to reach!';
    final body = buildPreArrivalBody(
      technicianName: cleanName,
      distanceMeters: distanceMeters,
      etaMinutes: etaMinutes,
    );

    final androidDetails = AndroidNotificationDetails(
      arrivalChannelId,
      arrivalChannelName,
      channelDescription: arrivalChannelDesc,
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Technician is about to reach',
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: '🛵 $cleanName is about to reach!',
        summaryText: 'Doorstep Service Visit',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF0F766E),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
    );

    try {
      final notifId = _stableNotifId('pre_$visitId');
      await _plugin.show(
        id: notifId,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
        payload: visitId,
      );
      _preArrivalNotifiedVisits.add(visitId);
      await prefs?.setBool('pre_arrival_notified_$visitId', true);
      debugPrint('[NotificationService] Posted pre-arrival notification for visit: $visitId');
    } catch (e) {
      debugPrint('[NotificationService] showPreArrivalAlert error: $e');
    }
  }

  /// Triggers a system notification in the notification bar
  /// when technician marks ARRIVED at doorstep with OTP reveal.
  Future<void> showDoorstepArrivalAlert({
    required String visitId,
    required String technicianName,
    String? otp,
  }) async {
    if (visitId.isEmpty) return;

    if (_doorstepNotifiedVisits.contains(visitId)) return;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('doorstep_notified_$visitId') == true) {
        _doorstepNotifiedVisits.add(visitId);
        return;
      }
    } catch (e) {
      debugPrint('[NotificationService] prefs read error: $e');
    }

    final cleanName = DisplaySanitizer.technicianName(
      technicianName,
      fallback: 'Technician',
    );
    const title = '📍 Technician at your Doorstep!';
    final body = otp != null && otp.isNotEmpty
        ? '$cleanName has arrived. Share Start OTP: $otp with him.'
        : '$cleanName is at your doorstep for water purifier inspection.';

    final androidDetails = AndroidNotificationDetails(
      arrivalChannelId,
      arrivalChannelName,
      channelDescription: arrivalChannelDesc,
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Technician at doorstep',
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'Doorstep Arrival',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.status,
      color: const Color(0xFF16A34A),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
    );

    try {
      final notifId = _stableNotifId('arrived_$visitId');
      await _plugin.show(
        id: notifId,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
        payload: visitId,
      );
      _doorstepNotifiedVisits.add(visitId);
      await prefs?.setBool('doorstep_notified_$visitId', true);
      debugPrint('[NotificationService] Posted doorstep arrival notification for visit: $visitId');
    } catch (e) {
      debugPrint('[NotificationService] showDoorstepArrivalAlert error: $e');
    }
  }

  /// Displays a heads-up payment recovery reminder notification without exact alarms.
  /// Tapping navigates directly into CartBottomSheet Payment Method step via payload.
  Future<void> showOnlineRecoveryAlert({
    required String draftId,
    String? title,
    String? body,
    String? orderNumber,
  }) async {
    if (draftId.trim().isEmpty) return;

    final notifTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : 'Complete Your ROParts Order';
    final notifBody = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : 'Your cart is saved for 7 days. Tap to retry online payment or choose Cash on Delivery.';

    final androidDetails = AndroidNotificationDetails(
      recoveryChannelId,
      recoveryChannelName,
      channelDescription: recoveryChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: notifTitle,
      styleInformation: BigTextStyleInformation(
        notifBody,
        contentTitle: notifTitle,
        summaryText: 'Saved Online Cart (7 Days)',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF0284C7),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    try {
      final notifId = _stableNotifId('recovery_$draftId');
      await _plugin.show(
        id: notifId,
        title: notifTitle,
        body: notifBody,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
        ),
        payload: 'ONLINE_RESUME:$draftId',
      );
      debugPrint('[NotificationService] Posted online recovery notification for draft: $draftId');
    } catch (e) {
      debugPrint('[NotificationService] showOnlineRecoveryAlert error: $e');
    }
  }

  /// Displays a heads-up notification for Online E-Commerce order lifecycle milestones
  /// (Confirmed, Shipped, Out for Delivery, Delivered, Cancelled, RTO).
  Future<void> showOnlineOrderStatusAlert({
    required String orderNumber,
    String? title,
    String? body,
    String? eventType,
  }) async {
    final cleanOrder = orderNumber.trim();
    if (cleanOrder.isEmpty) return;

    final notifTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : 'Order Update • $cleanOrder';
    final notifBody = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : 'Tap to track your ROParts order live.';

    final androidDetails = AndroidNotificationDetails(
      updatesChannelId,
      updatesChannelName,
      channelDescription: updatesChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: notifTitle,
      styleInformation: BigTextStyleInformation(
        notifBody,
        contentTitle: notifTitle,
        summaryText: 'ROParts Order Update',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF0071E3),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    try {
      final notifId = _stableNotifId('online_order_${cleanOrder}_${eventType ?? 'update'}');
      await _plugin.show(
        id: notifId,
        title: notifTitle,
        body: notifBody,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
        ),
        payload: 'ONLINE_ORDER_UPDATE:$cleanOrder',
      );
      debugPrint('[NotificationService] Posted order update ($eventType) for $cleanOrder');
    } catch (e) {
      debugPrint('[NotificationService] showOnlineOrderStatusAlert error: $e');
    }
  }

  /// Displays a heads-up notification when a defective part/kit is replaced under warranty.
  /// Shows ONLY the new replacement product serial to the customer.
  Future<void> showWarrantyReplacementAlert({
    required String claimId,
    required String orderNumber,
    String? title,
    String? body,
    String? oldSerialQr,
    String? newSerialQr,
    String? defectReason,
  }) async {
    final cleanOrder = orderNumber.trim();
    final cleanClaim = claimId.trim().isNotEmpty ? claimId.trim() : cleanOrder;
    if (cleanClaim.isEmpty) return;

    final notifTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : 'Part Replaced Under Warranty (₹0)';
    final newStr = (newSerialQr != null && newSerialQr.trim().isNotEmpty)
        ? newSerialQr.trim()
        : 'Verified Replacement';
    final reasonStr = (defectReason ?? 'DEFECTIVE').replaceAll('_', ' ');
    final notifBody = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : 'New Serial: $newStr • Reason: $reasonStr. Tap to view in Orders.';

    final androidDetails = AndroidNotificationDetails(
      updatesChannelId,
      updatesChannelName,
      channelDescription: updatesChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: notifTitle,
      styleInformation: BigTextStyleInformation(
        notifBody,
        contentTitle: notifTitle,
        summaryText: 'ROParts Warranty Replacement',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF059669),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    try {
      final notifId = _stableNotifId('warranty_${cleanClaim}_$cleanOrder');
      await _plugin.show(
        id: notifId,
        title: notifTitle,
        body: notifBody,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
        ),
        payload: 'WARRANTY_REPLACEMENT:$cleanOrder',
      );
      debugPrint('[NotificationService] Posted warranty replacement alert ($cleanClaim)');
    } catch (e) {
      debugPrint('[NotificationService] showWarrantyReplacementAlert error: $e');
    }
  }

  Future<void> showSupportChatAlert({
    required String threadId,
    String? title,
    String? body,
  }) async {
    if (!_isInitialized) await initialize();
    final cleanTid = threadId.trim();
    if (cleanTid.isEmpty) return;

    final notifTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : 'Zone Support Desk';
    final notifBody = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : 'You have a new reply from your Zone Support Manager.';

    final androidDetails = AndroidNotificationDetails(
      chatChannelId,
      chatChannelName,
      channelDescription: chatChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: notifTitle,
      styleInformation: BigTextStyleInformation(
        notifBody,
        contentTitle: notifTitle,
        summaryText: 'ROParts Support Chat',
      ),
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF0284C7),
      enableVibration: true,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    );

    try {
      await _plugin.show(
        id: _stableNotifId('support_chat_$cleanTid'),
        title: notifTitle,
        body: notifBody,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
        ),
        payload: 'SUPPORT_CHAT:$cleanTid',
      );
    } catch (e) {
      debugPrint('[NotificationService] showSupportChatAlert error: $e');
    }
  }

  Future<String?> consumeLaunchNotificationPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details != null && details.didNotificationLaunchApp) {
        return details.notificationResponse?.payload;
      }
    } catch (e) {
      debugPrint('[NotificationService] launch details check warning: $e');
    }
    return null;
  }
}
