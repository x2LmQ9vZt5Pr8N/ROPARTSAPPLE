import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'models/catalog_snapshot.dart';
import 'models/product.dart';
import 'services/api_service.dart';
import 'services/catalog_media_cache.dart';
import 'state/cart_state.dart';
import 'theme/app_theme.dart';
import 'widgets/ro_header.dart';
import 'widgets/quick_service_banner.dart';
import 'widgets/happy_hour_banner.dart';
import 'widgets/shop_categories_grid.dart';
import 'widgets/product_card.dart';
import 'widgets/alkaline_cartridge_banner.dart';
import 'widgets/maintenance_kits_section.dart';
import 'widgets/brand_marquee.dart';
import 'widgets/know_your_purifier_section.dart';
import 'widgets/refer_buddy_banner.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/cart_bottom_sheet.dart';
import 'widgets/ro_service_screen.dart';
import 'widgets/universal_search_sheet.dart';
import 'widgets/product_detail_sheet.dart';
import 'widgets/menu_drawer.dart';
import '../utils/happy_hour_helper.dart';
import 'widgets/bouncing_widget.dart';
import 'widgets/location_picker_sheet.dart';
import 'widgets/orders_sheet.dart';
import 'widgets/profile_sheet.dart';
import 'widgets/service_history_sheet.dart';
import 'widgets/refer_earn_sheet.dart';
import 'widgets/know_about_ro_sheet.dart';
import 'widgets/technician_qr_scanner_screen.dart';
import 'widgets/category_products_sheet.dart';
import 'state/service_tracking_state.dart';
import 'widgets/technician_tracking_bar.dart';
import 'widgets/technician_live_tracking_screen.dart';
import 'widgets/staggered_entrance.dart';
import 'widgets/auth_sheet.dart';
import 'widgets/map_address_picker_sheet.dart';
import 'models/user_address.dart';
import 'services/notification_service.dart';
import 'widgets/zone_support_chat_sheet.dart';
import 'services/fcm_service.dart';
import 'widgets/web_app_download_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
  };
  // Never display Flutter's harsh red ErrorWidget screen anywhere in the app
  ErrorWidget.builder = (FlutterErrorDetails details) => const SizedBox.shrink();
  final cartState = CartState();
  // Asynchronous non-blocking session restoration ensures immediate time-to-first-frame (<400ms)
  cartState.initSession();
  runApp(RoPartsApp(cartState: cartState));
  // Initialize FCM real-time push engine in background (non-blocking)
  FcmService().initialize();
}

class RoPartsApp extends StatefulWidget {
  final CartState? cartState;
  const RoPartsApp({super.key, this.cartState});

  @override
  State<RoPartsApp> createState() => _RoPartsAppState();
}

class _RoPartsAppState extends State<RoPartsApp> {
  late final CartState _cartState;

  @override
  void initState() {
    super.initState();
    _cartState = widget.cartState ?? CartState();
    if (widget.cartState == null) {
      _cartState.initSession();
    }
  }

