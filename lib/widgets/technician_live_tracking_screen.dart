import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/route_service.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import '../services/notification_service.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/display_sanitizer.dart';
import 'technician_qr_scanner_screen.dart';
import 'know_about_ro_sheet.dart';
import 'technician_rating_widgets.dart';
import 'visit_chat_sheet.dart';
import 'zone_support_chat_sheet.dart';
import 'web_app_download_sheet.dart';

const Duration kTrackingAutoRecenterPauseDuration = Duration(seconds: 5);
const Duration kTrackingCameraTransitionDuration = Duration(milliseconds: 680);

/// Whether the interactive map preview ("VIEW MAP") should be offered.
/// Hidden when technician has not started travelling or is already at doorstep.
bool shouldShowLiveMapPreview({required bool isEnRoute}) => isEnRoute;

/// Whether external road-routing requests (OSRM) should run.
/// Strictly gated so minimized maps or non-travelling states hit 0 routing APIs.
bool shouldFetchLiveRoadRoute({
  required bool isEnRoute,
  required bool isMapExpanded,
}) =>
    isEnRoute && isMapExpanded;

/// Adaptive foreground polling cadence to avoid wasted API hits when map is unused.
Duration recommendedTrackingPollInterval({
  required bool isEnRoute,
  required bool isMapExpanded,
  required bool isStationary,
}) {
  if (isEnRoute && isMapExpanded) {
    return isStationary ? const Duration(seconds: 10) : const Duration(seconds: 5);
  }
  if (isEnRoute) {
    return const Duration(seconds: 15);
  }
  // Idle/stationary states rely on immediate FCM push triggers; keep rare safety-net only.
  return const Duration(seconds: 120);
}

/// Collects doorstep destination, live technician position, and sampled
/// remaining road tail points so `CameraFit.bounds` frames everything in one view.
List<ll.LatLng> buildTrackingFramePoints({
  required ll.LatLng doorstep,
  ll.LatLng? vehiclePos,
  List<ll.LatLng> remainingPolyline = const [],
  int maxTailSamples = 14,
}) {
  final points = <ll.LatLng>[doorstep];
  if (vehiclePos != null) {
    points.add(vehiclePos);
  }
  if (remainingPolyline.isNotEmpty) {
    final step = remainingPolyline.length <= maxTailSamples
        ? 1
        : (remainingPolyline.length / maxTailSamples).ceil();
    for (int i = 0; i < remainingPolyline.length; i += step) {
      points.add(remainingPolyline[i]);
    }
    points.add(remainingPolyline.last);
  }
  return points;
}

class TechnicianLiveTrackingScreen extends StatefulWidget {
  final ServiceTrackingState serviceState;
  final CartState cartState;
  final List<Map<String, dynamic>>? initialPurchasedSpares;
  final bool enableLiveSync;

  const TechnicianLiveTrackingScreen({
    super.key,
    required this.serviceState,
    required this.cartState,
    this.initialPurchasedSpares,
    this.enableLiveSync = true,
  });

  @override
  State<TechnicianLiveTrackingScreen> createState() =>
      _TechnicianLiveTrackingScreenState();
}

