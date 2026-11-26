import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

class RouteService {
  static final RouteService _instance = RouteService._internal();
  factory RouteService() => _instance;
  RouteService._internal();

  static const double _originCacheRadiusMeters = 80.0;
  static const double _destCacheRadiusMeters = 20.0;
  static const Duration _cacheMinCooldown = Duration(seconds: 20);

  LatLng? _cachedStart;
  LatLng? _cachedDestination;
  DateTime? _cachedAt;
  RouteResult? _cachedResult;
  Future<RouteResult>? _inFlightRequest;

  static double _approxDistanceMeters(LatLng a, LatLng b) {
    const double r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * (math.pi / 180.0);
    final dLng = (b.longitude - a.longitude) * (math.pi / 180.0);
    final sinLat = math.sin(dLat / 2.0);
    final sinLng = math.sin(dLng / 2.0);
    final h = sinLat * sinLat +
        math.cos(a.latitude * (math.pi / 180.0)) *
            math.cos(b.latitude * (math.pi / 180.0)) *
            sinLng *
            sinLng;
    final clamped = h.clamp(0.0, 1.0);
    return 2.0 * r * math.atan2(math.sqrt(clamped), math.sqrt(1.0 - clamped));
  }

  /// Returns true when the cached route covers this leg within 80m origin /
  /// 20m destination drift and inside the 20-second cooldown window.
  static bool isCacheHit({
    required LatLng start,
    required LatLng destination,
    required LatLng? cachedStart,
    required LatLng? cachedDestination,
    required DateTime? cachedAt,
    DateTime? now,
  }) {
    if (cachedStart == null || cachedDestination == null || cachedAt == null) {
      return false;
    }
    final checkNow = now ?? DateTime.now();
    return checkNow.difference(cachedAt) < _cacheMinCooldown &&
        _approxDistanceMeters(start, cachedStart) < _originCacheRadiusMeters &&
        _approxDistanceMeters(destination, cachedDestination) <
            _destCacheRadiusMeters;
  }

  /// Clears cached route (for new bookings or tests).
  void clearCache() {
    _cachedStart = null;
    _cachedDestination = null;
    _cachedAt = null;
    _cachedResult = null;
    _inFlightRequest = null;
  }

  /// Fetches road-following geometry from free OSRM routing with spatial +
  /// cooldown caching so stationary / minor coordinate shifts avoid repeat calls.
  Future<RouteResult> getDrivingRoute({
    required LatLng start,
    required LatLng destination,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedResult != null &&
        isCacheHit(
          start: start,
          destination: destination,
          cachedStart: _cachedStart,
          cachedDestination: _cachedDestination,
          cachedAt: _cachedAt,
        )) {
      return _cachedResult!;
    }

    if (_inFlightRequest != null) {
      return _inFlightRequest!;
    }

    final future = _fetchRouteFromOsrm(start, destination);
    _inFlightRequest = future;
    try {
      return await future;
    } finally {
      _inFlightRequest = null;
    }
  }

  Future<RouteResult> _fetchRouteFromOsrm(
    LatLng start,
    LatLng destination,
  ) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson',
      );

      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final distance = (route['distance'] as num).toDouble();
          final duration = (route['duration'] as num).toDouble();
          final rawCoords = route['geometry']['coordinates'] as List;

          final points = rawCoords.map((c) {
            return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
          }).toList();

          final result = RouteResult(
            points: points,
            distanceMeters: distance,
            durationSeconds: duration,
          );
          _cachedStart = start;
          _cachedDestination = destination;
          _cachedAt = DateTime.now();
          _cachedResult = result;
          return result;
        }
      }
    } catch (_) {
      // Fallback to cached route if available, otherwise straight line
      if (_cachedResult != null) return _cachedResult!;
    }

    return RouteResult(
      points: [start, destination],
      distanceMeters: 0,
      durationSeconds: 0,
    );
  }
}