  @override
  void dispose() {
    _cartState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ROParts.in - Factory-Direct RO Spares',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: mediaQuery.textScaler.clamp(
              minScaleFactor: 0.90,
              maxScaleFactor: 1.15,
            ),
          ),
          child: child!,
        );
      },
      home: HomeScreen(cartState: _cartState),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final CartState cartState;

  const HomeScreen({
    super.key,
    required this.cartState,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentNavIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final ServiceTrackingState _serviceTrackingState = ServiceTrackingState();
  CatalogSnapshot _catalogSnapshot = CatalogSnapshot.empty();
  List<Product> _liveCatalog = const [];
  bool _isCatalogLoading = true;
  StreamSubscription<CatalogSnapshot>? _catalogFcmSub;
  String? _lastSyncedFcmCustId;
  bool _hasSyncedFcmOnce = false;
  bool _isAwaitingLocationSettings = false;
  bool _hasAutoFetched = false;

  void _openLiveTracking() {
    if (!widget.cartState.isLoggedIn) {
      AuthSheet.show(
        context,
        cartState: widget.cartState,
        onAuthSuccess: () {
          setState(() {});
          _syncActiveVisitFromBackend();
        },
      );
      return;
    }
    if (_isLiveTrackingOpen) return;
    _isLiveTrackingOpen = true;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: 'service_in_progress'),
        builder: (context) => TechnicianLiveTrackingScreen(
          serviceState: _serviceTrackingState,
          cartState: widget.cartState,
        ),
      ),
    ).then((_) {
      _isLiveTrackingOpen = false;
      // Refresh booking state once when user exits the live map screen
      if (mounted && widget.cartState.isLoggedIn) {
        _syncActiveVisitFromBackend();
      }
    });
  }

  void _onCartStateChanged() {
    _ensureFcmCatalogRegistration();
    if (!widget.cartState.isLoggedIn) {
      if (_serviceTrackingState.hasActiveBooking) {
        _serviceTrackingState.resetToIdle();
      }
    } else {
      _syncActiveVisitFromBackend();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.cartState.addListener(_onCartStateChanged);
    unawaited(_hydrateLocalCachesFirst());
    _catalogFcmSub = FcmService().catalogUpdateStream.listen((snap) {
      if (!mounted) return;
      setState(() {
        _catalogSnapshot = snap;
        _liveCatalog = snap.products;
        _isCatalogLoading = false;
      });
    });
    FcmService().configureCallbacks(
      onPayloadReceived: (data) {
        final type = data['type']?.toString();
        if (type == 'CATALOG_UPDATED' || type == 'CONFIG_INVALIDATION') return;
        if (type == 'ONLINE_PAYMENT_RECOVERY') {
          unawaited(widget.cartState.loadActiveOnlineDraft());
          if (data['_opened_from_notification'] == 'true') {
            unawaited(
              _resumeOnlineDraftInCart(draftId: data['draft_id']?.toString()),
            );
          }
          return;
        }
        if (type == 'WARRANTY_REPLACEMENT' ||
            data['action']?.toString() == 'OPEN_ORDERS' ||
            (type != null && type.startsWith('ONLINE_ORDER_'))) {
          if (data['_opened_from_notification'] == 'true' && mounted) {
            _openOrders();
          }
          return;
        }
        if (mounted) _syncActiveVisitFromBackend();
      },
    );
    unawaited(NotificationService().initialize(onNotificationClick: _handleNotificationPayloadRouting));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _autoFetchLocationOnAppOpen();
      unawaited(_syncViaRedisVersionGate());
      _syncActiveVisitFromBackend();
      _ensureFcmCatalogRegistration();
      final launchPayload = await NotificationService().consumeLaunchNotificationPayload();
      if (launchPayload != null && launchPayload.isNotEmpty && mounted) {
        _handleNotificationPayloadRouting(launchPayload);
      }
    });
  }

  bool _isLiveTrackingOpen = false;
  bool _isResumingDraft = false;
  String? _lastNotifiedArrivalOtp;
  String? _lastPreArrivalNotifiedVisit;

  void _handleNotificationPayloadRouting(String? payload) {
    if (!mounted) return;
    final clean = (payload ?? '').trim();
    if (clean.startsWith('ONLINE_RESUME')) {
      final idx = clean.indexOf(':');
      final draftId = idx != -1 ? clean.substring(idx + 1).trim() : null;
      unawaited(_resumeOnlineDraftInCart(draftId: (draftId?.isNotEmpty == true) ? draftId : null));
      return;
    }
    if (clean.startsWith('ONLINE_ORDER_UPDATE') || clean.startsWith('WARRANTY_REPLACEMENT')) {
      _openOrders();
      return;
    }
    if (clean.startsWith('SUPPORT_CHAT:')) {
      final tid = clean.substring('SUPPORT_CHAT:'.length).trim();
      if (tid.isNotEmpty) {
        unawaited(
          showZoneSupportChatSheet(
            context,
            threadId: tid,
            cartState: widget.cartState,
          ),
        );
        return;
      }
    }
    _openLiveTracking();
  }

  Future<void> _resumeOnlineDraftInCart({String? draftId}) async {
    if (_isResumingDraft || !mounted) return;
    _isResumingDraft = true;
    try {
      if (!widget.cartState.isLoggedIn) {
        AuthSheet.show(
          context,
          cartState: widget.cartState,
          onAuthSuccess: () {
            if (mounted) unawaited(_resumeOnlineDraftInCart(draftId: draftId));
          },
        );
        return;
      }
      final res = await widget.cartState.resumeActiveOnlineDraft(draftId: draftId);
      if (!mounted) return;
      if (res['success'] == true || widget.cartState.items.isNotEmpty) {
        final live = res['live_pricing'] is Map ? res['live_pricing'] as Map : null;
        String? bannerMsg;
        if (live != null && live['price_changed'] == true) {
          bannerMsg = 'Live catalog price updated to ₹${live['net_payable']} before payment.';
        } else if (live != null && live['coupon_notice'] != null) {
          bannerMsg = live['coupon_notice'].toString();
        }
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (context) => CartBottomSheet(
            cartState: widget.cartState,
            initialStep: 1,
            resumeDraftId: draftId,
            recoveryBannerMessage: bannerMsg,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (res['error'] ?? 'Saved online order could not be resumed or has expired.').toString(),
            ),
          ),
        );
      }
    } finally {
      _isResumingDraft = false;
    }
  }

  Future<void> _syncActiveVisitFromBackend() async {
    try {
      // Strict Authentication Gate: Never poll or display active visit if user is logged out
      if (!widget.cartState.isLoggedIn) {
        if (_serviceTrackingState.hasActiveBooking) {
          _serviceTrackingState.resetToIdle();
        }
        return;
      }

      final phone = widget.cartState.userPhone;
      if (phone.isEmpty) return;

      final activeVisit = await ApiService().getActiveVisit(phone: phone);
      if (mounted) {
        if (activeVisit != null) {
          final wasArrived = _serviceTrackingState.isArrivedOrConfirmingOtp;
          _serviceTrackingState.updateFromBackend(activeVisit);
          setState(() {});

          // 1. Pre-Arrival Alert: Technician is about to reach (~500m / 2-3 mins away)
          if (_serviceTrackingState.isAboutToReach) {
            final visitId = _serviceTrackingState.bookingId;
            unawaited(
              NotificationService().showPreArrivalAlert(
                visitId: visitId,
                technicianName: _serviceTrackingState.technicianName,
                distanceMeters: _serviceTrackingState.distanceMeters,
                etaMinutes: _serviceTrackingState.etaMinutes,
              ),
            );

            if (_lastPreArrivalNotifiedVisit != visitId) {
              _lastPreArrivalNotifiedVisit = visitId;
              if (!_isLiveTrackingOpen && (ModalRoute.of(context)?.isCurrent ?? true)) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: const Color(0xFF0F766E),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  content: Row(
                    children: [
                      const Icon(Icons.electric_moped_rounded, color: Colors.white, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Technician is about to reach!',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                            ),
                            Text(
                              '${_serviceTrackingState.technicianName} is ~${_serviceTrackingState.distanceMeters?.round() ?? 500}m away. Please prepare the RO area.',
                              style: const TextStyle(fontSize: 11.5, color: Color(0xFFCCFBF1)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  action: SnackBarAction(
                    label: 'TRACK',
                    textColor: Colors.white,
                    onPressed: _openLiveTracking,
                  ),
                ),
              );
              }
            }
          }

          // 2. Doorstep Arrival Alert: Technician has arrived with OTP (<=150m ARRIVED or >150m confirmation)
          if (_serviceTrackingState.isArrivedOrConfirmingOtp) {
            unawaited(
              NotificationService().showDoorstepArrivalAlert(
                visitId: _serviceTrackingState.bookingId,
                technicianName: _serviceTrackingState.technicianName,
                otp: _serviceTrackingState.arrivalOtp,
              ),
            );

            if (!wasArrived || _lastNotifiedArrivalOtp != _serviceTrackingState.arrivalOtp) {
              _lastNotifiedArrivalOtp = _serviceTrackingState.arrivalOtp;
              if (!_isLiveTrackingOpen && (ModalRoute.of(context)?.isCurrent ?? true)) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: const Color(0xFFB45309),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  content: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _serviceTrackingState.isLocationMismatchArrival
                                  ? 'Technician Arrived (Confirm Location)'
                                  : 'Technician Arrived at Doorstep!',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                            ),
                            if (_serviceTrackingState.arrivalOtp != null)
                              Text(
                                'Share OTP to Confirm: ${_serviceTrackingState.arrivalOtp}',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFFEF3C7)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  action: SnackBarAction(
                    label: 'VIEW',
                    textColor: Colors.white,
                    onPressed: _openLiveTracking,
                  ),
                ),
              );
              }
            }
          }
        } else {
          // If no active visit exists in DB, ensure in-memory state is cleared
          if (_serviceTrackingState.hasActiveBooking) {
            _serviceTrackingState.resetToIdle();
          }
        }
      }
    } catch (_) {}
  }

  void _ensureFcmCatalogRegistration() {
    if (!widget.cartState.isSessionInitialized) return;
    final custId = widget.cartState.isLoggedIn ? widget.cartState.customerId : null;
    if (_hasSyncedFcmOnce && _lastSyncedFcmCustId == custId) return;
    _hasSyncedFcmOnce = true;
    _lastSyncedFcmCustId = custId;
    unawaited(
      FcmService().syncCatalogTokenWithAuth(
        customerId: custId,
        force: custId != null && custId.isNotEmpty,
      ),
    );
  }

  Future<void> _hydrateLocalCachesFirst() async {
    try {
      final results = await Future.wait<dynamic>([
        ApiService().readCachedCatalogSnapshot(),
        HappyHourHelper.loadFromLocalCache(),
        CatalogMediaCache().hydrate(),
      ]);
      final cachedCatalog = results[0] as CatalogSnapshot?;
      if (mounted &&
          cachedCatalog != null &&
          (cachedCatalog.products.isNotEmpty ||
              cachedCatalog.kits.isNotEmpty ||
              cachedCatalog.categories.isNotEmpty)) {
        setState(() {
          _catalogSnapshot = cachedCatalog;
          _liveCatalog = cachedCatalog.products;
          _isCatalogLoading = false;
        });
      }
    } catch (_) {}
  }

  Future<void> _syncViaRedisVersionGate({
    bool bypassCooldown = false,
    bool forceCatalogRefresh = false,
  }) async {
    try {
      await CatalogMediaCache().hydrate(force: true);
      final res = await ApiService().syncWithRedisVersionsOnly(
        bypassCooldown: bypassCooldown,
        forceCatalogRefresh: forceCatalogRefresh,
      );
      if (res.happyHourUpdated && res.happyHour != null) {
        HappyHourHelper.updateFromBackend(
          res.happyHour!,
          persist: false,
          version: res.remoteHappyHourVersion,
        );
      }
      if (!mounted) return;
      final snap = res.catalog;
      if (snap != null &&
          (res.catalogUpdated ||
              (_liveCatalog.isEmpty &&
                  (snap.products.isNotEmpty || snap.kits.isNotEmpty)))) {
        setState(() {
          _catalogSnapshot = snap;
          _liveCatalog = snap.products;
          _isCatalogLoading = false;
        });
      } else if (_isCatalogLoading) {
        setState(() => _isCatalogLoading = false);
      }

      if (snap != null) {
        final targetRef = (res.remoteCatalogRef ?? '').trim().isNotEmpty
            ? res.remoteCatalogRef!.trim()
            : snap.catalogRef;
        if (res.catalogUpdated || forceCatalogRefresh) {
          unawaited(
            CatalogMediaCache().syncSnapshotMedia(snap, forceRefreshAll: true),
          );
        } else if (!CatalogMediaCache().isVersionSynced(targetRef, snapshot: snap)) {
          unawaited(
            CatalogMediaCache().syncSnapshotMedia(snap, forceRefreshAll: false),
          );
        }
      }
    } catch (_) {
      if (mounted && _isCatalogLoading) {
        setState(() => _isCatalogLoading = false);
      }
    }
  }

  Future<void> _loadLiveCatalogFromBackend({bool forceRefresh = false}) async {
    await _syncViaRedisVersionGate(
      bypassCooldown: forceRefresh,
      forceCatalogRefresh: forceRefresh,
    );
  }

  @override
  void dispose() {
    _catalogFcmSub?.cancel();
    widget.cartState.removeListener(_onCartStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _serviceTrackingState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncViaRedisVersionGate());
      if (widget.cartState.isLoggedIn) {
        _syncActiveVisitFromBackend();
        unawaited(widget.cartState.claimActivePushDeviceIfLoggedIn());
      }
      if (_isAwaitingLocationSettings) {
        _isAwaitingLocationSettings = false;
        _autoFetchLocationOnAppOpen();
      }
    }
  }

  Future<void> _autoFetchLocationOnAppOpen() async {
    if (kIsWeb) return;
    if (_hasAutoFetched) return;

    try {
      // 1. Check if location services (GPS) are turned on
      final isServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isServiceEnabled) {
        if (mounted) {
          _showTurnOnGpsDialog();
        }
        return;
      }

      // 2. Check & request permission persistently until granted
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            _showRequestPermissionDialog(permanently: false);
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          _showRequestPermissionDialog(permanently: true);
        }
        return;
      }

      // 3. Permission granted: Try instant last-known cached position first (< 5ms)
      Position? position = widget.cartState.cachedLocation;
      position ??= await Geolocator.getLastKnownPosition();

      // If no cached position is available, fetch fresh position with balanced medium accuracy (fast ~100ms)
      if (position == null) {
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 4),
            ),
          );
        } catch (_) {}
      }

      if (position == null) return;

      // 4. Reverse geocode coordinates to get real street, area, city, and pincode
      final placemarks = await Geocoding().placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final pin = p.postalCode?.trim() ?? '';
        final locality = p.locality?.trim() ?? '';
        final subLoc = p.subLocality?.trim() ?? '';
        final street = p.street?.trim() ?? '';
        final subAdmin = p.subAdministrativeArea?.trim() ?? '';
        final admin = p.administrativeArea?.trim() ?? '';

        final areaParts = <String>[];
        if (street.isNotEmpty && !street.contains('+') && !street.toLowerCase().contains(subLoc.toLowerCase())) {
          areaParts.add(street);
        }
        if (subLoc.isNotEmpty) areaParts.add(subLoc);
        if (locality.isNotEmpty && !areaParts.contains(locality)) areaParts.add(locality);

        final detectedArea = areaParts.isNotEmpty
            ? areaParts.join(', ')
            : (subLoc.isNotEmpty ? subLoc : (locality.isNotEmpty ? locality : 'Detected Area'));

        final detectedCity = locality.isNotEmpty
            ? locality
            : (subAdmin.isNotEmpty ? subAdmin : (admin.isNotEmpty ? admin : 'India'));

        if (pin.isNotEmpty) {
          _hasAutoFetched = true;
          widget.cartState.setDefaultGpsAddress(
            pincode: pin,
            city: detectedCity,
            area: detectedArea,
            latitude: position.latitude,
            longitude: position.longitude,
          );

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.near_me_rounded, color: Color(0xFF38BDF8), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Delivering to $pin • $detectedCity',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF0F172A),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Auto fetch location error: $e');
    }
  }

  void _showRequestPermissionDialog({required bool permanently}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: permanently ? const Color(0xFFFEF2F2) : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.near_me_rounded,
                  color: permanently ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  permanently ? 'Location Permission Blocked' : 'Enable Location',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
              ),
            ],
          ),
          content: Text(
            permanently
                ? 'Location permission is permanently disabled in Android settings. Please enable "Allow while using app" in App Settings to auto-detect your delivery pincode.'
                : 'Just like Blinkit & Zepto, RO Parts requires device location to auto-detect your delivery pincode and verify fast doorstep delivery availability.',
            style: const TextStyle(fontSize: 13.5, color: Color(0xFF475569), height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not Now', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                if (permanently) {
                  _isAwaitingLocationSettings = true;
                  await Geolocator.openAppSettings();
                } else {
                  _autoFetchLocationOnAppOpen();
                }
              },
              child: Text(
                permanently ? 'Open App Settings' : 'Allow Location',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showTurnOnGpsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.location_disabled_rounded, color: Color(0xFF0284C7), size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Turn On GPS',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
              ),
            ],
          ),
          content: const Text(
            'Device GPS is turned off. Please enable location services to auto-detect your delivery address and pincode.',
            style: TextStyle(fontSize: 13.5, color: Color(0xFF475569), height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Enter Manually', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                if (!kIsWeb) {
                  _isAwaitingLocationSettings = true;
                  await Geolocator.openLocationSettings();
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please allow location access in your browser site settings.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Turn On GPS', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
  }

  void _openCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CartBottomSheet(cartState: widget.cartState),
    );
  }

  void _openServiceBooking() {
    // 1. Check if customer is logged in
    if (!widget.cartState.isLoggedIn) {
      AuthSheet.show(
        context,
        cartState: widget.cartState,
        onAuthSuccess: () {
          setState(() {});
          _proceedWithServiceLocationFlow();
        },
      );
      return;
    }

    _proceedWithServiceLocationFlow();
  }

  Future<void> _proceedWithServiceLocationFlow() async {
    // 1. SMART CHECK (Zero harassment & 0ms navigation lag):
    // If the customer ALREADY has saved addresses or an active doorstep address,
    // navigate immediately without waiting a fraction of a second for GPS!
    if (widget.cartState.addresses.isNotEmpty || widget.cartState.activeAddress != null) {
      // 0ms instant transition
      _navigateToServiceBooking();

      // Prewarm fresh GPS in background with permission request if needed
      unawaited(widget.cartState.getCurrentOrCachedPosition(requestPermission: true));
      return;
    }

    // 2. Only if 0 saved addresses exist -> Open Map Address Picker once to set up first doorstep address
    final savedAddr = await showModalBottomSheet<UserAddress>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MapAddressPickerSheet(
        cartState: widget.cartState,
        autoLocate: true,
      ),
    );

    if (savedAddr != null && mounted) {
      widget.cartState.selectAddress(savedAddr);
      _navigateToServiceBooking();
    }
  }

  void _navigateToServiceBooking() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoServiceScreen(
          initialPincode: widget.cartState.deliveryPincode,
          serviceState: _serviceTrackingState,
          cartState: widget.cartState,
          onTrackTap: _openLiveTracking,
          onBookSuccess: (data) {
            Navigator.pop(context);
            _openLiveTracking();
          },
        ),
      ),
    );
  }

  void _openSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => UniversalSearchSheet(
        cartState: widget.cartState,
        products: _catalogSnapshot.allBrowseItems,
        onProductSelect: _openProductDetail,
      ),
    );
  }

  void _openProductDetail(Product product) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ProductDetailSheet(
        product: product,
        cartState: widget.cartState,
      ),
    );
  }

  void _openCategory(String categoryId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CategoryProductsSheet(
        initialCategoryId: categoryId,
        cartState: widget.cartState,
        categories: _catalogSnapshot.categories,
        products: _liveCatalog,
        kits: _catalogSnapshot.kits,
        onProductSelect: _openProductDetail,
        onOpenCart: _openCart,
      ),
    );
  }

  void _openHappyHour() {
    // Direct Doorstep Booking without separate page friction
    _openServiceBooking();
  }

  void _openOrders() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => OrdersSheet(
        cartState: widget.cartState,
        serviceState: _serviceTrackingState,
        onTrackServiceTap: _openLiveTracking,
        onResumeSavedDraft: ({draftId}) async {
          Navigator.pop(sheetCtx);
          await _resumeOnlineDraftInCart(draftId: draftId);
        },
      ),
    );
  }

  void _openProfile() {
    if (!widget.cartState.isLoggedIn) {
      AuthSheet.show(context, cartState: widget.cartState, onAuthSuccess: () {
        setState(() {});
      });
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ProfileSheet(cartState: widget.cartState),
    );
  }

  void _openServiceHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ServiceHistorySheet(
        onBookServiceTap: _openServiceBooking,
        serviceState: _serviceTrackingState,
        onTrackServiceTap: _openLiveTracking,
      ),
    );
  }

  void _openReferEarn() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const ReferEarnSheet(),
    );
  }

  void _openKnowAboutRo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => KnowAboutRoSheet(onExploreSpares: _openSearch),
    );
  }

  Future<void> _openQrScanner() async {
    if (WebAppDownloadConfig.isWeb) {
      await showWebAppDownloadSheet(
        context,
        title: 'Scan Genuine RO Spares on ROParts App',
        subtitle:
            'QR & hologram verification with instant up to 80% off works seamlessly inside the ROParts Android App.',
      );
      return;
    }
    final returnedFromPayment = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => TechnicianQrScannerScreen(
          cartState: widget.cartState,
          serviceState: _serviceTrackingState,
        ),
      ),
    );
    if (returnedFromPayment == true &&
        mounted &&
        _serviceTrackingState.hasActiveBooking &&
        !_serviceTrackingState.isCompleted) {
      _openLiveTracking();
    }
  }

  void _openMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => MenuDrawerSheet(
        cartState: widget.cartState,
        onProfileTap: _openProfile,
        onCartTap: _openCart,
        onOrdersTap: _openOrders,
        onServiceHistoryTap: _openServiceHistory,
        onReferEarnTap: _openReferEarn,
        onKnowAboutRoTap: _openKnowAboutRo,
        onTrackTap: _openOrders,
        onShippingTap: () => _showPolicyDialog(
          'Shipping Policy',
          'All RO spare parts are dispatched within 24 hours directly from our partner factories. Express delivery typically takes 2-4 business days across India.',
        ),
        onPrivacyTap: () => _showPolicyDialog(
          'Privacy Policy',
          'Your personal and order data is encrypted and strictly used for processing deliveries and doorstep service bookings. Zero data sharing with third parties.',
        ),
        onTermsTap: () => _showPolicyDialog(
          'Terms & Conditions',
          '100% genuine guaranteed spares. Products covered by standard manufacturer warranty. Installation service by verified technician.',
        ),
        onRefundsTap: () => _showPolicyDialog(
          'Refund & Replacement Policy',
          '7-day hassle-free replacement for defective or mismatched parts. Instant refund upon return inspection.',
        ),
      ),
    );
  }

  void _showOffersDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text('🏷️ ', style: TextStyle(fontSize: 20)),
            Expanded(
              child: Text(
                'Exclusive RO Offers',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: -0.3),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildOfferItem('FIRSTFREE', '100% Free Doorstep RO Service visit fee (₹0 instead of ₹49)'),
            const SizedBox(height: 10),
            _buildOfferItem('ROPARTS15', 'Flat 15% OFF on all inline & spun filter combos'),
            const SizedBox(height: 10),
            _buildOfferItem('FREESHIP', 'Free Express Dispatch across India on all spare orders'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  Widget _buildOfferItem(String code, String desc) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primaryLight,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              code,
              style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.appleBlue, fontSize: 11),
            ),
          ),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(fontSize: 11, color: AppTheme.textPrimary)),
        ],
      ),
    );
  }

  void _showPincodeDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LocationPickerSheet(cartState: widget.cartState),
    );
  }

  void _showPolicyDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: -0.3)),
        content: Text(content, style: const TextStyle(fontSize: 13, color: Color(0xFF475569), height: 1.4)),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final popularProducts = _liveCatalog.take(4).toList();
    final double bottomSafe = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            decoration: const BoxDecoration(
              color: AppTheme.canvas,
              boxShadow: [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
            Column(
              children: [
                // Top Navigation Header (Scoped listener to avoid rebuilding entire scroll feed)
                ListenableBuilder(
                  listenable: widget.cartState,
                  builder: (context, _) => RoHeader(
                    cartState: widget.cartState,
                    onSearchTap: _openSearch,
                    onCartTap: _openCart,
                    onQrScanTap: _openQrScanner,
                    onOffersTap: _showOffersDialog,
                    onPincodeTap: _showPincodeDialog,
                    onProfileTap: _openProfile,
                  ),
                ),

                    // Main Content (100% Domestic Purifiers Focus)
                    Expanded(
                      child: RefreshIndicator(
                        color: AppTheme.appleBlue,
                        onRefresh: () => _loadLiveCatalogFromBackend(forceRefresh: true),
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),

                              // Hero Service Banner (₹49 Doorstep Service)
                              StaggeredEntrance(
                                index: 0,
                                child: QuickServiceBanner(onTap: _openServiceBooking),
                              ),

                              // Happy Hour Live Promo Pill
                              StaggeredEntrance(
                                index: 1,
                                child: HappyHourBanner(onTap: _openHappyHour),
                              ),

                              // 1. Shop Essential Spares (Live DynamoDB Categories)
                              StaggeredEntrance(
                                index: 2,
                                child: ShopCategoriesGrid(
                                  categories: _catalogSnapshot.categories,
                                  products: _liveCatalog,
                                  onCategorySelect: (catId) {
                                    _openCategory(catId);
                                  },
                                ),
                              ),

                              const SizedBox(height: 16),

                              // 2. Popular RO Spare Parts Section (100% Live CBM Master Catalog)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Popular RO Spare Parts',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: AppTheme.textPrimary,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    BouncingWidget(
                                      onTap: () => _openCategory('all'),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'View All Spares',
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w700,
                                              color: AppTheme.appleBlue,
                                              letterSpacing: -0.2,
                                            ),
                                          ),
                                          SizedBox(width: 4),
                                          Icon(
                                            Icons.arrow_forward_ios_rounded,
                                            size: 11,
                                            color: AppTheme.appleBlue,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (popularProducts.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(18),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: const Color(0xFFE2E8F0)),
                                    ),
                                    child: _isCatalogLoading
                                        ? const Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              SizedBox(
                                                width: 18,
                                                height: 18,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              ),
                                              SizedBox(width: 10),
                                              Text(
                                                'Syncing live CBM catalog...',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF475569),
                                                ),
                                              ),
                                            ],
                                          )
                                        : const Text(
                                            'No spare parts published yet. Pull down to sync latest CBM Admin catalog.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              color: Color(0xFF64748B),
                                            ),
                                          ),
                                  ),
                                )
                              else
                                Builder(
                                  builder: (context) {
                                    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(0.9, 1.15);
                                    final double cardExtent = 248.0 + (textScale > 1.0 ? (textScale - 1.0) * 60.0 : 0.0);

                                    return GridView.builder(
                                      padding: const EdgeInsets.symmetric(horizontal: 16),
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        mainAxisExtent: cardExtent,
                                        mainAxisSpacing: 14,
                                        crossAxisSpacing: 12,
                                      ),
                                      itemCount: popularProducts.length,
                                      itemBuilder: (context, index) {
                                        final product = popularProducts[index];
                                        return ProductCard(
                                          product: product,
                                          cartState: widget.cartState,
                                          onTap: () => _openProductDetail(product),
                                        );
                                      },
                                    );
                                  },
                                ),

                              const SizedBox(height: 14),

                              // 3. Alkaline Mineral Cartridge Banner
                              AlkalineCartridgeBanner(
                                onTap: () {
                                  if (_liveCatalog.isEmpty) {
                                    _openCategory('all');
                                    return;
                                  }
                                  final alkalineProduct = _liveCatalog.firstWhere(
                                    (p) =>
                                        p.name.toLowerCase().contains('alkaline') ||
                                        p.name.toLowerCase().contains('mineral'),
                                    orElse: () => _liveCatalog.first,
                                  );
                                  _openProductDetail(alkalineProduct);
                                },
                              ),

                              // 4. RO Maintenance Kits (Live CBM Kit Recipes)
                              MaintenanceKitsSection(
                                kits: _catalogSnapshot.kits,
                                onCompareKits: () => _openCategory('service-kits'),
                                onKitSelect: (kit) => _openProductDetail(kit.toProduct()),
                              ),

                            // 5. Universal Compatibility Strip
                            const BrandMarquee(),

                            // 6. Know Your Purifier DIY Diagnostic Section
                            KnowYourPurifierSection(onTap: _openKnowAboutRo),

                            // 7. Refer a Buddy Banner
                            ReferBuddyBanner(onReferTap: _openReferEarn),

                            const SizedBox(height: 28),

                            // Watermark Copyright Information (Subtle, native, spacious)
                            Center(
                              child: Opacity(
                                opacity: 0.65,
                                child: Column(
                                  children: [
                                    Image.asset(
                                      'assets/images/ropartslogo.png',
                                      height: 22,
                                      fit: BoxFit.contain,
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      '© 2026 Drop Technologies Private Limited',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    const Text(
                                      'GSTIN: 29AAMCD6292Q1ZK • All Rights Reserved',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Generous bottom spacing so it clears the floating coin dock & taller tracking bar
                            SizedBox(height: 240 + bottomSafe),
                          ],
                        ),
                      ),
                    ),
                    ),
                  ],
                ),

                // Scoped Overlay Listener: Rebuilds floating badges when cart items or service tracking change
                ListenableBuilder(
                  listenable: Listenable.merge([widget.cartState, _serviceTrackingState]),
                  builder: (context, _) {
                    final showRecoveryBanner =
                        widget.cartState.itemCount > 0 || widget.cartState.hasActiveRecoveryDraft;
                    final isFailedRecovery = widget.cartState.isRecoveryDraftPaymentFailed;
                    final daysLeft = widget.cartState.recoveryDraftDaysRemaining;
                    final displayPayable = widget.cartState.itemCount > 0
                        ? widget.cartState.finalPayableAmount
                        : widget.cartState.recoveryDraftPayable;

                    return Stack(
                      children: [
                        // Blinkit / Zepto Style Floating Technician Live Tracking Pill
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          bottom: (showRecoveryBanner ? 156 : 96) + bottomSafe,
                          left: 0,
                          right: 0,
                          child: TechnicianTrackingBar(
                            serviceState: _serviceTrackingState,
                            cartState: widget.cartState,
                            onTap: _openLiveTracking,
                          ),
                        ),

                        // Floating Cart / 7-Day Recovery Indicator Pill (Animated Fluid Slide & Fade)
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          bottom: 90 + bottomSafe,
                          left: 16,
                          right: 16,
                          child: AnimatedSlide(
                            offset: showRecoveryBanner ? Offset.zero : const Offset(0, 1.2),
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: showRecoveryBanner ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 220),
                              child: showRecoveryBanner
                                  ? BouncingWidget(
                                      onTap: (widget.cartState.itemCount == 0 || isFailedRecovery)
                                          ? () => _resumeOnlineDraftInCart(
                                                draftId: widget.cartState.activeRecoveryDraft?['draft_id']
                                                    ?.toString(),
                                              )
                                          : _openCart,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        decoration: BoxDecoration(
                                          color: isFailedRecovery
                                              ? const Color(0xFF881337)
                                              : AppTheme.textPrimary,
                                          borderRadius: BorderRadius.circular(16),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.2),
                                              blurRadius: 16,
                                              offset: const Offset(0, 6),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: isFailedRecovery
                                                    ? const Color(0xFFF43F5E)
                                                    : AppTheme.appleBlue,
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: AnimatedSwitcher(
                                                duration: const Duration(milliseconds: 180),
                                                transitionBuilder: (child, anim) =>
                                                    ScaleTransition(scale: anim, child: child),
                                                child: Text(
                                                  widget.cartState.itemCount > 0
                                                      ? '${widget.cartState.itemCount} ITEMS'
                                                      : (isFailedRecovery
                                                          ? 'RETRY PAY'
                                                          : 'SAVED ${daysLeft}D'),
                                                  key: ValueKey<String>(
                                                    '${widget.cartState.itemCount}_$isFailedRecovery',
                                                  ),
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  AnimatedSwitcher(
                                                    duration: const Duration(milliseconds: 180),
                                                    transitionBuilder: (child, anim) =>
                                                        ScaleTransition(scale: anim, child: child),
                                                    child: Text(
                                                      '₹$displayPayable',
                                                      key: ValueKey<int>(displayPayable),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 15,
                                                        fontWeight: FontWeight.w900,
                                                        letterSpacing: -0.4,
                                                      ),
                                                    ),
                                                  ),
                                                  Text(
                                                    isFailedRecovery
                                                        ? 'Payment incomplete · Tap to Retry or COD'
                                                        : (widget.cartState.hasActiveRecoveryDraft
                                                            ? 'Saved for $daysLeft d · Tap to Resume'
                                                            : 'Pan-India Online Store Checkout'),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isFailedRecovery
                                                          ? const Color(0xFFFECDD3)
                                                          : AppTheme.appleGreen,
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Row(
                                              children: [
                                                Text(
                                                  (widget.cartState.itemCount == 0 || isFailedRecovery)
                                                      ? 'Resume'
                                                      : 'View Cart',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                const Icon(Icons.arrow_forward_ios, size: 10, color: Colors.white),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),

                // Floating Frosted Bottom Dock
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: RoBottomNav(
                    currentIndex: _currentNavIndex,
                    onTabSelected: (index) {
                      setState(() => _currentNavIndex = index);
                      if (index == 0 && _scrollController.hasClients) {
                        _scrollController.animateTo(
                          0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    },
                    onServiceBookTap: _openServiceBooking,
                    onMenuTap: _openMenu,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
}