class _TechnicianLiveTrackingScreenState
    extends State<TechnicianLiveTrackingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  Timer? _pollTimer;
  Timer? _recenterCooldownTimer;
  final MapController _mapController = MapController();
  final Set<int> _activeMapPointers = <int>{};

  // Smooth vehicle movement & camera transition animations
  AnimationController? _moveController;
  AnimationController? _pulseController;
  AnimationController? _cameraController;
  ll.LatLng? _camStartCenter;
  double? _camStartZoom;
  ll.LatLng? _camEndCenter;
  double? _camEndZoom;
  final ValueNotifier<int> _mapFrameTick = ValueNotifier<int>(0);
  ll.LatLng? _currentVehiclePos;
  double _vehicleBearing = 0.0;

  // Polyline sub-segment path snapping & 60 FPS interpolation
  List<ll.LatLng> _activeSubPath = [];
  List<double> _subPathCumulativeDistances = [];
  List<ll.LatLng> _roadPolyline = [];
  List<ll.LatLng> _traveledPolyline = [];
  List<ll.LatLng> _remainingPolyline = [];
  bool _fetchingRoute = false;
  ll.LatLng? _lastRouteFetchPos;
  int _lastSnapSegmentIndex = 0;

  // State flags & Versioning
  int _trackingVersion = 0;
  bool _autoCenter = true;
  bool _isUserInteractingWithMap = false;
  bool _isMapReady = false;
  bool _isMapExpanded = false;
  bool _isStationary = false;
  bool _isServiceCardExpanded = false;
  Duration _currentPollInterval = const Duration(seconds: 15);
  String? _lastSyncedVisitId;
  Map<String, dynamic>? _catalogHighlights;
  List<Map<String, dynamic>> _purchasedSpares = [];
  bool _isRespondingMutualCancel = false;
  StreamSubscription<Map<String, dynamic>>? _chatFcmSub;
  int _unreadChatCount = 0;
  bool _isChatSheetOpen = false;
  BuildContext? _chatSheetContext;
  bool _hasShownChatEndedSnack = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.serviceState.addListener(_handleServiceStateChange);
    if (widget.initialPurchasedSpares != null) {
      _purchasedSpares = List<Map<String, dynamic>>.from(widget.initialPurchasedSpares!);
    }
    if (widget.enableLiveSync) {
      _syncPurchasedSpares();
      _syncCatalogHighlights();
    }

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.enableLiveSync && _isMapExpanded && widget.serviceState.isEnRoute) {
      _pulseController!.repeat();
    }

    _cameraController = AnimationController(
      vsync: this,
      duration: kTrackingCameraTransitionDuration,
    );
    final curvedCamera = CurvedAnimation(
      parent: _cameraController!,
      curve: Curves.easeOutCubic,
    );
    _cameraController!.addListener(() {
      if (!_isMapReady || _isUserInteractingWithMap) return;
      final sC = _camStartCenter;
      final eC = _camEndCenter;
      final sZ = _camStartZoom;
      final eZ = _camEndZoom;
      if (sC == null || eC == null || sZ == null || eZ == null) return;
      final t = curvedCamera.value;
      final lat = sC.latitude + (eC.latitude - sC.latitude) * t;
      final lng = sC.longitude + (eC.longitude - sC.longitude) * t;
      final zoom = sZ + (eZ - sZ) * t;
      try {
        _mapController.move(ll.LatLng(lat, lng), zoom);
      } catch (_) {}
    });

    _moveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4900),
    );

    _moveController?.addListener(() {
      if (_activeSubPath.length < 2 || _subPathCumulativeDistances.isEmpty) {
        return;
      }
      final t = _moveController!.value;
      final totalDist = _subPathCumulativeDistances.last;
      if (totalDist <= 0.0) return;

      final targetDist = t * totalDist;

      // Locate active sub-segment along polyline
      int segIndex = 0;
      for (int i = 0; i < _subPathCumulativeDistances.length - 1; i++) {
        if (targetDist >= _subPathCumulativeDistances[i] &&
            targetDist <= _subPathCumulativeDistances[i + 1]) {
          segIndex = i;
          break;
        }
      }

      final segStart = _activeSubPath[segIndex];
      final segEnd = _activeSubPath[segIndex + 1];
      final segDist = _subPathCumulativeDistances[segIndex + 1] -
          _subPathCumulativeDistances[segIndex];
      final segT = segDist > 0.0
          ? (targetDist - _subPathCumulativeDistances[segIndex]) / segDist
          : 0.0;

      final lat =
          segStart.latitude + (segEnd.latitude - segStart.latitude) * segT;
      final lng =
          segStart.longitude + (segEnd.longitude - segStart.longitude) * segT;
      final currentPos = ll.LatLng(lat, lng);

      // Shortest-arc tangent bearing rotation along active road segment
      final segBearing = _calculateBearing(segStart, segEnd);
      final diff = (segBearing - _vehicleBearing + 540) % 360 - 180;
      final smoothedBearing = (_vehicleBearing + diff * 0.20) % 360;

      // Marker glide updates route split smoothly without jarring camera snaps
      _updatePolylineSplit(currentPos);

      _currentVehiclePos = currentPos;
      _vehicleBearing = smoothedBearing;
      _mapFrameTick.value++;
    });

    if (widget.enableLiveSync) {
      _currentPollInterval = recommendedTrackingPollInterval(
        isEnRoute: widget.serviceState.isEnRoute,
        isMapExpanded: false,
        isStationary: false,
      );
      _startSyncPolling();
      _chatFcmSub = FcmService().payloadStream.listen((data) {
        if (!mounted) return;
        final type = (data['type'] ?? data['event_type'] ?? '').toString().toUpperCase();
        if (type == 'CHAT_MESSAGE') {
          final s = widget.serviceState;
          if (!_isChatSheetOpen &&
              !s.isArrived &&
              !s.isInService &&
              !s.isCompleted &&
              !s.isCancelled) {
            setState(() => _unreadChatCount += 1);
          }
          return;
        }
        if (type.startsWith('TECHNICIAN_') ||
            type.startsWith('SERVICE_') ||
            type.startsWith('VISIT_') ||
            type.startsWith('MUTUAL_CANCEL') ||
            type == 'PRE_ARRIVAL_500M' ||
            type == 'DOORSTEP_ARRIVED' ||
            type == 'JOB_ASSIGNED') {
          unawaited(_syncActiveVisit());
        }
      });
    }
  }

  void _stopMapAnimations() {
    _pulseController?.stop();
    _moveController?.stop();
    _cameraController?.stop();
    _recenterCooldownTimer?.cancel();
  }

  void _expandLiveMap() {
    if (!shouldShowLiveMapPreview(isEnRoute: widget.serviceState.isEnRoute)) {
      return;
    }
    setState(() {
      _isMapExpanded = true;
      _autoCenter = true;
      _isUserInteractingWithMap = false;
    });
    _pulseController?.repeat();
    final state = widget.serviceState;
    if (state.technicianLat != null && state.technicianLng != null) {
      final pos = _currentVehiclePos ??
          ll.LatLng(state.technicianLat!, state.technicianLng!);
      final doorstep = ll.LatLng(state.customerLat, state.customerLng);
      _fetchRoadRoute(pos, doorstep);
    }
    _reschedulePollTimer(
      recommendedTrackingPollInterval(
        isEnRoute: true,
        isMapExpanded: true,
        isStationary: _isStationary,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isMapExpanded) {
        _frameTrackingView(force: true, snap: true);
      }
    });
  }

  void _minimizeLiveMap() {
    if (!_isMapExpanded) return;
    _stopMapAnimations();
    setState(() {
      _isMapExpanded = false;
      _isMapReady = false;
    });
    _reschedulePollTimer(
      recommendedTrackingPollInterval(
        isEnRoute: widget.serviceState.isEnRoute,
        isMapExpanded: false,
        isStationary: _isStationary,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // App minimized or backgrounded: 0 network requests & 0 CPU cycles
      _pollTimer?.cancel();
      _pollTimer = null;
      _stopMapAnimations();
    } else if (state == AppLifecycleState.resumed) {
      // App resumed: pulse & route only when live map is actively expanded
      if (_isMapExpanded && widget.serviceState.isEnRoute) {
        _pulseController?.repeat();
      }
      if (!widget.serviceState.isCompleted && !widget.serviceState.isCancelled) {
        _syncActiveVisit();
        _reschedulePollTimer(_currentPollInterval, force: true);
      }
    }
  }

  void _startSyncPolling() {
    _syncActiveVisit();
    _reschedulePollTimer(_currentPollInterval, force: true);
  }

  void _reschedulePollTimer(Duration interval, {bool force = false}) {
    if (!force && _pollTimer != null && _currentPollInterval == interval) {
      return;
    }
    _currentPollInterval = interval;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) {
      _syncActiveVisit();
    });
  }

  Future<void> _syncActiveVisit() async {
    // Strict Authentication Gate: If user is logged out, reset state and exit screen immediately
    if (!widget.cartState.isLoggedIn) {
      widget.serviceState.resetToIdle();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    final phone = widget.cartState.userPhone.isNotEmpty
        ? widget.cartState.userPhone
        : (widget.serviceState.receiverPhone ?? '');
    final customerId = widget.cartState.customerId;
    if (phone.isEmpty && (customerId == null || customerId.isEmpty)) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    final active = await ApiService().getActiveVisit(
      phone: phone.isNotEmpty ? phone : null,
      customerId: customerId,
      trackingVersion: _trackingVersion,
    );
    if (!mounted) return;

    if (active != null) {
      if (active['unchanged'] == true) {
        // Stationary / no new coordinate received: zero extra API calls & zero state overwrites
        if (!_isStationary && mounted) {
          setState(() {
            _isStationary = true;
          });
        } else {
          _isStationary = true;
        }
        _reschedulePollTimer(
          recommendedTrackingPollInterval(
            isEnRoute: widget.serviceState.isEnRoute,
            isMapExpanded: _isMapExpanded,
            isStationary: true,
          ),
        );
        return;
      }

      final activeVisitId = (active['id'] ?? '').toString().trim();
      if (activeVisitId.isNotEmpty && _lastSyncedVisitId != null && _lastSyncedVisitId != activeVisitId) {
        _purchasedSpares = [];
        _lastSyncedVisitId = activeVisitId;
      }

      final status = active['status'];
      // When Service is in Progress, Completed, or Cancelled: stop live GPS animations & polling when closed
      if (status == 'IN_PROGRESS' ||
          status == 'COMPLETED' ||
          status == 'CANCELLED' ||
          status == 'CANCELLED_NO_CUSTOMER_SHOW') {
        _stopMapAnimations();
        _isMapExpanded = false;
        _isMapReady = false;
        if (status == 'COMPLETED' ||
            status == 'CANCELLED' ||
            status == 'CANCELLED_NO_CUSTOMER_SHOW') {
          _pollTimer?.cancel();
          _pollTimer = null;
        } else {
          _reschedulePollTimer(
            recommendedTrackingPollInterval(
              isEnRoute: false,
              isMapExpanded: false,
              isStationary: _isStationary,
            ),
          );
        }
        if (active['tracking_version'] != null) {
          _trackingVersion = active['tracking_version'] is int
              ? active['tracking_version']
              : (int.tryParse(active['tracking_version'].toString()) ??
                  _trackingVersion);
        }
        widget.serviceState.updateFromBackend(active);
        if (status == 'IN_PROGRESS' || status == 'COMPLETED') {
          _syncPurchasedSpares();
        }
        if (mounted) setState(() {});
        return;
      }

      // When Technician is at Doorstep: collapse map & stop movement animations/routing
      if (status == 'ARRIVED') {
        _stopMapAnimations();
        _isMapExpanded = false;
        _isMapReady = false;
        _reschedulePollTimer(
          recommendedTrackingPollInterval(
            isEnRoute: false,
            isMapExpanded: false,
            isStationary: _isStationary,
          ),
        );
        if (active['tracking_version'] != null) {
          _trackingVersion = active['tracking_version'] is int
              ? active['tracking_version']
              : (int.tryParse(active['tracking_version'].toString()) ??
                  _trackingVersion);
        }
        widget.serviceState.updateFromBackend(active);
        _syncPurchasedSpares();
        if (mounted) setState(() {});
        return;
      }

      if (active['tracking_version'] != null) {
        _trackingVersion = active['tracking_version'] is int
            ? active['tracking_version']
            : (int.tryParse(active['tracking_version'].toString()) ??
                _trackingVersion);
      }

      widget.serviceState.updateFromBackend(active);
      if (!widget.serviceState.isEnRoute) {
        _stopMapAnimations();
        _isMapExpanded = false;
        _isMapReady = false;
      }
      _handleTechnicianLocationUpdate();
    } else {
      // Network timeout or temporary failure: retain existing active state and retry next poll
      debugPrint(
          '[TrackingScreen] Active visit sync returned null, retaining current state.');
    }
  }

  Future<void> _syncCatalogHighlights() async {
    try {
      final highlights = await ApiService().getCatalogHighlights();
      if (mounted && highlights != null) {
        setState(() {
          _catalogHighlights = highlights;
        });
      }
    } catch (_) {}
  }

  Future<void> _syncPurchasedSpares() async {
    try {
      final visitId = widget.serviceState.bookingId.trim();
      if (visitId.isEmpty) {
        if (mounted && (_purchasedSpares.isNotEmpty || _lastSyncedVisitId != null)) {
          setState(() {
            _lastSyncedVisitId = null;
            _purchasedSpares = [];
          });
        }
        return;
      }

      if (_lastSyncedVisitId != null && _lastSyncedVisitId != visitId) {
        if (mounted) {
          setState(() {
            _purchasedSpares = [];
          });
        } else {
          _purchasedSpares = [];
        }
      }
      _lastSyncedVisitId = visitId;

      final customerId = widget.cartState.customerId ?? widget.cartState.userPhone;
      final res = await ApiService().getVisitPurchases(visitId, customerId: customerId);
      if (!mounted || widget.serviceState.bookingId.trim() != visitId) return;
      if (res != null &&
          (res['success'] == true || res['purchases'] != null || res['movements'] != null)) {
        final purchases = (res['purchases'] is List)
            ? (res['purchases'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];
        final movements = (res['movements'] is List)
            ? (res['movements'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];
        final list = purchases.isNotEmpty ? purchases : movements;
        setState(() {
          _purchasedSpares = list;
        });
      }
    } catch (_) {}
  }

  double _calculateBearing(ll.LatLng from, ll.LatLng to) {
    final lat1 = from.latitude * (math.pi / 180.0);
    final lon1 = from.longitude * (math.pi / 180.0);
    final lat2 = to.latitude * (math.pi / 180.0);
    final lon2 = to.longitude * (math.pi / 180.0);
    final dLon = lon2 - lon1;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final radians = math.atan2(y, x);
    return (radians * 180 / math.pi + 360) % 360;
  }

  double _calculateDistanceMeters(ll.LatLng p1, ll.LatLng p2) {
    const r = 6371000.0;
    final dLat = (p2.latitude - p1.latitude) * math.pi / 180.0;
    final dLng = (p2.longitude - p1.longitude) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(p1.latitude * math.pi / 180.0) *
            math.cos(p2.latitude * math.pi / 180.0) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  // Snapping projection onto segment [a, b]
  ll.LatLng _projectPointOnSegment(ll.LatLng p, ll.LatLng a, ll.LatLng b) {
    final abX = b.longitude - a.longitude;
    final abY = b.latitude - a.latitude;
    final abLenSq = abX * abX + abY * abY;
    if (abLenSq <= 0.0) return a;
    final apX = p.longitude - a.longitude;
    final apY = p.latitude - a.latitude;
    var t = (apX * abX + apY * abY) / abLenSq;
    t = t.clamp(0.0, 1.0);
    return ll.LatLng(a.latitude + t * abY, a.longitude + t * abX);
  }

  // Find nearest snapped point and segment index on polyline (O(1) incremental window when hint valid)
  ({int segmentIndex, ll.LatLng point, double distanceMeters}) _snapToPolyline(
    ll.LatLng p,
    List<ll.LatLng> polyline, {
    int? hintSegmentIndex,
  }) {
    if (polyline.length < 2) {
      return (segmentIndex: 0, point: p, distanceMeters: 0.0);
    }

    int bestSeg = 0;
    ll.LatLng bestPoint = polyline.first;
    double minDistance = double.infinity;

    if (hintSegmentIndex != null && polyline.length > 24) {
      final int winStart = math.max(0, hintSegmentIndex - 8);
      final int winEnd = math.min(polyline.length - 2, hintSegmentIndex + 24);
      for (int i = winStart; i <= winEnd; i++) {
        final proj = _projectPointOnSegment(p, polyline[i], polyline[i + 1]);
        final dist = _calculateDistanceMeters(p, proj);
        if (dist < minDistance) {
          minDistance = dist;
          bestSeg = i;
          bestPoint = proj;
        }
      }
      if (minDistance <= 65.0) {
        return (
          segmentIndex: bestSeg,
          point: bestPoint,
          distanceMeters: minDistance,
        );
      }
    }

    for (int i = 0; i < polyline.length - 1; i++) {
      final proj = _projectPointOnSegment(p, polyline[i], polyline[i + 1]);
      final dist = _calculateDistanceMeters(p, proj);
      if (dist < minDistance) {
        minDistance = dist;
        bestSeg = i;
        bestPoint = proj;
      }
    }
    return (
      segmentIndex: bestSeg,
      point: bestPoint,
      distanceMeters: minDistance
    );
  }

  // Split polyline into traveled (subtle gray) and remaining (vibrant emerald)
  void _updatePolylineSplit(ll.LatLng vehiclePos) {
    if (_roadPolyline.length < 2) {
      _traveledPolyline = [];
      _remainingPolyline = _roadPolyline;
      _lastSnapSegmentIndex = 0;
      return;
    }
    final snap = _snapToPolyline(
      vehiclePos,
      _roadPolyline,
      hintSegmentIndex: _lastSnapSegmentIndex,
    );
    final segIdx = snap.segmentIndex;
    _lastSnapSegmentIndex = segIdx;

    final traveled = <ll.LatLng>[];
    for (int i = 0; i <= segIdx; i++) {
      traveled.add(_roadPolyline[i]);
    }
    traveled.add(vehiclePos);

    final remaining = <ll.LatLng>[vehiclePos];
    for (int i = segIdx + 1; i < _roadPolyline.length; i++) {
      remaining.add(_roadPolyline[i]);
    }

    _traveledPolyline = traveled;
    _remainingPolyline = remaining;
  }

  void _handleTechnicianLocationUpdate() {
    final state = widget.serviceState;
    if (state.technicianLat != null && state.technicianLng != null) {
      final rawPos = ll.LatLng(state.technicianLat!, state.technicianLng!);
      final doorstep = ll.LatLng(state.customerLat, state.customerLng);

      if (state.isAboutToReach) {
        unawaited(
          NotificationService().showPreArrivalAlert(
            visitId: state.bookingId,
            technicianName: state.technicianName,
            distanceMeters: state.distanceMeters,
            etaMinutes: state.etaMinutes,
          ),
        );
      }

      if (!shouldFetchLiveRoadRoute(
        isEnRoute: state.isEnRoute,
        isMapExpanded: _isMapExpanded,
      )) {
        // Minimized map or non-en-route state: skip OSRM routing & 60fps glide completely
        final movementDelta = _currentVehiclePos == null
            ? 999.0
            : _calculateDistanceMeters(_currentVehiclePos!, rawPos);
        _isStationary = movementDelta < 8.0;
        _currentVehiclePos = rawPos;
        _reschedulePollTimer(
          recommendedTrackingPollInterval(
            isEnRoute: state.isEnRoute,
            isMapExpanded: false,
            isStationary: _isStationary,
          ),
        );
        if (mounted) setState(() {});
        return;
      }

      if (_currentVehiclePos == null) {
        _currentVehiclePos = rawPos;
        _activeSubPath = [rawPos, doorstep];
        _subPathCumulativeDistances = [
          0.0,
          _calculateDistanceMeters(rawPos, doorstep)
        ];
        _fetchRoadRoute(rawPos, doorstep);
        _frameTrackingView();
        _reschedulePollTimer(
          recommendedTrackingPollInterval(
            isEnRoute: true,
            isMapExpanded: true,
            isStationary: false,
          ),
        );
        if (mounted) setState(() {});
        return;
      }

      // Movement delta check
      final movementDelta =
          _calculateDistanceMeters(_currentVehiclePos!, rawPos);
      if (movementDelta < 2.0) {
        // Micro GPS jitter suppression
        _isStationary = true;
        _reschedulePollTimer(
          recommendedTrackingPollInterval(
            isEnRoute: true,
            isMapExpanded: true,
            isStationary: true,
          ),
        );
        if (mounted) setState(() {});
        return;
      }

      _isStationary = movementDelta < 8.0;
      _reschedulePollTimer(
        recommendedTrackingPollInterval(
          isEnRoute: true,
          isMapExpanded: true,
          isStationary: _isStationary,
        ),
      );

      // Road path snapping
      ll.LatLng targetSnapped = rawPos;
      if (_roadPolyline.length >= 2) {
        final snapResult = _snapToPolyline(
          rawPos,
          _roadPolyline,
          hintSegmentIndex: _lastSnapSegmentIndex,
        );
        if (snapResult.distanceMeters <= 75.0) {
          targetSnapped = snapResult.point;
        } else {
          // Diverged > 75m from current road -> re-fetch routing
          _fetchRoadRoute(rawPos, doorstep);
        }
      } else if (_lastRouteFetchPos == null ||
          _calculateDistanceMeters(_lastRouteFetchPos!, rawPos) >= 80.0) {
        _fetchRoadRoute(rawPos, doorstep);
      }

      // Zero-Jump Continuous Handoff: Start strictly from current in-flight rendered position
      final startPos = _currentVehiclePos!;
      final subPath = <ll.LatLng>[startPos];

      if (_roadPolyline.length >= 2) {
        final startSnap = _snapToPolyline(
          startPos,
          _roadPolyline,
          hintSegmentIndex: _lastSnapSegmentIndex,
        );
        final targetSnap = _snapToPolyline(
          targetSnapped,
          _roadPolyline,
          hintSegmentIndex: startSnap.segmentIndex,
        );

        if (startSnap.segmentIndex <= targetSnap.segmentIndex) {
          for (int i = startSnap.segmentIndex + 1;
              i <= targetSnap.segmentIndex;
              i++) {
            subPath.add(_roadPolyline[i]);
          }
        }
      }
      subPath.add(targetSnapped);

      // Compute cumulative segment distances along sub-path
      final cumDist = <double>[0.0];
      for (int i = 0; i < subPath.length - 1; i++) {
        final d = _calculateDistanceMeters(subPath[i], subPath[i + 1]);
        cumDist.add(cumDist.last + d);
      }

      _activeSubPath = subPath;
      _subPathCumulativeDistances = cumDist;

      _moveController?.reset();
      _moveController?.forward();

      // Smoothly update camera frame ONCE per genuine movement update (not 60 FPS)
      _frameTrackingView();
    } else {
      _reschedulePollTimer(
        recommendedTrackingPollInterval(
          isEnRoute: state.isEnRoute,
          isMapExpanded: _isMapExpanded,
          isStationary: _isStationary,
        ),
      );
      if (state.isEnRoute && _isMapExpanded) {
        _frameTrackingView();
      }
    }
  }

  Future<void> _fetchRoadRoute(ll.LatLng start, ll.LatLng destination) async {
    if (_fetchingRoute ||
        !shouldFetchLiveRoadRoute(
          isEnRoute: widget.serviceState.isEnRoute,
          isMapExpanded: _isMapExpanded,
        )) {
      return;
    }
    _fetchingRoute = true;
    _lastRouteFetchPos = start;
    try {
      final routeRes = await RouteService().getDrivingRoute(
        start: start,
        destination: destination,
      );
      if (mounted && routeRes.points.isNotEmpty) {
        setState(() {
          _roadPolyline = routeRes.points;
          _lastSnapSegmentIndex = 0;
          _updatePolylineSplit(_currentVehiclePos ?? start);
        });
        _frameTrackingView();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _roadPolyline = [start, destination];
          _lastSnapSegmentIndex = 0;
          _updatePolylineSplit(_currentVehiclePos ?? start);
        });
      }
    } finally {
      _fetchingRoute = false;
    }
  }

  void _pauseAutoCenterForGesture() {
    _cameraController?.stop();
    _recenterCooldownTimer?.cancel();
    if (_autoCenter && mounted) {
      setState(() {
        _autoCenter = false;
      });
    } else {
      _autoCenter = false;
    }
    if (!_isUserInteractingWithMap) {
      _recenterCooldownTimer = Timer(
        kTrackingAutoRecenterPauseDuration,
        _resumeAutoCenterAfterCooldown,
      );
    }
  }

  void _resumeAutoCenterAfterCooldown() {
    if (!mounted || _isUserInteractingWithMap) return;
    if (widget.serviceState.isArrived ||
        widget.serviceState.isInService ||
        widget.serviceState.isCompleted) {
      return;
    }
    setState(() {
      _autoCenter = true;
    });
    _frameTrackingView(force: true);
  }

  void _animateCameraTo(
    ll.LatLng targetCenter,
    double targetZoom, {
    bool snap = false,
  }) {
    if (!_isMapReady) return;
    try {
      if (snap) {
        _cameraController?.stop();
        _mapController.move(targetCenter, targetZoom);
        return;
      }
      final cam = _mapController.camera;
      final centerDist = _calculateDistanceMeters(cam.center, targetCenter);
      final zoomDiff = (cam.zoom - targetZoom).abs();
      if (centerDist < 8.0 && zoomDiff < 0.04) {
        return;
      }
      _camStartCenter = cam.center;
      _camStartZoom = cam.zoom;
      _camEndCenter = targetCenter;
      _camEndZoom = targetZoom;
      _cameraController?.forward(from: 0.0);
    } catch (_) {}
  }

  void _handleMapPointerRelease(int pointer, bool isArrived) {
    _activeMapPointers.remove(pointer);
    _isUserInteractingWithMap = _activeMapPointers.isNotEmpty;
    if (!_isUserInteractingWithMap && !isArrived && !_autoCenter) {
      _recenterCooldownTimer?.cancel();
      _recenterCooldownTimer = Timer(
        kTrackingAutoRecenterPauseDuration,
        _resumeAutoCenterAfterCooldown,
      );
    }
  }

  /// Frames technician + destination + remaining route tail in a single smooth view.
  void _frameTrackingView({bool force = false, bool snap = false}) {
    if (!mounted || !_isMapReady) return;
    if (!force && (!_autoCenter || _isUserInteractingWithMap)) return;

    final state = widget.serviceState;
    final doorstep = ll.LatLng(state.customerLat, state.customerLng);
    final techPos = _currentVehiclePos ??
        (state.technicianLat != null && state.technicianLng != null
            ? ll.LatLng(state.technicianLat!, state.technicianLng!)
            : null);

    if (techPos == null) {
      _animateCameraTo(doorstep, 16.8, snap: snap);
      return;
    }

    final framePoints = buildTrackingFramePoints(
      doorstep: doorstep,
      vehiclePos: techPos,
      remainingPolyline: _remainingPolyline,
    );

    double minLat = framePoints.first.latitude;
    double maxLat = framePoints.first.latitude;
    double minLng = framePoints.first.longitude;
    double maxLng = framePoints.first.longitude;
    for (final pt in framePoints) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }

    if ((maxLat - minLat).abs() < 1e-5 && (maxLng - minLng).abs() < 1e-5) {
      _animateCameraTo(techPos, 17.2, snap: snap);
      return;
    }

    try {
      final bounds = LatLngBounds.fromPoints(framePoints);
      final fit = CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(40, 56, 40, 40),
        maxZoom: 17.0,
        minZoom: 11.5,
      );
      if (snap) {
        _cameraController?.stop();
        _mapController.fitCamera(fit);
        return;
      }
      final targetCamera = fit.fit(_mapController.camera);
      _animateCameraTo(targetCamera.center, targetCamera.zoom);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.serviceState.removeListener(_handleServiceStateChange);
    _pollTimer?.cancel();
    _recenterCooldownTimer?.cancel();
    _chatFcmSub?.cancel();
    _cameraController?.dispose();
    _moveController?.dispose();
    _pulseController?.dispose();
    _mapFrameTick.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _handleServiceStateChange() {
    if (!mounted) return;
    final state = widget.serviceState;
    if (state.isArrived ||
        state.isInService ||
        state.isCompleted ||
        state.isCancelled) {
      if (_unreadChatCount != 0) {
        setState(() => _unreadChatCount = 0);
      }
    }
    if (state.isInService || state.isCompleted || state.isCancelled) {
      _closeOpenVisitChatSheetIfNeeded(
        reason: state.isInService
            ? 'Arrival OTP verified • Technician chat session ended.'
            : 'Visit closed • Technician chat session ended.',
      );
    }
  }

  void _closeOpenVisitChatSheetIfNeeded({required String reason}) {
    final sheetCtx = _chatSheetContext;
    if (!_isChatSheetOpen || sheetCtx == null) return;
    _chatSheetContext = null;
    _isChatSheetOpen = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (sheetCtx.mounted) {
        Navigator.of(sheetCtx).maybePop();
      }
      if (mounted && !_hasShownChatEndedSnack) {
        _hasShownChatEndedSnack = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  Future<void> _makePhoneCall() async {
    final rawDigits =
        widget.serviceState.technicianPhone.replaceAll(RegExp(r'\D'), '');
    final cleanPhone = rawDigits.length >= 10
        ? rawDigits.substring(rawDigits.length - 10)
        : rawDigits;
    if (cleanPhone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Technician phone number not available')),
        );
      }
      return;
    }
    final uri = Uri(scheme: 'tel', path: cleanPhone);
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open phone dialer')),
        );
      }
    }
  }

  Future<void> _openTechnicianChat() async {
    final state = widget.serviceState;
    if (state.bookingId.trim().isEmpty ||
        state.isArrived ||
        state.isInService ||
        state.isCompleted ||
        state.isCancelled) {
      return;
    }
    if (!state.isEnRoute) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
    setState(() {
      _isChatSheetOpen = true;
      _hasShownChatEndedSnack = false;
      _unreadChatCount = 0;
    });
    await showCustomerVisitChatSheet(
      context,
      visitId: state.bookingId,
      technicianName: state.technicianName,
      technicianPhotoUrl: state.technicianPhotoUrl,
      initialLat: state.customerLat,
      initialLng: state.customerLng,
      serviceAddress: state.customerAddress,
      onSheetContextReady: (sheetCtx) => _chatSheetContext = sheetCtx,
      onChatClosedOrRead: () {
        _chatSheetContext = null;
        if (mounted) {
          setState(() => _isChatSheetOpen = false);
          if (widget.serviceState.isInService && !_hasShownChatEndedSnack) {
            _hasShownChatEndedSnack = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Arrival OTP verified • Technician chat session ended.'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          if (!widget.serviceState.isCompleted &&
              !widget.serviceState.isCancelled &&
              _pollTimer == null) {
            _reschedulePollTimer(
              recommendedTrackingPollInterval(
                isEnRoute: widget.serviceState.isEnRoute,
                isMapExpanded: _isMapExpanded,
                isStationary: _isStationary,
              ),
              force: true,
            );
          }
        }
      },
    );
  }

  void _openTechnicianReviewsSheet(ServiceTrackingState state) {
    final visitId = state.bookingId.trim();
    final techBadge = (state.technicianBadge ?? '').trim();
    if (visitId.isEmpty && techBadge.isEmpty) return;
    showTechnicianReviewsSheet(
      context,
      visitId: visitId.isNotEmpty ? visitId : null,
      technicianId: techBadge.isNotEmpty ? techBadge : null,
      technicianName: DisplaySanitizer.technicianName(
        state.technicianName,
        fallback: 'Technician',
      ),
      initialAvg: state.technicianRating,
      initialCount: state.technicianRatingCount,
      initialJobs: state.completedJobs,
    );
  }

  void _showQuickSupportSheet() {
    final bookingId = widget.serviceState.bookingId.trim();
    unawaited(
      showZoneSupportChatSheet(
        context,
        visitId: bookingId.isNotEmpty ? bookingId : null,
        issueType: 'DOORSTEP_ASSISTANCE',
        lat: widget.serviceState.customerLat,
        lng: widget.serviceState.customerLng,
        cartState: widget.cartState,
        quickPrompts: const <String>[
          'Request Reschedule / Change Visit Slot',
          'Machine diagnostics / service clarification',
          'Spares billing / factory direct pricing inquiry',
          'Upgrade to Complete Service (₹149)',
          'Urgent: Request call from Zone Manager',
        ],
      ),
    );
  }

  Widget _buildUpgradeFeatureRow(String text, bool isIncluded,
      {Widget? badge}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Icons.check_circle_rounded,
          size: 16,
          color: isIncluded ? const Color(0xFF16A34A) : const Color(0xFF0284C7),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isIncluded ? FontWeight.w700 : FontWeight.w600,
              color: isIncluded
                  ? const Color(0xFF166534)
                  : const Color(0xFF1E293B),
              height: 1.3,
            ),
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 6),
          badge,
        ],
      ],
    );
  }

  void _openQrScanner() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TechnicianQrScannerScreen(
          cartState: widget.cartState,
          serviceState: widget.serviceState,
        ),
      ),
    );
    _syncPurchasedSpares();
  }

  Widget _buildSpareItemRow(Map<String, dynamic> item) {
    final name = (item['name'] ?? item['product_name'] ?? item['recipe_name'] ?? 'Genuine RO Spare').toString();
    final qr = (item['component_qr'] ?? item['kit_qr'] ?? item['serial_qr'] ?? item['serial'] ?? item['code'] ?? '').toString().trim();
    final sku = (item['sku'] ?? '').toString().trim();
    final isKit = (item['type']?.toString().toUpperCase() == 'KIT' || item['kit_qr'] != null);
    final rawPrice = item['mrp'] ?? item['price'] ?? 0;
    final price = (rawPrice is num) ? rawPrice.toDouble() : (double.tryParse(rawPrice.toString()) ?? 0.0);
    final spec = CbmSpecHelper.resolveItemSpec(item);
    final children = CbmSpecHelper.extractChildComponents(item);
    final paidChildren = children.where(CbmSpecHelper.isCustomerVisiblePaidComponent).toList();
    final freeSpares = CbmSpecHelper.extractFreeSpares(item);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: isKit
                      ? const LinearGradient(
                          colors: [Color(0xFF1E3A8A), Color(0xFF0F172A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : const LinearGradient(
                          colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF93C5FD).withValues(alpha: 0.7),
                    width: 1.2,
                  ),
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [
                              Color(0xFFFED7AA),
                              Color(0xFFFB923C),
                              Color(0xFFEA580C),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ).createShader(bounds),
                          child: const Text(
                            'R',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              height: 0.95,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        isKit
                            ? const Icon(
                                Icons.inventory_2_rounded,
                                size: 12,
                                color: Color(0xFFFB923C),
                              )
                            : const Icon(
                                Icons.water_drop_rounded,
                                size: 12,
                                color: Color(0xFFFB923C),
                              ),
                      ],
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      isKit ? 'KIT' : 'PART',
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 5.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.25,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        if (qr.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'QR: $qr',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          )
                        else if (sku.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'SKU: $sku',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ),
                        if (spec.shortBadge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: spec.pillBackground,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(spec.icon, size: 10.5, color: spec.pillForeground),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    spec.shortBadge!,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: spec.pillForeground,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (price > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '₹${CbmSpecHelper.formatIndianInt(price.round())}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ],
          ),
          if (isKit && paidChildren.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'KIT COMPONENTS (CBM VERIFIED)',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF64748B),
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...paidChildren.map((c) {
                    final cName = (c['product_name'] ?? c['name'] ?? c['sku'] ?? 'RO Component').toString();
                    final cQr = (c['component_qr'] ?? c['qr'] ?? '').toString().trim();
                    final cSpec = CbmSpecHelper.resolveItemSpec(c);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        children: [
                          Icon(cSpec.icon, size: 11, color: cSpec.pillForeground),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              cQr.isNotEmpty ? '$cName ($cQr)' : cName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF334155),
                              ),
                            ),
                          ),
                          if (cSpec.shortBadge != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              cSpec.shortBadge!,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: cSpec.pillForeground,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
          if (isKit && freeSpares.isNotEmpty)
            SealedFreeSparesBox(freeSpares: freeSpares),
        ],
      ),
    );
  }

  Widget _buildSummaryAmountRow(
    String label,
    String value, {
    Color valueColor = const Color(0xFF0F172A),
    bool isBold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: isBold ? 12.5 : 11.5,
                fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
                color: isBold ? const Color(0xFF0F172A) : const Color(0xFF475569),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: isBold ? 13.5 : 11.5,
              fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchasedSparesCard({bool allowScanMore = true}) {
    final allItems = CbmSpecHelper.extractPurchasedItems(_purchasedSpares);
    final summary = CbmSpecHelper.summarizePurchases(_purchasedSpares);

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF86EFAC), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C16A34A),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.verified_rounded, size: 20, color: Color(0xFF16A34A)),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Genuine Spares Purchased (This Visit)',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 1),
                    Text(
                      'Doorstep Visit • Custody Verified',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF16A34A),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFBBF7D0)),
                ),
                child: Text(
                  'PAID ₹${CbmSpecHelper.formatIndianInt(summary.sparesPaidTotal.round())}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF15803D),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (allItems.isNotEmpty) ...allItems.map(_buildSpareItemRow),
          if (summary.discountAmount > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: _buildSummaryAmountRow(
                'Coupon Savings${summary.couponCodes.isNotEmpty ? ' (${summary.couponCodes.join(', ')})' : ''}',
                '-₹${CbmSpecHelper.formatIndianInt(summary.discountAmount.round())}',
                valueColor: const Color(0xFF15803D),
              ),
            ),
          ],
          if (allowScanMore) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0284C7),
                  side: const BorderSide(color: Color(0xFFBAE6FD)),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                ),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text(
                  'Scan Another Spare / Kit Box',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5),
                ),
                onPressed: _openQrScanner,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompletedSummaryCard(ServiceTrackingState state) {
    final allItems = CbmSpecHelper.extractPurchasedItems(_purchasedSpares);
    final summary = CbmSpecHelper.summarizePurchases(_purchasedSpares);
    final combinedValue = state.finalPayableAmount + summary.sparesPaidTotal;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF86EFAC), width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D0F172A),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded, size: 13, color: Color(0xFF16A34A)),
                      SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          'SERVICE COMPLETED',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF15803D),
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            state.serviceTitle,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Serviced by ${DisplaySanitizer.technicianName(state.technicianName)}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          TechnicianRatingBadgeRow(
            rating: state.technicianRating,
            ratingCount: state.technicianRatingCount,
            completedJobs: state.completedJobs,
            showViewReviewsHint: true,
            onTap: () => _openTechnicianReviewsSheet(state),
          ),
          const SizedBox(height: 14),

          // Service Charge Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'DOORSTEP SERVICE CHARGE',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF166534),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      state.finalPayableText,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF15803D),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1.5),
                      child: Icon(Icons.payments_outlined, size: 13.5, color: Color(0xFF15803D)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        state.finalPayableAmount == 0
                            ? 'Happy Hour offer applied — doorstep inspection is 100% Free.'
                            : 'Pay ${state.finalPayableText} via Cash or UPI directly to ${state.technicianName}.',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF166534),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Purchase Summary Header (Scoped to this Visit # only)
          Row(
            children: [
              const Expanded(
                child: Text(
                  'PURCHASE SUMMARY',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: allItems.isNotEmpty || summary.ordersCount > 0
                      ? const Color(0xFFDCFCE7)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  allItems.isNotEmpty || summary.ordersCount > 0
                      ? 'PAID ONLINE ₹${CbmSpecHelper.formatIndianInt(summary.sparesPaidTotal.round())}'
                      : 'NO SPARES BILLED',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: allItems.isNotEmpty || summary.ordersCount > 0
                        ? const Color(0xFF15803D)
                        : const Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (allItems.isNotEmpty) ...[
            ...allItems.map(_buildSpareItemRow),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryAmountRow(
                    'Spares MRP (${summary.itemsCount} ${summary.itemsCount == 1 ? 'item' : 'items'})',
                    '₹${CbmSpecHelper.formatIndianInt(summary.baseMrpTotal.round())}',
                  ),
                  if (summary.discountAmount > 0)
                    _buildSummaryAmountRow(
                      'Discount${summary.couponCodes.isNotEmpty ? ' (${summary.couponCodes.join(', ')})' : ''}',
                      '-₹${CbmSpecHelper.formatIndianInt(summary.discountAmount.round())}',
                      valueColor: const Color(0xFF16A34A),
                    ),
                  const Divider(height: 14, color: Color(0xFFE2E8F0)),
                  _buildSummaryAmountRow(
                    'Spares Paid Online (App)',
                    '₹${CbmSpecHelper.formatIndianInt(summary.sparesPaidTotal.round())}',
                    isBold: true,
                  ),
                  if (summary.orderNumbers.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Order Ref: ${summary.orderNumbers.join(' • ')}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Combined Visit Total',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'Service ${state.finalPayableText} + Spares ₹${CbmSpecHelper.formatIndianInt(summary.sparesPaidTotal.round())}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '₹${CbmSpecHelper.formatIndianInt(combinedValue.round())}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
            ),
          ] else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.receipt_long_outlined, size: 16, color: Color(0xFF64748B)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No spares or kits were purchased during this service.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          TechnicianRateCard(
            key: ValueKey('rate_card_${state.bookingId}'),
            technicianName: DisplaySanitizer.technicianName(state.technicianName),
            technicianBadge: state.technicianBadge,
            initialCustomerRating: state.customerRating,
            initialCustomerReview: state.customerReview,
            onSubmit: state.submitVisitRating,
            onViewReviews: () => _openTechnicianReviewsSheet(state),
          ),
        ],
      ),
    );
  }

  void _openKnowAboutRoSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => KnowAboutRoSheet(onExploreSpares: () => Navigator.pop(context)),
    );
  }

  void _showUpgradeConfirmationDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        title: const Row(
          children: [
            Icon(Icons.upgrade_rounded, color: Color(0xFF0284C7), size: 28),
            SizedBox(width: 8),
            Text(
              'Upgrade Service?',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  color: Color(0xFF0F172A)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Are you sure you want to upgrade your booking to Full Comprehensive Service?',
              style: TextStyle(
                  fontSize: 13, color: Color(0xFF334155), height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Full Service Charge:',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF166534)),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '₹149',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF15803D)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '• Complete internal leakage & pipe fixing\n• High-pressure booster pump calibration\n• Electrical SMPS & solenoid valve audit',
              style: TextStyle(
                  fontSize: 11.5, color: Color(0xFF64748B), height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(
                    color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await widget.serviceState.upgradeToFullService();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok
                        ? '🎉 Upgraded to Full Service for ₹149!'
                        : 'Service upgraded locally (₹149)'),
                    backgroundColor: const Color(0xFF16A34A),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('Yes, Upgrade to ₹149',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  String _cleanAddress(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    String addr = raw.trim();
    // 1. Remove duplicate trailing city & pincode variations like ", Bengaluru (560100)" when already present
    addr = addr.replaceAll(
        RegExp(r',\s*Bengaluru\s*\(\d{5,6}\)$', caseSensitive: false), '');
    addr = addr.replaceAll(
        RegExp(r',\s*Bangalore\s*\(\d{5,6}\)$', caseSensitive: false), '');
    // 2. Remove duplicate city names like "Bengaluru, Bengaluru" or "Bangalore, Bangalore"
    addr = addr.replaceAll(
        RegExp(r'\bBengaluru,\s*Bengaluru\b', caseSensitive: false),
        'Bengaluru');
    addr = addr.replaceAll(
        RegExp(r'\bBangalore,\s*Bangalore\b', caseSensitive: false),
        'Bangalore');
    // 3. Clean any consecutive double commas or trailing commas
    addr = addr.replaceAll(RegExp(r',\s*,'), ',');
    addr = addr.trim().replaceAll(RegExp(r'^,\s*|,\s*$'), '');
    return addr;
  }

  Widget _buildBlinkitHeroStatus(ServiceTrackingState state) {
    final isArrived = state.isArrivedOrConfirmingOtp;
    final isEnRoute = state.isEnRoute;
    final isCompleted = state.isCompleted;
    final isCancelled = state.isCancelled;
    final isConfirmed = state.isOrderConfirmed;
    final isScheduled = state.isScheduledNextDay;
    final isInService = state.isInService;

    String headline;
    String subtitle;
    String pillText;
    Color pillColor;
    Color pillTextColor;
    IconData heroIcon;

    if (isCancelled) {
      headline = 'Service Cancelled';
      final reason = state.cancelReason?.trim();
      subtitle = reason != null && reason.isNotEmpty
          ? 'Reason: $reason. You can book a fresh visit anytime.'
          : 'This visit was cancelled by hub support. You can book a fresh visit anytime.';
      pillText = 'CANCELLED';
      pillColor = const Color(0xFFFEE2E2);
      pillTextColor = const Color(0xFFDC2626);
      heroIcon = Icons.cancel_outlined;
    } else if (isCompleted) {
      headline = 'Service Completed';
      subtitle = 'Inspection & service completed by ${state.technicianName}.';
      pillText = 'DONE';
      pillColor = const Color(0xFFDCFCE7);
      pillTextColor = const Color(0xFF16A34A);
      heroIcon = Icons.task_alt_rounded;
    } else if (isInService) {
      headline = 'Service in Progress';
      subtitle =
          '${state.technicianName} is performing machine checkup and TDS diagnostics.';
      pillText = '⚡ ACTIVE';
      pillColor = const Color(0xFFF3E8FF);
      pillTextColor = const Color(0xFF9333EA);
      heroIcon = Icons.handyman_rounded;
    } else if (isArrived) {
      headline = state.isLocationMismatchArrival
          ? 'Technician Arrived • Share OTP'
          : 'Arrived at Doorstep';
      subtitle = state.isLocationMismatchArrival
          ? 'Technician pressed I Have Arrived at your location. Share the 3-digit OTP below to confirm & start service.'
          : 'Technician has reached your doorstep! Share the 3-digit OTP below.';
      pillText = state.isLocationMismatchArrival ? 'CONFIRM OTP' : 'AT DOORSTEP';
      pillColor = const Color(0xFFDCFCE7);
      pillTextColor = const Color(0xFF15803D);
      heroIcon = Icons.home_rounded;
    } else if (isEnRoute) {
      headline = 'Arriving in ${state.etaMinutes} mins';
      subtitle =
          '${state.technicianName} is navigating to your doorstep with sealed parts.';
      pillText = '⚡ LIVE GPS';
      pillColor = const Color(0xFFE0F2FE);
      pillTextColor = const Color(0xFF0284C7);
      heroIcon = Icons.electric_moped_rounded;
    } else if (isConfirmed) {
      headline = 'Technician Assigned';
      subtitle = '';
      pillText = 'ASSIGNED';
      pillColor = const Color(0xFFDCFCE7);
      pillTextColor = const Color(0xFF16A34A);
      heroIcon = Icons.person_pin_circle_rounded;
    } else if (isScheduled) {
      headline = 'Slot Booked';
      subtitle =
          'Doorstep service appointment reserved with certified technician.';
      pillText = 'SCHEDULED';
      pillColor = const Color(0xFFFEF3C7);
      pillTextColor = const Color(0xFFB45309);
      heroIcon = Icons.calendar_month_rounded;
    } else {
      headline = 'Service Slot Booked';
      subtitle =
          'Doorstep service appointment reserved with certified technician.';
      pillText = 'SLOT BOOKED';
      pillColor = const Color(0xFFF0FDF4);
      pillTextColor = const Color(0xFF16A34A);
      heroIcon = Icons.event_available_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F766E).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(heroIcon,
                          color: const Color(0xFF0F766E), size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              headline,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          if (state.isFreeRevisit || state.isFreeVisit) ...[
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFFFDE68A)),
                              ),
                              child: Text(
                                state.isFreeRevisit ? '↻ FREE REVISIT • ₹0' : '★ FREE VISIT • ₹0',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFB45309),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: pillColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEnRoute || isArrived || isInService) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: pillTextColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      pillText,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: pillTextColor,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF475569), height: 1.35),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBlinkitProgressStepper(ServiceTrackingState state) {
    int activeStage = 0;
    if (state.isCompleted || state.isInService || state.isArrivedOrConfirmingOtp) {
      activeStage = 3;
    } else if (state.isEnRoute) {
      activeStage = 2;
    } else if (state.isOrderConfirmed) {
      activeStage = 1;
    } else {
      activeStage = 0;
    }

    final steps = [
      {'title': 'Confirmed', 'icon': Icons.receipt_long_rounded},
      {'title': 'Assigned', 'icon': Icons.person_rounded},
      {'title': 'On The Way', 'icon': Icons.two_wheeler_rounded},
      {'title': 'At Doorstep', 'icon': Icons.home_rounded},
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Flexible(
                child: Text(
                  'LIVE SERVICE JOURNEY',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                    color: Color(0xFF0F766E),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Step ${activeStage + 1} of 4',
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF64748B)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: List.generate(steps.length * 2 - 1, (i) {
              if (i.isOdd) {
                final lineIndex = i ~/ 2;
                final isDone = activeStage > lineIndex;
                return Expanded(
                  child: Container(
                    height: 3,
                    color: isDone
                        ? const Color(0xFF0F766E)
                        : const Color(0xFFE2E8F0),
                  ),
                );
              }
              final stepIndex = i ~/ 2;
              final isDone = activeStage > stepIndex;
              final isCurrent = activeStage == stepIndex;

              final Color nodeBg = isDone
                  ? const Color(0xFF0F766E)
                  : (isCurrent
                      ? const Color(0xFF0F766E)
                      : const Color(0xFFF1F5F9));
              final Color nodeColor = (isDone || isCurrent)
                  ? Colors.white
                  : const Color(0xFF94A3B8);

              return SizedBox(
                width: 62,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: nodeBg,
                        shape: BoxShape.circle,
                        border: isCurrent
                            ? Border.all(
                                color: const Color(0xFF99F6E4), width: 3)
                            : null,
                      ),
                      child: Icon(
                        isDone
                            ? Icons.check_rounded
                            : (steps[stepIndex]['icon'] as IconData),
                        color: nodeColor,
                        size: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        steps[stepIndex]['title'] as String,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: (isDone || isCurrent)
                              ? FontWeight.bold
                              : FontWeight.w500,
                          color: (isDone || isCurrent)
                              ? const Color(0xFF0F172A)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBlinkitDoorstepMap(ServiceTrackingState state) {
    final isArrived = state.isArrivedOrConfirmingOtp;
    final isWaiting = state.isWaitingForAcceptance;
    final doorstepPos = ll.LatLng(state.customerLat, state.customerLng);

    final markers = <Marker>[
      // Customer Doorstep Pin
      Marker(
        point: doorstepPos,
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33EF4444),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.home_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    ];

    final vehiclePos = _currentVehiclePos ??
        (state.technicianLat != null && state.technicianLng != null
            ? ll.LatLng(state.technicianLat!, state.technicianLng!)
            : null);

    Widget buildVehicleMarkerChild() {
      if (isArrived) {
        return Center(
          child: Transform.rotate(
            angle: _vehicleBearing * (math.pi / 180),
            child: Image.asset(
              'assets/images/roparts_bike_transparent.png',
              width: 76,
              height: 76,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Color(0xFF0F766E),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.two_wheeler_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        );
      }

      final v1 = _pulseController?.value ?? 0.0;
      final v2 = (v1 + 0.5) % 1.0;
      return Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 82 * v2,
            height: 82 * v2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0F766E).withValues(
                alpha: ((1.0 - v2) * 0.20).clamp(0.0, 1.0),
              ),
            ),
          ),
          Container(
            width: 72 * v1,
            height: 72 * v1,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0F766E).withValues(
                alpha: ((1.0 - v1) * 0.35).clamp(0.0, 1.0),
              ),
            ),
          ),
          Transform.rotate(
            angle: _vehicleBearing * (math.pi / 180),
            child: Image.asset(
              'assets/images/roparts_bike_transparent.png',
              width: 76,
              height: 76,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Color(0xFF0F766E),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.two_wheeler_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      height: 260,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                _activeMapPointers.add(event.pointer);
                _isUserInteractingWithMap = true;
                if (!isArrived) {
                  _pauseAutoCenterForGesture();
                }
              },
              onPointerUp: (event) =>
                  _handleMapPointerRelease(event.pointer, isArrived),
              onPointerCancel: (event) =>
                  _handleMapPointerRelease(event.pointer, isArrived),
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: vehiclePos ?? doorstepPos,
                  initialZoom:
                      isArrived ? 17.5 : (vehiclePos != null ? 15.2 : 17.2),
                  // When arrived: freeze map completely into a still image (zero drag, zero zoom, zero GPU overhead)
                  interactionOptions: InteractionOptions(
                    flags: isArrived
                        ? InteractiveFlag.none
                        : (InteractiveFlag.all & ~InteractiveFlag.rotate),
                  ),
                  onPositionChanged: (position, hasGesture) {
                    if (hasGesture && !isArrived) {
                      _pauseAutoCenterForGesture();
                    }
                  },
                  onMapReady: () {
                    _isMapReady = true;
                    _frameTrackingView(force: true, snap: true);
                  },
                ),
              children: [
                TileLayer(
                  urlTemplate: ApiService.cartoTileUrl,
                  userAgentPackageName: 'in.roparts.roparts',
                  maxZoom: 20,
                ),
                AnimatedBuilder(
                  animation: Listenable.merge([
                    _pulseController ?? const AlwaysStoppedAnimation<double>(0.0),
                    _mapFrameTick,
                  ]),
                  builder: (context, _) {
                    final liveVehiclePos = _currentVehiclePos ??
                        (state.technicianLat != null && state.technicianLng != null
                            ? ll.LatLng(state.technicianLat!, state.technicianLng!)
                            : null);
                    final dynamicMarkers = <Marker>[
                      ...markers,
                      if (liveVehiclePos != null &&
                          !isWaiting &&
                          !state.isScheduledNextDay)
                        Marker(
                          point: liveVehiclePos,
                          width: 82,
                          height: 82,
                          child: buildVehicleMarkerChild(),
                        ),
                    ];

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_traveledPolyline.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _traveledPolyline,
                                strokeWidth: 3.5,
                                color: const Color(0xFF94A3B8)
                                    .withValues(alpha: 0.65),
                              ),
                            ],
                          ),
                        if (_remainingPolyline.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _remainingPolyline,
                                strokeWidth: 7.0,
                                color: const Color(0xFF14B8A6).withValues(
                                  alpha: isArrived
                                      ? 0.4
                                      : (0.25 +
                                              (_pulseController?.value ?? 0.0) *
                                                  0.35)
                                          .clamp(0.0, 1.0),
                                ),
                                strokeCap: StrokeCap.round,
                                strokeJoin: StrokeJoin.round,
                              ),
                              Polyline(
                                points: _remainingPolyline,
                                strokeWidth: 4.5,
                                color: const Color(0xFF0F766E),
                                borderColor: const Color(0xFF5EEAD4),
                                borderStrokeWidth: 1.0,
                                strokeCap: StrokeCap.round,
                                strokeJoin: StrokeJoin.round,
                              ),
                            ],
                          )
                        else if (_roadPolyline.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _roadPolyline,
                                strokeWidth: 4.5,
                                color: const Color(0xFF0F766E),
                                borderColor: const Color(0xFF14B8A6),
                                borderStrokeWidth: 1.5,
                                strokeCap: StrokeCap.round,
                                strokeJoin: StrokeJoin.round,
                              ),
                            ],
                          ),
                        MarkerLayer(markers: dynamicMarkers),
                      ],
                    );
                  },
                ),
              ],
            ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0x55CBD5E1)),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.65,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isArrived
                              ? const Color(0xFF16A34A)
                              : (state.isEnRoute
                                  ? const Color(0xFF0284C7)
                                  : const Color(0xFFD97706)),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          isArrived
                              ? (state.isLocationMismatchArrival
                                  ? 'Technician arrived • Share OTP to confirm'
                                  : 'Technician at location')
                              : (state.isEnRoute
                                  ? 'Live'
                                  : (isWaiting
                                      ? 'Radar: 3 km radius active'
                                      : 'Partner Assigned')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!isArrived)
              Positioned(
                top: 12,
                right: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      key: const Key('minimize_map_btn'),
                      onTap: _minimizeLiveMap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.close_fullscreen_rounded,
                              size: 13,
                              color: Color(0xFF0F172A),
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Minimize',
                              style: TextStyle(
                                color: Color(0xFF0F172A),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        _recenterCooldownTimer?.cancel();
                        _isUserInteractingWithMap = false;
                        setState(() {
                          _autoCenter = true;
                        });
                        _frameTrackingView(force: true);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: _autoCenter
                              ? const Color(0xFFF0FDF4)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: _autoCenter
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFCBD5E1)),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x0F000000),
                                blurRadius: 4,
                                offset: Offset(0, 2)),
                          ],
                        ),
                        child: Icon(
                          Icons.my_location_rounded,
                          size: 16,
                          color: _autoCenter
                              ? const Color(0xFF16A34A)
                              : const Color(0xFF0F766E),
                        ),
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

  Widget _buildTrackingMediaOrMap(ServiceTrackingState state) {
    final canExpandMap = shouldShowLiveMapPreview(isEnRoute: state.isEnRoute);
    if (canExpandMap && _isMapExpanded) {
      return _buildBlinkitDoorstepMap(state);
    }
    return _buildMinimizedHeroBanner(
      state,
      showViewMapThumb: canExpandMap,
    );
  }

  Widget _buildMinimizedHeroBanner(
    ServiceTrackingState state, {
    required bool showViewMapThumb,
  }) {
    final eta = state.etaMinutes;
    final etaUnit = eta == 1 ? 'min' : 'mins';
    final distMeters = state.distanceMeters;
    final techName = state.technicianName.trim().isNotEmpty
        ? state.technicianName.trim()
        : 'Your technician';
    final etaSubtitle = (distMeters != null && distMeters > 0)
        ? '$techName is ~${distMeters >= 1000 ? '${(distMeters / 1000).toStringAsFixed(1)} km' : '${distMeters.round()}m'} away'
        : '$techName is on the way with sealed parts';

    return Container(
      key: const Key('minimized_eta_card'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF0FDFA)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFCCFBF1), width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D0F172A),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCCFBF1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF0F766E),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          state.isAboutToReach ? 'ABOUT TO REACH' : 'ON THE WAY',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF0F766E),
                            fontSize: 9.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    state.isLocationMismatchArrival
                        ? 'Confirm Arrival • Share OTP'
                        : 'Arriving in $eta $etaUnit',
                    maxLines: 1,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  etaSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (showViewMapThumb) ...[
            const SizedBox(width: 12),
            GestureDetector(
              key: const Key('view_map_thumbnail_btn'),
              onTap: _expandLiveMap,
              child: Container(
                width: 126,
                height: 82,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x240F172A),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _MiniMapPreviewPainter(),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 5),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Text(
                            'VIEW MAP',
                            style: TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleMutualCancelDecision(
    ServiceTrackingState state,
    String decision,
  ) async {
    if (_isRespondingMutualCancel) return;
    setState(() => _isRespondingMutualCancel = true);
    final res = await state.respondToMutualCancel(
      decision: decision,
      reason: decision == 'REJECT'
          ? 'Customer declined mutual cancellation and requested service'
          : null,
    );
    if (!mounted) return;
    setState(() => _isRespondingMutualCancel = false);
    final ok = res['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res['message']?.toString() ??
              (ok
                  ? (decision == 'APPROVE'
                      ? 'Mutual cancellation approved.'
                      : 'Mutual cancellation declined. Service continues.')
                  : 'Failed to submit your decision.'),
        ),
        backgroundColor: ok
            ? (decision == 'APPROVE'
                ? const Color(0xFF334155)
                : const Color(0xFF0F766E))
            : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (ok) {
      unawaited(_syncActiveVisit());
    }
  }

  Widget _buildMutualCancelRequestCard(ServiceTrackingState state) {
    final code = state.mutualCancelCode ?? '---';
    final reason = state.mutualCancelReason?.trim() ?? 'Mutual cancellation proposed by technician';
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF59E0B), width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14F59E0B),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.handshake_outlined,
                  color: Color(0xFFB45309),
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mutual Cancellation Request',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF92400E),
                      ),
                    ),
                    Text(
                      'Technician asked to cancel by agreement',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    const Text(
                      'CODE',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    Text(
                      code,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 3,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Text(
              'Reason: $reason\nTap Approve below to cancel immediately without charges (or share code $code with technician). Tap Decline to continue service.',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF78350F),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0F766E),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF0F766E), width: 1.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  onPressed: _isRespondingMutualCancel
                      ? null
                      : () => _handleMutualCancelDecision(state, 'REJECT'),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Decline / Keep Service',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  onPressed: _isRespondingMutualCancel
                      ? null
                      : () => _handleMutualCancelDecision(state, 'APPROVE'),
                  child: _isRespondingMutualCancel
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Approve Mutual Cancel',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSlotDetailsCard(ServiceTrackingState state) {
    final cleanAddr = _cleanAddress(state.customerAddress);
    final isAssigned = state.rawStatus == 'ASSIGNED' ||
        state.rawStatus == 'ACCEPTED_CALLING_CUSTOMER';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on_rounded,
                  size: 16, color: Color(0xFF0284C7)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cleanAddr,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 16, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isAssigned
                        ? '${state.technicianName} will call you before arrival. Live tracking activates once they start travelling.'
                        : 'Live tracking will activate automatically as soon as your technician starts travelling.',
                    style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF166534),
                        height: 1.3,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.serviceState,
      builder: (context, _) {
        final state = widget.serviceState;
        final isArrived = state.isArrivedOrConfirmingOtp;
        final isCompleted = state.isCompleted;
        final isCancelled = state.isCancelled;
        final isInService = state.isInService;
        final isEnRoute = state.isEnRoute;
        // Strictly unlocked ONLY during active service (hidden after Completed)
        final canShowActiveServiceActions = isInService;

        // Dynamic Title based on Live Service Lifecycle
        String appBarTitle = 'Technician Live Tracking';
        if (isCancelled) {
          appBarTitle = 'Booking Cancelled';
        } else if (isCompleted) {
          appBarTitle = 'Service Completed';
        } else if (isInService) {
          appBarTitle = 'Service in Progress';
        } else if (isArrived) {
          appBarTitle = state.isLocationMismatchArrival
              ? 'Technician Arrived'
              : 'Technician at Doorstep';
        } else if (isEnRoute) {
          appBarTitle = 'Technician on the Way';
        } else if (state.isBooked) {
          appBarTitle = (state.hasTechnicianAssigned || state.isOrderConfirmed)
              ? 'Technician Assigned'
              : 'Service Scheduled';
        }

        // Dynamic Badge in Top Right (Zero fake ETA during active service)
        String badgeText = '${state.etaMinutes} MINS ETA';
        Color badgeBg = const Color(0xFFE0F2FE);
        Color badgeFg = const Color(0xFF0284C7);

        if (isCancelled) {
          badgeText = 'CANCELLED';
          badgeBg = const Color(0xFFFEE2E2);
          badgeFg = const Color(0xFFDC2626);
        } else if (isCompleted) {
          badgeText = 'COMPLETED';
          badgeBg = const Color(0xFFDCFCE7);
          badgeFg = const Color(0xFF15803D);
        } else if (isInService) {
          badgeText = 'ACTIVE';
          badgeBg = const Color(0xFFDCFCE7);
          badgeFg = const Color(0xFF15803D);
        } else if (isArrived) {
          badgeText =
              state.isLocationMismatchArrival ? 'CONFIRM OTP' : 'AT DOORSTEP';
          badgeBg = const Color(0xFFFEF3C7);
          badgeFg = const Color(0xFFB45309);
        } else if (state.isBooked) {
          if (state.hasTechnicianAssigned || state.isOrderConfirmed) {
            badgeText = 'ASSIGNED';
            badgeBg = const Color(0xFFDCFCE7);
            badgeFg = const Color(0xFF16A34A);
          } else if (state.isScheduledNextDay) {
            badgeText = 'SCHEDULED';
            badgeBg = const Color(0xFFFEF3C7);
            badgeFg = const Color(0xFFB45309);
          } else {
            badgeText = 'ASSIGNING';
            badgeBg = const Color(0xFFF1F5F9);
            badgeFg = const Color(0xFF475569);
          }
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC), // Clean Light Theme
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded,
                  color: Color(0xFF0F172A)),
              onPressed: () => Navigator.pop(context),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appBarTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  _cleanAddress(state.customerAddress),
                  style:
                      const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              if (WebAppDownloadConfig.isWeb && !isCompleted && !isCancelled)
                IconButton(
                  key: const Key('web_tracking_refresh_btn'),
                  tooltip: 'Refresh Live Location & OTP',
                  icon: const Icon(Icons.refresh_rounded, color: Color(0xFF0284C7), size: 20),
                  onPressed: _syncActiveVisit,
                ),
              if (state.isFreeRevisit || state.isFreeVisit)
                Container(
                  margin: const EdgeInsets.only(right: 6, top: 12, bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Center(
                    child: Text(
                      state.isFreeRevisit ? 'REVISIT' : 'FREE VISIT',
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ),
                ),
              Container(
                margin: const EdgeInsets.only(right: 14, top: 12, bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: badgeFg,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              if (state.hasMutualCancelRequest && !isCancelled && !isCompleted) ...[
                _buildMutualCancelRequestCard(state),
              ],
              if (isCancelled) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Color(0x0C000000), blurRadius: 10, offset: Offset(0, 3)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'VISIT CANCELLED',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFFDC2626)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Your service booking has been cancelled.',
                        style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        (state.cancelReason?.trim().isNotEmpty ?? false)
                            ? 'Reason: ${state.cancelReason!.trim()}'
                            : 'This order was closed by Hub Operations Support. You can schedule a new visit anytime.',
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569), height: 1.35),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            widget.serviceState.resetToIdle();
                            if (Navigator.of(context).canPop()) {
                              Navigator.of(context).pop();
                            }
                          },
                          icon: const Icon(Icons.calendar_today_rounded, size: 16),
                          label: const Text('Dismiss & Book Fresh Slot', style: TextStyle(fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (!isCancelled &&
                  !isCompleted &&
                  (state.rescheduleReason?.trim().isNotEmpty ?? false)) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_repeat_rounded, size: 18, color: Color(0xFF0284C7)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Appointment Updated: ${state.preferredTimeSlot ?? state.scheduledWindow} (${state.rescheduleReason!.trim()})',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E3A8A)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // STEP 5: FINAL PURCHASE & SETTLEMENT SUMMARY CARD (When Job Completed)
              if (isCompleted) ...[
                _buildCompletedSummaryCard(state),
              ],
              // ==========================================
              // LIVE JOURNEY TRACKING (Only active before service starts)
              // ==========================================
              if (!isCompleted && !isInService && !isCancelled) ...[
                // 1. Blinkit-Style Hero Status with Live ETA Pill
                _buildBlinkitHeroStatus(state),

                // 2. 4-Stage Horizontal Journey Stepper (Confirmed -> Assigned -> On Way -> Arrived)
                _buildBlinkitProgressStepper(state),

                // 3. Minimized "Arriving in X mins" + VIEW MAP thumbnail ONLY when en route;
                //    when ARRIVED (at doorstep), hide banners/maps so Doorstep OTP sits up front.
                if (state.isEnRoute)
                  _buildTrackingMediaOrMap(state)
                else if (!state.isArrived)
                  _buildSlotDetailsCard(state),

                const SizedBox(height: 14),
              ],

              // 2. Doorstep Arrival OTP Box (Shown at <= 500m pre-arrival, technician request, or ARRIVED)
              if (state.shouldShowOtp && state.arrivalOtp != null) ...[
                Container(
                  key: const Key('doorstep_arrival_otp_card'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7), // Light Warm Amber Box
                    borderRadius: BorderRadius.circular(18),
                    border:
                        Border.all(color: const Color(0xFFFCD34D), width: 1.5),
                  ),
                  child: Column(
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.key_rounded,
                              color: Color(0xFFB45309), size: 18),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'DOORSTEP ARRIVAL OTP',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF92400E),
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: state.arrivalOtp!.split('').map((digit) {
                          return Container(
                            width: 38,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: const Color(0xFFF59E0B), width: 2),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x14000000),
                                  blurRadius: 4,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              digit,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF92400E),
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        state.isLocationMismatchArrival
                            ? '${state.technicianName} pressed I Have Arrived at your location. Share this 3-digit OTP to confirm arrival & start service.'
                            : (state.isEnRoute
                                ? '${state.technicianName} is about to reach (~${state.etaMinutes} mins away). Keep this 3-digit OTP ready for doorstep verification.'
                                : 'Share this 3-digit OTP with ${state.technicianName} at your doorstep to start service.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF78350F),
                            fontWeight: FontWeight.w600),
                      ),
                      if (isArrived) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF0F766E),
                              side: const BorderSide(color: Color(0xFF99F6E4)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text(
                                'Refresh Verification Status',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 12)),
                            onPressed: _syncActiveVisit,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ] else if (isArrived) ...[
                Container(
                  key: const Key('retrieve_arrival_otp_card'),
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.key_rounded,
                          color: Color(0xFFB45309), size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Technician is at your doorstep. Tap to retrieve your 3-digit OTP.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF78350F),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _syncActiveVisit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFB45309),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text(
                          'Retrieve OTP',
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 1. Current Service Plan Summary & Upgrade (Strictly unlocked AFTER Doorstep OTP confirmation)
              if (canShowActiveServiceActions && WebAppDownloadConfig.isWeb) ...[
                WebAppDownloadGateCard(
                  key: const Key('web_in_service_download_gate'),
                  badge: 'APP EXCLUSIVE • UP TO 80% OFF',
                  title: 'Download ROParts App to Continue',
                  subtitle:
                      'Scan genuine RO spare QRs, unlock digital warranty & get up to 80% off on your app order.',
                  bullets: const [
                    'Instant QR & hologram authenticity verification',
                    'Up to 80% off on genuine spares & kits on app',
                    'One-tap UPI checkout & digital GST warranty vault',
                  ],
                  onDownloadTap: () => WebAppDownloadConfig.launchAppDownload(context),
                ),
                const SizedBox(height: 14),
              ] else if (canShowActiveServiceActions) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: state.isUpgraded
                          ? const Color(0xFF86EFAC)
                          : const Color(0xFFE2E8F0),
                      width: state.isUpgraded ? 1.5 : 1.0,
                    ),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x06000000),
                          blurRadius: 10,
                          offset: Offset(0, 3)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() {
                            _isServiceCardExpanded = !_isServiceCardExpanded;
                          });
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    state.isUpgraded
                                        ? 'Full RO Service & Comprehensive Repair'
                                        : 'Quick RO Visit & Inspection',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A),
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    state.isUpgraded
                                        ? 'Comprehensive service • 30-Day Service Guarantee'
                                        : 'Complimentary Tank Cleaning',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      '₹${state.fee}',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        color: state.isUpgraded
                                            ? const Color(0xFF16A34A)
                                            : const Color(0xFF0284C7),
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                    if (!state.isUpgraded &&
                                        !_isServiceCardExpanded)
                                      const Text(
                                        'Upgrade',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0284C7),
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(width: 14),
                                AnimatedRotation(
                                  turns: _isServiceCardExpanded ? 0.5 : 0.0,
                                  duration: const Duration(milliseconds: 380),
                                  curve: Curves.easeInOutCubic,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: _isServiceCardExpanded
                                          ? const Color(0xFFE0F2FE)
                                          : const Color(0xFFF1F5F9),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _isServiceCardExpanded
                                            ? const Color(0xFFBAE6FD)
                                            : const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 16,
                                      color: _isServiceCardExpanded
                                          ? const Color(0xFF0284C7)
                                          : const Color(0xFF64748B),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 480),
                        reverseDuration: const Duration(milliseconds: 360),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.topCenter,
                        child: _isServiceCardExpanded
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 12),

                                  // Value Feature Breakdown
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: state.isUpgraded
                                          ? const Color(0xFFF0FDF4)
                                          : const Color(0xFFF0F9FF)
                                              .withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: state.isUpgraded
                                            ? const Color(0xFFBBF7D0)
                                            : const Color(0xFFBAE6FD),
                                        width: 1.0,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (!state.isUpgraded) ...[
                                          const Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Icon(Icons.check_circle,
                                                  size: 16,
                                                  color: Color(0xFF16A34A)),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Technician doorstep visit and RO inspection.',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 7),
                                          const Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Icon(Icons.check_circle,
                                                  size: 16,
                                                  color: Color(0xFF16A34A)),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Purifier health & performance check.',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 7),
                                          const Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Icon(Icons.check_circle,
                                                  size: 16,
                                                  color: Color(0xFF16A34A)),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Pre-filter replacement included.',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 7),
                                          const Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Icon(Icons.cancel,
                                                  size: 16,
                                                  color: Color(0xFFEF4444)),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Full purifier repair & service.',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF94A3B8),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 7),
                                          const Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Icon(Icons.cancel,
                                                  size: 16,
                                                  color: Color(0xFFEF4444)),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Electronic parts fix & replacement.',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF94A3B8),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ] else ...[
                                          _buildUpgradeFeatureRow(
                                            'Internal machine deep-cleaning & high-pressure pipe flush',
                                            true,
                                          ),
                                          const SizedBox(height: 6),
                                          _buildUpgradeFeatureRow(
                                            'Booster pump pressure calibration & leakage inspection',
                                            true,
                                          ),
                                          const SizedBox(height: 6),
                                          _buildUpgradeFeatureRow(
                                            'Electrical SMPS, wiring & auto shut-off solenoid audit',
                                            true,
                                          ),
                                          const SizedBox(height: 6),
                                          _buildUpgradeFeatureRow(
                                            'Pre-filter replacement & complimentary tank cleaning included',
                                            true,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),

                                  // Upgrade action or confirmation badge
                                  const SizedBox(height: 14),
                                  if (!state.isUpgraded)
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFF0284C7),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14)),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          elevation: 0,
                                        ),
                                        icon: const Icon(
                                            Icons.arrow_circle_up_rounded,
                                            size: 18),
                                        label: const Text(
                                          'Upgrade to Full Service',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13.5),
                                        ),
                                        onPressed:
                                            _showUpgradeConfirmationDialog,
                                      ),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDCFCE7),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                            color: const Color(0xFF86EFAC)),
                                      ),
                                      child: const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.verified_rounded,
                                              size: 16,
                                              color: Color(0xFF16A34A)),
                                          SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              'Upgraded to Full Service (₹149 Applied)',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                  color: Color(0xFF15803D)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 2. Scan & Buy Spares (Factory Direct — mobile hardware scanner only)
              if (canShowActiveServiceActions && !WebAppDownloadConfig.isWeb) ...[
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFBAE6FD), width: 1.4),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0C0284C7),
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(19),
                    child: Stack(
                      children: [
                        const Positioned(
                          top: 0,
                          right: 0,
                          child: _GlassyOfferTag(),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(15),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header Row
                              Padding(
                                padding: const EdgeInsets.only(right: 88),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE0F2FE),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(Icons.qr_code_scanner_rounded, size: 18, color: Color(0xFF0284C7)),
                                    ),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Scan & Buy Spares',
                                              maxLines: 1,
                                              softWrap: false,
                                              style: TextStyle(
                                                fontSize: 18.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0F172A),
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                          ),
                                          SizedBox(height: 1),
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              '100% genuine spare parts with authentic QR code',
                                              maxLines: 1,
                                              softWrap: false,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w500,
                                                color: Color(0xFF64748B),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                      const SizedBox(height: 12),

                      // Features Matrix (2x2 Grid: Factory Direct, Genuine High Quality, Upto 2 Year Life, 1 Year Warranty)
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0F9FF).withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE0F2FE)),
                        ),
                        child: Builder(
                          builder: (_) {
                            final consumableText = (_catalogHighlights?['consumable_label']
                                            ?.toString()
                                            .trim()
                                            .isNotEmpty ==
                                        true)
                                ? _catalogHighlights!['consumable_label'].toString().trim()
                                : 'Liters Rated Life';
                            final nonConsumableText = (_catalogHighlights?['non_consumable_label']
                                            ?.toString()
                                            .trim()
                                            .isNotEmpty ==
                                        true)
                                ? _catalogHighlights!['non_consumable_label'].toString().trim()
                                : 'Factory Warranty';
                            return Column(
                              children: [
                                const Row(
                                  children: [
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Icon(Icons.precision_manufacturing_outlined, size: 19, color: Color(0xFF0284C7)),
                                          SizedBox(width: 6),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                'Direct from Factory',
                                                maxLines: 1,
                                                softWrap: false,
                                                style: TextStyle(
                                                  fontSize: 12.0,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFF0F172A),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: 44),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Icon(Icons.verified_outlined, size: 19, color: Color(0xFF0284C7)),
                                          SizedBox(width: 6),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                'Genuine Parts',
                                                maxLines: 1,
                                                softWrap: false,
                                                style: TextStyle(
                                                  fontSize: 12.0,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFF0F172A),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 11),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.water_drop_outlined, size: 19, color: Color(0xFF0284C7)),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.centerLeft,
                                                  child: Text(
                                                    consumableText,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: const TextStyle(
                                                      fontSize: 12.0,
                                                      fontWeight: FontWeight.w700,
                                                      color: Color(0xFF0F172A),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 1),
                                                const FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.centerLeft,
                                                  child: Text(
                                                    '(Consumable parts)',
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: TextStyle(
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: Color(0xFF64748B),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 44),
                                    Expanded(
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.verified_user_outlined, size: 19, color: Color(0xFF0284C7)),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.centerLeft,
                                                  child: Text(
                                                    nonConsumableText,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: const TextStyle(
                                                      fontSize: 12.0,
                                                      fontWeight: FontWeight.w700,
                                                      color: Color(0xFF0F172A),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 1),
                                                const FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.centerLeft,
                                                  child: Text(
                                                    '(Non consumable parts)',
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: TextStyle(
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: Color(0xFF64748B),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 10),

                      // Interactive Know and Learn About RO Link Card
                      InkWell(
                        onTap: _openKnowAboutRoSheet,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFC7D2FE)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.school_outlined, size: 18, color: Color(0xFF4F46E5)),
                              SizedBox(width: 9),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Know and Learn About RO',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF1E1B4B),
                                      ),
                                    ),
                                    SizedBox(height: 1),
                                    Text(
                                      'Water TDS guide, filter care & DIY guide',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: Color(0xFF4338CA),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Color(0xFF6366F1)),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 11),

                      // Primary Scan CTA Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          icon: const Icon(Icons.qr_code_scanner_rounded, size: 17),
                          label: const Text(
                            'Scan 100% Genuine Products or Kits',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                          ),
                          onPressed: _openQrScanner,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Must replace Sediment, Carbon, Antiscalant, Post Carbon & Pre-Filter for best performance',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                    ],
                  ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_purchasedSpares.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _buildPurchasedSparesCard(allowScanMore: true),
                ],
                const SizedBox(height: 14),
              ],

              // 3. Technician Profile Card (Hidden once service is in progress / completed / cancelled)
              if (state.hasTechnicianAssigned &&
                  !isInService &&
                  !isCompleted &&
                  !isCancelled) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _TechnicianAvatarTile(
                            photoUrl: state.technicianPhotoUrl,
                            technicianName: state.technicianName,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        state.technicianName,
                                        style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDCFCE7),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'VERIFIED',
                                        style: TextStyle(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF16A34A),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                TechnicianRatingBadgeRow(
                                  rating: state.technicianRating,
                                  ratingCount: state.technicianRatingCount,
                                  completedJobs: state.completedJobs,
                                  showViewReviewsHint: true,
                                  onTap: () => _openTechnicianReviewsSheet(state),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!state.isInService &&
                                  state.cleanTechnicianPhone.isNotEmpty)
                                IconButton(
                                  icon: const Icon(Icons.phone_rounded,
                                      color: Color(0xFF0284C7), size: 20),
                                  padding: const EdgeInsets.all(6),
                                  constraints: const BoxConstraints(
                                    minWidth: 34,
                                    minHeight: 34,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Call Technician',
                                  onPressed: _makePhoneCall,
                                ),
                              if (state.bookingId.trim().isNotEmpty &&
                                  !state.isArrived &&
                                  !state.isInService &&
                                  !state.isCompleted &&
                                  !state.isCancelled)
                                Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Material(
                                      color: const Color(0xFFECFDF5),
                                      borderRadius: BorderRadius.circular(10),
                                      child: InkWell(
                                        onTap: _openTechnicianChat,
                                        borderRadius: BorderRadius.circular(10),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(
                                              color: const Color(0xFF86EFAC),
                                            ),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.chat_bubble_rounded,
                                                color: Color(0xFF15803D),
                                                size: 13,
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                'Chat Tech',
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: Color(0xFF15803D),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_unreadChatCount > 0)
                                      Positioned(
                                        right: -4,
                                        top: -4,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFDC2626),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            _unreadChatCount > 9 ? '9+' : '$_unreadChatCount',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                size: 15, color: Color(0xFF0284C7)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                state.isInService
                                    ? '${state.technicianName} is actively working on your purifier at your doorstep.'
                                    : 'Assigned certified RO technician for doorstep machine maintenance and genuine spares fitting.',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF475569),
                                    height: 1.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ] else if (isInService && state.hasTechnicianAssigned) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF16A34A),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${state.technicianName} is working',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF166534),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ] else if (!state.hasTechnicianAssigned &&
                  !isInService &&
                  !isCompleted &&
                  !isCancelled) ...[
                // Dispatch Status Banner when technician is not yet assigned
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x06000000),
                          blurRadius: 8,
                          offset: Offset(0, 2)),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFBBF7D0)),
                        ),
                        child: const Icon(Icons.assignment_ind_rounded,
                            color: Color(0xFF16A34A), size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Technician Assignment in Progress',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              state.isScheduledNextDay
                                  ? 'Our Hub operations team will allocate a certified technician for your scheduled window (${state.preferredTimeSlot ?? state.scheduledWindow}).'
                                  : 'Our dispatch team is currently assigning the nearest available certified RO specialist to your booking.',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF64748B),
                                  height: 1.3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 4. Central Hub & Support Helpdesk (Completely Separate Card Below Technician)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x06000000),
                        blurRadius: 10,
                        offset: Offset(0, 3)),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: const Icon(Icons.support_agent_rounded,
                          color: Color(0xFF16A34A), size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Need Help or Escalation?',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF0284C7),
                        side: const BorderSide(
                            color: Color(0xFF0284C7), width: 1.2),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.chat_bubble_outline_rounded,
                          size: 14),
                      label: const Text(
                        'Chat to Support',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 11.5),
                      ),
                      onPressed: _showQuickSupportSheet,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
            ],
          ),
        );
      },
    );
  }
}

