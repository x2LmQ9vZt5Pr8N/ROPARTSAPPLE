import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../models/catalog_snapshot.dart';
import '../utils/happy_hour_helper.dart';
import 'api_service.dart';
import 'catalog_media_cache.dart';
import 'notification_service.dart';

/// Top-level background message handler required by Firebase Messaging
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint('[FCM Background] Firebase init warning: $e');
  }
  debugPrint('[FCM Background] Title: ${message.notification?.title}, Data: ${message.data}');
  final data = message.data;
  if (data.isEmpty) return;
  final type = data['type']?.toString();
  final entity = data['entity']?.toString();
  if (type == 'CATALOG_UPDATED' ||
      (type == 'CONFIG_INVALIDATION' && entity == 'catalog')) {
    final incomingRef = data['catalog_ref']?.toString();
    await ApiService.markCatalogDirtyInPrefs(incomingRef);
    await CatalogMediaCache.markMediaDirtyInPrefs(incomingRef);
    return;
  }
  if (type == 'TECHNICIAN_PRE_ARRIVAL' || type == 'PRE_ARRIVAL_500M') {
    await NotificationService().initialize();
    await NotificationService().showPreArrivalAlert(
      visitId: data['visit_id']?.toString() ?? '',
      technicianName: data['technician_name']?.toString() ?? 'Your technician',
      distanceMeters: double.tryParse(data['distance_meters']?.toString() ?? ''),
      etaMinutes: int.tryParse(data['eta_minutes']?.toString() ?? ''),
    );
  } else if (type == 'TECHNICIAN_ARRIVED' || type == 'DOORSTEP_ARRIVED') {
    await NotificationService().initialize();
    await NotificationService().showDoorstepArrivalAlert(
      visitId: data['visit_id']?.toString() ?? '',
      technicianName: data['technician_name']?.toString() ?? 'Technician',
      otp: data['otp']?.toString() ?? data['arrival_otp']?.toString(),
    );
  } else if (type == 'ONLINE_PAYMENT_RECOVERY' && message.notification == null) {
    await NotificationService().initialize();
    await NotificationService().showOnlineRecoveryAlert(
      draftId: data['draft_id']?.toString() ?? 'active',
      title: data['title']?.toString(),
      body: data['body']?.toString(),
      orderNumber: data['order_number']?.toString(),
    );
  } else if (type != null && type.startsWith('ONLINE_ORDER_') && message.notification == null) {
    await NotificationService().initialize();
    await NotificationService().showOnlineOrderStatusAlert(
      orderNumber: data['order_number']?.toString() ?? '',
      title: data['title']?.toString(),
      body: data['body']?.toString(),
      eventType: type,
    );
  }
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  bool _isInitialized = false;
  bool _catalogTopicSubscribed = false;
  bool _hasCompletedTokenSyncOnce = false;
  bool _catalogSyncRequested = false;
  String? _catalogCustomerId;
  Future<void>? _initFuture;
  Future<void>? _topicSubscribeFuture;
  Function(Map<String, dynamic> data)? _onPayloadReceived;
  Function(String token)? _onTokenRefreshCallback;
  Map<String, dynamic>? _pendingTapPayload;
  final StreamController<Map<String, dynamic>> _payloadStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get payloadStream =>
      _payloadStreamController.stream;
  final StreamController<CatalogSnapshot> _catalogUpdateController =
      StreamController<CatalogSnapshot>.broadcast();
  Stream<CatalogSnapshot> get catalogUpdateStream =>
      _catalogUpdateController.stream;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedAppSub;

  String get _platformName {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    return 'android';
  }

  /// Updates listeners after initial boot without re-subscribing Firebase streams.
  void configureCallbacks({
    Function(Map<String, dynamic> data)? onPayloadReceived,
    Function(String token)? onTokenRefresh,
  }) {
    if (onPayloadReceived != null) {
      _onPayloadReceived = onPayloadReceived;
      final deferred = _pendingTapPayload;
      if (deferred != null) {
        _pendingTapPayload = null;
        scheduleMicrotask(() => _onPayloadReceived?.call(deferred));
      }
    }
    if (onTokenRefresh != null) _onTokenRefreshCallback = onTokenRefresh;
  }

  /// Initializes Firebase and sets up real-time push listeners idempotently.
  /// Runs asynchronously without blocking UI or first frame render.
  Future<void> initialize({
    Function(Map<String, dynamic> data)? onPayloadReceived,
    Function(String token)? onTokenRefresh,
  }) async {
    configureCallbacks(
      onPayloadReceived: onPayloadReceived,
      onTokenRefresh: onTokenRefresh,
    );
    if (_isInitialized) return;
    if (_initFuture != null) return _initFuture;

    _initFuture = _initializeInternal();
    try {
      await _initFuture;
    } finally {
      _initFuture = null;
    }
  }

  Future<String?> _waitForApnsTokenIfIos(FirebaseMessaging messaging) async {
    if (kIsWeb || !Platform.isIOS) return null;
    for (int attempt = 0; attempt < 6; attempt++) {
      try {
        final apnsToken = await messaging.getAPNSToken();
        if (apnsToken != null && apnsToken.isNotEmpty) {
          return apnsToken;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return null;
  }

  Future<void> _initializeInternal() async {
    if (kIsWeb) {
      _isInitialized = true;
      return;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Request permission on modern Android / iOS
      final messaging = FirebaseMessaging.instance;
      if (!kIsWeb && Platform.isIOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      debugPrint('[FCM] Permission status: ${settings.authorizationStatus}');

      if (!kIsWeb && Platform.isIOS) {
        final apnsToken = await _waitForApnsTokenIfIos(messaging);
        debugPrint('[FCM] iOS APNs ready=${apnsToken != null && apnsToken.isNotEmpty}');
      }

      // Fetch registration token (never abort init if APNs is still warming on iOS Simulator/first boot)
      try {
        _fcmToken = await messaging.getToken();
      } catch (tokenErr) {
        debugPrint('[FCM] getToken deferred (waiting for APNs/Play Services): $tokenErr');
      }
      debugPrint('[FCM] Device Token: $_fcmToken');
      if (_fcmToken != null && _fcmToken!.isNotEmpty) {
        _onTokenRefreshCallback?.call(_fcmToken!);
        unawaited(_ensureCatalogUpdatesTopic());
      }

      // Listen for token refreshes (single subscription)
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        debugPrint('[FCM] Token refreshed: $_fcmToken');
        _onTokenRefreshCallback?.call(newToken);
        unawaited(_ensureCatalogUpdatesTopic());
        if (_hasCompletedTokenSyncOnce || _catalogSyncRequested) {
          _hasCompletedTokenSyncOnce = true;
          unawaited(
            ApiService().registerCatalogPushToken(
              fcmToken: newToken,
              customerId: _catalogCustomerId,
              platform: _platformName,
              force: true,
            ),
          );
        }
      });

      // Foreground message listener (single subscription)
      await _onMessageSub?.cancel();
      _onMessageSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('[FCM Foreground] Got message: ${message.data}');
        _handleIncomingPayload({
          ...message.data,
          if (message.notification?.title != null && !message.data.containsKey('title'))
            'title': message.notification!.title,
          if (message.notification?.body != null && !message.data.containsKey('body'))
            'body': message.notification!.body,
        }, fromUserTap: false);
      });

      // User tapped notification from background (single subscription)
      await _onOpenedAppSub?.cancel();
      _onOpenedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM Opened] User clicked notification: ${message.data}');
        _handleIncomingPayload(message.data, fromUserTap: true);
      });

      // Check if launched from a terminated state via notification click
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('[FCM Initial] App launched via notification: ${initialMessage.data}');
        _handleIncomingPayload(initialMessage.data, fromUserTap: true);
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint('[FCM] Initialization warning: $e');
    }
  }

  Future<void> _ensureCatalogUpdatesTopic() {
    if (kIsWeb || _catalogTopicSubscribed) return Future.value();
    if (_topicSubscribeFuture != null) return _topicSubscribeFuture!;
    _topicSubscribeFuture = () async {
      try {
        if (!kIsWeb && Platform.isIOS) {
          final apns = await FirebaseMessaging.instance.getAPNSToken();
          if (apns == null || apns.isEmpty) {
            debugPrint('[FCM] Deferring catalog_updates topic subscribe until APNs token is ready');
            return;
          }
        }
        await FirebaseMessaging.instance.subscribeToTopic('catalog_updates');
        _catalogTopicSubscribed = true;
        debugPrint('[FCM] Subscribed to catalog_updates topic');
      } catch (e) {
        debugPrint('[FCM] catalog_updates topic subscribe warning: $e');
      } finally {
        _topicSubscribeFuture = null;
      }
    }();
    return _topicSubscribeFuture!;
  }

  /// Ensures topic `catalog_updates` and a customer or guest FCM token are registered for emergency pushes.
  Future<void> syncCatalogTokenWithAuth({
    String? customerId,
    bool force = false,
  }) async {
    _catalogSyncRequested = true;
    final cleanId = (customerId ?? '').trim();
    final previousId = (_catalogCustomerId ?? '').trim();
    final nextId = cleanId.isNotEmpty ? cleanId : null;
    final authChangedAfterSync =
        _hasCompletedTokenSyncOnce && previousId != (nextId ?? '');
    _catalogCustomerId = nextId;

    await initialize();
    await _ensureCatalogUpdatesTopic();

    if ((_fcmToken == null || _fcmToken!.isEmpty) && !kIsWeb && Platform.isIOS) {
      try {
        final apns = await _waitForApnsTokenIfIos(FirebaseMessaging.instance);
        if (apns != null && apns.isNotEmpty) {
          _fcmToken = await FirebaseMessaging.instance.getToken();
          await _ensureCatalogUpdatesTopic();
        }
      } catch (_) {}
    }

    final token = _fcmToken;
    if (token == null || token.isEmpty) return;

    _hasCompletedTokenSyncOnce = true;
    await ApiService().registerCatalogPushToken(
      fcmToken: token,
      customerId: _catalogCustomerId,
      platform: _platformName,
      force: force || authChangedAfterSync,
    );
  }

  /// Subscribe or unsubscribe from customer broadcast topic based on auth state.
  Future<void> syncBroadcastTopic({required bool subscribed}) async {
    try {
      if (kIsWeb) return;
      final messaging = FirebaseMessaging.instance;
      if (subscribed) {
        await messaging.subscribeToTopic('customer_broadcast');
      } else {
        await messaging.unsubscribeFromTopic('customer_broadcast');
      }
    } catch (e) {
      debugPrint('[FCM] Topic sync warning: $e');
    }
  }

  void _handleIncomingPayload(
    Map<String, dynamic> data, {
    bool fromUserTap = false,
  }) {
    if (data.isEmpty) return;

    final type = data['type']?.toString();
    final entity = data['entity']?.toString();

    // 0. Emergency / live catalog invalidation push
    if (type == 'CATALOG_UPDATED' ||
        (type == 'CONFIG_INVALIDATION' && entity == 'catalog')) {
      final incomingRef = data['catalog_ref']?.toString();
      final emergency = data['emergency']?.toString().toLowerCase() == 'true';
      debugPrint('[FCM] Catalog ${emergency ? "EMERGENCY " : ""}push received ($incomingRef)');
      unawaited(ApiService.markCatalogDirtyInPrefs(incomingRef));
      unawaited(CatalogMediaCache.markMediaDirtyInPrefs(incomingRef));
      unawaited(
        ApiService()
            .handleCatalogUpdateFcmPush(catalogRef: incomingRef, emergency: emergency)
            .then((snap) {
          if (snap != null) {
            unawaited(
              CatalogMediaCache().syncSnapshotMedia(snap, forceRefreshAll: true),
            );
            if (!_catalogUpdateController.isClosed) {
              _catalogUpdateController.add(snap);
            }
          }
        }),
      );
      if (!_payloadStreamController.isClosed) {
        _payloadStreamController.add(data);
      }
      return;
    }

    // 1. Tier 1: Happy Hour Silent Invalidation (handles both String JSON & Map)
    if (type == 'CONFIG_INVALIDATION' && entity == 'happy_hour') {
      debugPrint('[FCM] Happy Hour live invalidation received via push');
      final rawPayload = data['payload'];
      Map<String, dynamic>? decodedPayload;
      if (rawPayload is Map) {
        decodedPayload = rawPayload.map((k, v) => MapEntry(k.toString(), v));
      } else if (rawPayload is String && rawPayload.trim().isNotEmpty) {
        try {
          final parsed = jsonDecode(rawPayload);
          if (parsed is Map) {
            decodedPayload = parsed.map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (e) {
          debugPrint('[FCM] Happy hour payload decode failed: $e');
        }
      }
      if (decodedPayload != null) {
        HappyHourHelper.updateFromBackend(decodedPayload);
      } else {
        HappyHourHelper.syncWithBackend(forceRefresh: true);
      }
    }

    // 2. Pre-Arrival Alert: Technician is ~500m away
    if (type == 'TECHNICIAN_PRE_ARRIVAL' || type == 'PRE_ARRIVAL_500M') {
      final visitId = data['visit_id']?.toString() ?? '';
      final techName = data['technician_name']?.toString() ?? 'Your technician';
      final dist = double.tryParse(data['distance_meters']?.toString() ?? '');
      final eta = int.tryParse(data['eta_minutes']?.toString() ?? '');
      unawaited(
        NotificationService().showPreArrivalAlert(
          visitId: visitId,
          technicianName: techName,
          distanceMeters: dist,
          etaMinutes: eta,
        ),
      );
    } else if (type == 'TECHNICIAN_ARRIVED' || type == 'DOORSTEP_ARRIVED') {
      final visitId = data['visit_id']?.toString() ?? '';
      final techName = data['technician_name']?.toString() ?? 'Technician';
      final otp = data['otp']?.toString() ?? data['arrival_otp']?.toString();
      unawaited(
        NotificationService().showDoorstepArrivalAlert(
          visitId: visitId,
          technicianName: techName,
          otp: otp,
        ),
      );
    } else if (type == 'ONLINE_PAYMENT_RECOVERY' && !fromUserTap) {
      unawaited(
        NotificationService().showOnlineRecoveryAlert(
          draftId: data['draft_id']?.toString() ?? 'active',
          title: data['title']?.toString(),
          body: data['body']?.toString(),
          orderNumber: data['order_number']?.toString(),
        ),
      );
    } else if (type == 'WARRANTY_REPLACEMENT' && !fromUserTap) {
      unawaited(
        NotificationService().showWarrantyReplacementAlert(
          claimId: data['claim_id']?.toString() ?? '',
          orderNumber: data['order_number']?.toString() ?? '',
          title: data['title']?.toString(),
          body: data['body']?.toString(),
          newSerialQr: data['new_serial_qr']?.toString(),
          defectReason: data['defect_reason']?.toString(),
        ),
      );
    } else if (type != null && type.startsWith('ONLINE_ORDER_') && !fromUserTap) {
      unawaited(
        NotificationService().showOnlineOrderStatusAlert(
          orderNumber: data['order_number']?.toString() ?? '',
          title: data['title']?.toString(),
          body: data['body']?.toString(),
          eventType: type,
        ),
      );
    } else if (type == 'SUPPORT_CHAT_MESSAGE' && !fromUserTap) {
      unawaited(
        NotificationService().showSupportChatAlert(
          threadId: data['thread_id']?.toString() ?? '',
          title: data['title']?.toString(),
          body: data['body']?.toString(),
        ),
      );
    }

    // 3. Custom callback hook & broadcast stream for active screen state reconciliation
    final enriched = <String, dynamic>{
      ...data,
      if (fromUserTap) '_opened_from_notification': 'true',
    };
    if (fromUserTap && _onPayloadReceived == null) {
      _pendingTapPayload = enriched;
    } else {
      _onPayloadReceived?.call(enriched);
    }
    if (!_payloadStreamController.isClosed) {
      _payloadStreamController.add(enriched);
    }
  }
}