class _GlassyOfferTag extends StatefulWidget {
  const _GlassyOfferTag();

  @override
  State<_GlassyOfferTag> createState() => _GlassyOfferTagState();
}

class _GlassyOfferTagState extends State<_GlassyOfferTag>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(11)),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final double sweep = (_controller.value * 2.4) - 0.7;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF10B981),
                  Color(0xFF059669),
                  Color(0xFF047857),
                ],
              ),
              border: Border(
                left: BorderSide(color: Colors.white.withValues(alpha: 0.45), width: 0.8),
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.45), width: 0.8),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x28059669),
                  blurRadius: 8,
                  offset: Offset(-1, 2),
                ),
              ],
            ),
            foregroundDecoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(sweep - 0.45, -1.0),
                end: Alignment(sweep + 0.45, 1.0),
                colors: [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.32),
                  Colors.white.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
            child: child,
          );
        },
        child: const Text(
          'FLAT 80% OFF',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: 0.35,
          ),
        ),
      ),
    );
  }
}

/// Returns true when [url] is an HTTP(S) or `data:image/` URI suitable for rendering.
bool isValidTechnicianPhotoUrl(String? url) {
  final clean = (url ?? '').trim();
  if (clean.isEmpty) return false;
  final lower = clean.toLowerCase();
  return lower.startsWith('https://') ||
      lower.startsWith('http://') ||
      lower.startsWith('data:image/');
}

/// Shared image renderer for both the 52x52 card thumbnail and the full-size lightbox.
Widget buildTechnicianPhotoImage(
  String url, {
  required BoxFit fit,
  double? width,
  double? height,
  required Widget fallback,
  Widget? loadingPlaceholder,
}) {
  final clean = url.trim();
  if (clean.toLowerCase().startsWith('data:image/')) {
    try {
      final bytes = UriData.fromUri(Uri.parse(clean)).contentAsBytes();
      return Image.memory(
        bytes,
        fit: fit,
        width: width,
        height: height,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback,
      );
    } catch (_) {
      return fallback;
    }
  }
  return Image.network(
    clean,
    fit: fit,
    width: width,
    height: height,
    gaplessPlayback: true,
    loadingBuilder: (context, child, loadingProgress) {
      if (loadingProgress == null) return child;
      return loadingPlaceholder ?? fallback;
    },
    errorBuilder: (_, error, ___) {
      debugPrint('[TechPhoto] failed to load "$clean": $error');
      return fallback;
    },
  );
}

/// Opens a full-size pinch-to-zoom modal displaying the technician's verified photo.
Future<void> showTechnicianPhotoPreviewDialog(
  BuildContext context, {
  required String technicianName,
  required String photoUrl,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.86),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              technicianName.trim().isNotEmpty
                                  ? technicianName
                                  : 'Verified Technician',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              'VERIFIED',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF15803D),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Pinch or double-tap to zoom',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close photo preview',
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.68,
                maxWidth: MediaQuery.of(ctx).size.width - 32,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  color: const Color(0xFF0F172A),
                  child: InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 4.0,
                    child: buildTechnicianPhotoImage(
                      photoUrl,
                      fit: BoxFit.contain,
                      loadingPlaceholder: const SizedBox(
                        width: 240,
                        height: 240,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF38BDF8),
                            strokeWidth: 2.5,
                          ),
                        ),
                      ),
                      fallback: const SizedBox(
                        width: 240,
                        height: 240,
                        child: Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Color(0xFF94A3B8),
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TechnicianAvatarTile extends StatelessWidget {
  final String? photoUrl;
  final String technicianName;

  const _TechnicianAvatarTile({
    required this.photoUrl,
    required this.technicianName,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = isValidTechnicianPhotoUrl(photoUrl);
    const fallbackIcon = Center(
      child: Icon(Icons.engineering_rounded, color: Color(0xFF0284C7), size: 30),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (hasPhoto) {
            showTechnicianPhotoPreviewDialog(
              context,
              technicianName: technicianName,
              photoUrl: photoUrl!,
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Verified technician photo has not been uploaded yet.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFFE0F2FE),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasPhoto ? const Color(0xFF7DD3FC) : const Color(0xFFBAE6FD),
              width: hasPhoto ? 1.5 : 1.0,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x140284C7),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12.5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasPhoto)
                  buildTechnicianPhotoImage(
                    photoUrl!,
                    fit: BoxFit.cover,
                    width: 52,
                    height: 52,
                    fallback: fallbackIcon,
                  )
                else
                  fallbackIcon,
                if (hasPhoto)
                  Positioned(
                    right: 3,
                    bottom: 3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Icon(
                        Icons.zoom_out_map_rounded,
                        color: Colors.white,
                        size: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pure vector mini-map thumbnail (zero network tile requests or OSRM API hits).
class _MiniMapPreviewPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFFF1F5F9);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Subtle park & urban blocks
    final blockPaint = Paint()..color = const Color(0xFFE2E8F0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(8, 8, size.width * 0.34, size.height * 0.34),
        const Radius.circular(4),
      ),
      blockPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.54, size.height * 0.46, size.width * 0.36,
            size.height * 0.34),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFFDCFCE7),
    );

    // Clean road lines + roundabout ring
    final roadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, size.height * 0.48),
      Offset(size.width, size.height * 0.34),
      roadPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.44, 0),
      Offset(size.width * 0.60, size.height),
      roadPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.51, size.height * 0.42),
      10,
      roadPaint,
    );

    // Dashed curved arc between rider & doorstep pins
    final p0 = Offset(24, size.height * 0.44);
    final p1 = Offset(size.width * 0.56, size.height * 0.12);
    final p2 = Offset(size.width - 24, size.height * 0.36);
    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..quadraticBezierTo(p1.dx, p1.dy, p2.dx, p2.dy);

    final dashPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final metric in path.computeMetrics()) {
      double dist = 0.0;
      while (dist < metric.length) {
        final next = math.min(metric.length, dist + 4.5);
        canvas.drawPath(metric.extractPath(dist, next), dashPaint);
        dist += 8.0;
      }
    }

    // Home marker (doorstep)
    canvas.drawCircle(p0, 9.5, Paint()..color = const Color(0xFF0F172A));
    canvas.drawCircle(p0, 4.0, Paint()..color = Colors.white);

    // Technician marker (en route)
    canvas.drawCircle(p2, 9.5, Paint()..color = const Color(0xFF0F766E));
    canvas.drawCircle(p2, 4.0, Paint()..color = const Color(0xFF99F6E4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
