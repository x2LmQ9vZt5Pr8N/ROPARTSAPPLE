import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' as ll;
import '../models/user_address.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';

class MapAddressPickerSheet extends StatefulWidget {
  final CartState cartState;
  final UserAddress? initialAddress;
  final bool autoLocate;
  final bool requireDoorstepServiceability;
  final ValueChanged<UserAddress>? onAddressSaved;

  const MapAddressPickerSheet({
    super.key,
    required this.cartState,
    this.initialAddress,
    this.autoLocate = false,
    this.requireDoorstepServiceability = false,
    this.onAddressSaved,
  });

  @override
  State<MapAddressPickerSheet> createState() => _MapAddressPickerSheetState();
}

class _MapAddressPickerSheetState extends State<MapAddressPickerSheet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TextEditingController _flatController;
  late TextEditingController _areaController;
  late TextEditingController _landmarkController;
  late TextEditingController _pincodeController;
  late TextEditingController _stateController;
  late TextEditingController _recipientNameController;
  late TextEditingController _recipientPhoneController;
  late TextEditingController _searchController;
  late TextEditingController _tagController;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _flatKey = GlobalKey();
  final GlobalKey _pincodeKey = GlobalKey();
  final GlobalKey _tagKey = GlobalKey();

  String? _flatError;
  String? _pincodeError;
  String? _tagError;

  final MapController _mapController = MapController();

  bool _isDefault = true;
  bool _isLocatingGps = false;
  bool _isPinBouncing = false;
  bool _isAwaitingSettings = false;
  bool _autoLocateAttempted = false;
  bool _isReverseGeocoding = false;

  // Real Geo Coordinates
  double _lat = 12.9352;
  double _lng = 77.6775;
  String _detectedArea = 'Locating address...';
  String _detectedCity = 'Bengaluru';
  String _detectedPincode = '560034';

  // Meta-Ad Radius Serviceability & Expansion State
  bool _isServiceable = true;
  bool _isCheckingServiceability = false;
  String? _serviceabilityMessage;
  double? _distanceFromNearestKm;
  String? _nearestAreaName;
  bool _interestSubmitted = false;
  bool _isSubmittingInterest = false;

  final List<Map<String, dynamic>> _quickLocations = [
    {
      'name': 'Bellandur, Bengaluru',
      'lat': 12.9352,
      'lng': 77.6775,
      'pin': '560034',
      'city': 'Bengaluru',
      'area': 'Bellandur, Outer Ring Road',
    },
    {
      'name': 'Connaught Place, New Delhi',
      'lat': 28.6304,
      'lng': 77.2177,
      'pin': '110001',
      'city': 'New Delhi',
      'area': 'Barakhamba Road, Connaught Place',
    },
    {
      'name': 'Fort, South Mumbai',
      'lat': 18.9388,
      'lng': 72.8354,
      'pin': '400001',
      'city': 'Mumbai',
      'area': 'MIDC Industrial Area, Fort',
    },
    {
      'name': 'HSR Layout, Bengaluru',
      'lat': 12.9121,
      'lng': 77.6446,
      'pin': '560102',
      'city': 'Bengaluru',
      'area': 'Sector 2, HSR Layout',
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final init = widget.initialAddress;
    // HOUSE / FLAT must NEVER be pre-filled for a new address
    final initialFlat = (init != null && init.hasValidDoorstep && init.flatNo.trim().toLowerCase() != 'current location')
        ? init.flatNo
        : '';
    _flatController = TextEditingController(text: initialFlat);
    _areaController = TextEditingController(text: init?.streetArea ?? _detectedArea);
    _landmarkController = TextEditingController(text: init?.landmark ?? '');
    _pincodeController = TextEditingController(text: init?.pincode ?? _detectedPincode);
    _stateController = TextEditingController(text: init?.stateName ?? '');
    _recipientNameController = TextEditingController(
      text: (init?.recipientName?.isNotEmpty == true)
          ? init!.recipientName!
          : widget.cartState.userName,
    );
    _recipientPhoneController = TextEditingController(
      text: (init?.recipientPhone?.isNotEmpty == true)
          ? init!.recipientPhone!
          : widget.cartState.userPhone.replaceAll(RegExp(r'\D'), ''),
    );
    _searchController = TextEditingController();
    _tagController = TextEditingController();

    final hasHomeAlready = widget.cartState.addresses.any((a) =>
      a.id != widget.initialAddress?.id &&
      a.tag.trim().toLowerCase() == 'home'
    );

    if (init != null) {
      _tagController.text = init.tag;
      _isDefault = init.isDefault;
      if (init.hasMapPin) {
        _lat = init.latitude;
        _lng = init.longitude;
      }
      _detectedCity = init.city.isNotEmpty ? init.city : _detectedCity;
      _detectedPincode = init.pincode.isNotEmpty ? init.pincode : _detectedPincode;
      _detectedArea = init.streetArea;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _evaluateServiceability(_lat, _lng, _detectedPincode);
        }
      });
    } else if (!hasHomeAlready) {
      // 1st-time / new user: pre-fill 'Home' for fast 1-tap checkout!
      _tagController.text = 'Home';
    } else {
      // 'Home' already exists in saved addresses: do NOT pre-fill 'Home'
      _tagController.text = '';
    }

    if ((widget.autoLocate || widget.initialAddress == null || !widget.initialAddress!.hasMapPin) && !_autoLocateAttempted) {
      _autoLocateAttempted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _requestAndFetchDeviceLocation();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flatController.dispose();
    _areaController.dispose();
    _landmarkController.dispose();
    _pincodeController.dispose();
    _stateController.dispose();
    _recipientNameController.dispose();
    _recipientPhoneController.dispose();
    _searchController.dispose();
    _tagController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAwaitingSettings) {
      _isAwaitingSettings = false;
      // Re-trigger location detection when user returns from device settings
      _requestAndFetchDeviceLocation(isRetry: true);
    }
  }

  Future<void> _reverseGeocode(double lat, double lng) async {
    if (_isReverseGeocoding) return;
    _isReverseGeocoding = true;
    try {
      try {
        // 1. Ola Maps High-Precision Indian Geocoder
        final url = Uri.parse(
          'https://api.olamaps.io/places/v1/reverse-geocode?latlng=$lat,$lng&api_key=${ApiService.olaMapsApiKey}',
        );
        final response = await http.get(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final results = data['results'] as List?;
          if (results != null && results.isNotEmpty && mounted) {
            final first = results.first as Map<String, dynamic>;
            final comps = (first['address_components'] as List?) ?? [];

            String getComp(String type) {
              for (final c in comps) {
                final types = (c['types'] as List?) ?? [];
                if (types.contains(type)) return (c['long_name'] ?? c['short_name'] ?? '').toString().trim();
              }
              return '';
            }

            final neighborhood = getComp('neighborhood');
            final sublocality = getComp('sublocality');
            final locality = getComp('locality');
            final adminState = getComp('administrative_area_level_1');
            final pin = getComp('postal_code');
            final street = getComp('street_address');
            final premise = (first['name'] ?? '').toString().trim();

            final areaParts = <String>[];
            if (premise.isNotEmpty && !areaParts.contains(premise)) areaParts.add(premise);
            if (street.isNotEmpty && !areaParts.contains(street) && street != premise) areaParts.add(street);
            if (neighborhood.isNotEmpty && !areaParts.contains(neighborhood)) areaParts.add(neighborhood);
            if (sublocality.isNotEmpty && !areaParts.contains(sublocality)) areaParts.add(sublocality);

            final detectedArea = areaParts.isNotEmpty
                ? areaParts.join(', ')
                : (first['formatted_address']?.toString() ?? 'Selected Location');
            final detectedCity = locality.isNotEmpty ? locality : 'Bengaluru';

            setState(() {
              _detectedArea = detectedArea;
              _detectedCity = detectedCity;
              if (adminState.isNotEmpty && _stateController.text.trim().isEmpty) {
                _stateController.text = adminState;
              }
              if (pin.isNotEmpty) {
                _detectedPincode = pin;
                _pincodeController.text = pin;
              }
              _areaController.text = detectedArea;
            });
            _evaluateServiceability(lat, lng, pin.isNotEmpty ? pin : null);
            return;
          }
        }
      } catch (e) {
        debugPrint('Ola Maps reverse geocoding fallback: $e');
      }

      if (kIsWeb) {
        _evaluateServiceability(lat, lng, null);
        return;
      }

      // 2. Fallback to native system geocoding if network error occurs
      try {
        final placemarks = await Geocoding().placemarkFromCoordinates(lat, lng);
        if (placemarks.isNotEmpty && mounted) {
          final p = placemarks.first;

          final street = p.street?.trim() ?? '';
          final subLoc = p.subLocality?.trim() ?? '';
          final locality = p.locality?.trim() ?? '';
          final subAdmin = p.subAdministrativeArea?.trim() ?? '';
          final admin = p.administrativeArea?.trim() ?? '';
          final pin = p.postalCode?.trim() ?? '';

          final areaParts = <String>[];
          if (street.isNotEmpty && !street.contains('+') && !street.toLowerCase().contains(subLoc.toLowerCase())) {
            areaParts.add(street);
          }
          if (subLoc.isNotEmpty) areaParts.add(subLoc);
          if (locality.isNotEmpty && !areaParts.contains(locality)) areaParts.add(locality);

          final detectedArea = areaParts.isNotEmpty
              ? areaParts.join(', ')
              : (subLoc.isNotEmpty ? subLoc : (locality.isNotEmpty ? locality : 'Selected Location'));

          final detectedCity = locality.isNotEmpty
              ? locality
              : (subAdmin.isNotEmpty ? subAdmin : (admin.isNotEmpty ? admin : 'India'));

          setState(() {
            _detectedArea = detectedArea;
            _detectedCity = detectedCity;
            if (admin.isNotEmpty) {
              _stateController.text = admin;
            }
            if (pin.isNotEmpty) {
              _detectedPincode = pin;
              _pincodeController.text = pin;
            }
            _areaController.text = detectedArea;
          });
          _evaluateServiceability(lat, lng, pin.isNotEmpty ? pin : null);
        }
      } catch (e) {
        debugPrint('Geocoding error: $e');
      }
    } finally {
      _isReverseGeocoding = false;
    }
  }

  Future<void> _evaluateServiceability(double lat, double lng, String? pin) async {
    if (!mounted) return;
    setState(() {
      _isCheckingServiceability = true;
      _interestSubmitted = false;
    });

    try {
      final res = await ApiService().checkServiceability(
        latitude: lat,
        longitude: lng,
        pincode: pin,
      );

      if (!mounted) return;
      final isServ = res['serviceable'] == true;
      final nearest = res['nearest_area'] as Map<String, dynamic>?;
      final rawDist = res['distance_km'] ?? nearest?['distance_km'];
      final dist = (rawDist is num) ? rawDist.toDouble() : double.tryParse(rawDist?.toString() ?? '');
      final areaName = (res['area']?['name'] ?? nearest?['name']) as String?;

      setState(() {
        _isServiceable = isServ;
        _isCheckingServiceability = false;
        _serviceabilityMessage = res['message']?.toString();
        _distanceFromNearestKm = dist?.toDouble();
        _nearestAreaName = areaName;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isServiceable = false;
          _isCheckingServiceability = false;
          _serviceabilityMessage = 'Unable to verify serviceability right now. Please tap retry or adjust pin.';
          _distanceFromNearestKm = null;
          _nearestAreaName = null;
        });
      }
    }
  }

  Future<void> _submitExpansionInterest() async {
    if (_isSubmittingInterest || _interestSubmitted) return;
    setState(() => _isSubmittingInterest = true);

    try {
      final customerId = widget.cartState.customerId;
      final customerName = widget.cartState.userName.isNotEmpty ? widget.cartState.userName : null;
      final customerPhone = widget.cartState.userPhone.isNotEmpty ? widget.cartState.userPhone : null;

      final res = await ApiService().expressExpansionInterest(
        addressText: _detectedArea,
        latitude: _lat,
        longitude: _lng,
        pincode: _pincodeController.text.trim().isNotEmpty ? _pincodeController.text.trim() : _detectedPincode,
        city: _detectedCity,
        customerEntityId: customerId,
        customerName: customerName,
        customerPhone: customerPhone,
      );

      if (mounted) {
        setState(() {
          _isSubmittingInterest = false;
          _interestSubmitted = true;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF0F172A),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF38BDF8), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    res['message']?.toString() ?? 'Thank you! Priority expansion request logged.',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmittingInterest = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not submit expansion request. Please check your connection and try again.'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _requestAndFetchDeviceLocation({bool isRetry = false}) async {
    if (!mounted) return;
    setState(() => _isLocatingGps = true);

    try {
      // 1. Check if location services (GPS hardware) are turned on
      final isServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isServiceEnabled) {
        if (!mounted) return;
        setState(() => _isLocatingGps = false);
        _showGpsServiceDialog();
        return;
      }

      // 2. Check & ask for permission repeatedly until granted
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (!mounted) return;
          setState(() => _isLocatingGps = false);
          _showPermissionDeniedDialog(permanently: false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _isLocatingGps = false);
        _showPermissionDeniedDialog(permanently: true);
        return;
      }

      // 3. Permission is granted: Fetch accurate real coordinates using best navigation accuracy
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            timeLimit: Duration(seconds: 12),
          ),
        );
      } catch (e) {
        debugPrint('High accuracy GPS timeout, trying last known position: $e');
        position = await Geolocator.getLastKnownPosition();
      }

      if (position == null) {
        if (!mounted) return;
        setState(() => _isLocatingGps = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not get GPS fix. Please ensure location is enabled and try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final lat = position.latitude;
      final lng = position.longitude;

      if (!mounted) return;
      setState(() {
        _lat = lat;
        _lng = lng;
        _isLocatingGps = false;
      });

      _mapController.move(ll.LatLng(lat, lng), 17.0);

      // 4. Reverse geocode real coordinates to populate address fields
      await _reverseGeocode(lat, lng);
    } catch (e) {
      debugPrint('Error getting GPS location: $e');
      if (mounted) {
        setState(() => _isLocatingGps = false);
      }
    }
  }

  void _showGpsServiceDialog() {
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
            'Location services (GPS) are turned off. RO Parts needs GPS to pinpoint your exact doorstep for prompt delivery.',
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
                  _isAwaitingSettings = true;
                  await Geolocator.openLocationSettings();
                }
              },
              child: const Text('Turn On GPS', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
  }

  void _showPermissionDeniedDialog({required bool permanently}) {
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
                  permanently ? 'Permission Required' : 'Allow Location Access',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
              ),
            ],
          ),
          content: Text(
            permanently
                ? 'Location permission is permanently blocked in your device settings. Please enable "Allow while using app" in App Settings to detect your doorstep.'
                : 'RO Parts needs device location permission to accurately deliver spares to your doorstep. Please grant location access.',
            style: const TextStyle(fontSize: 13.5, color: Color(0xFF475569), height: 1.4),
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
                if (permanently && !kIsWeb) {
                  _isAwaitingSettings = true;
                  await Geolocator.openAppSettings();
                } else if (!permanently) {
                  // Ask again immediately!
                  _requestAndFetchDeviceLocation(isRetry: true);
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

  Future<void> _searchLocation(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    FocusScope.of(context).unfocus();

    double? foundLat;
    double? foundLng;

    try {
      final url = Uri.parse(
        'https://api.olamaps.io/places/v1/geocode?address=${Uri.encodeComponent(trimmed)}&api_key=${ApiService.olaMapsApiKey}',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final first = results.first as Map?;
          final geometry = first?['geometry'] as Map?;
          final loc = geometry?['location'] as Map?;
          final rawLat = loc?['lat'];
          final rawLng = loc?['lng'];
          foundLat = rawLat is num ? rawLat.toDouble() : double.tryParse('$rawLat');
          foundLng = rawLng is num ? rawLng.toDouble() : double.tryParse('$rawLng');
        }
      }
    } catch (e) {
      debugPrint('Ola Maps geocode search fallback: $e');
    }

    if ((foundLat == null || foundLng == null) && !kIsWeb) {
      try {
        final locations = await Geocoding().locationFromAddress(trimmed);
        if (locations.isNotEmpty) {
          foundLat = locations.first.latitude;
          foundLng = locations.first.longitude;
        }
      } catch (e) {
        debugPrint('Native address search error: $e');
      }
    }

    if (!mounted) return;
    if (foundLat != null && foundLng != null) {
      setState(() {
        _lat = foundLat!;
        _lng = foundLng!;
      });
      _mapController.move(ll.LatLng(foundLat, foundLng), 16.5);
      _reverseGeocode(foundLat, foundLng);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No matching location found. Try a nearby landmark or adjust the pin.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _selectQuickLocation(Map<String, dynamic> loc) {
    setState(() {
      _lat = loc['lat'];
      _lng = loc['lng'];
      _detectedArea = loc['area'];
      _detectedCity = loc['city'];
      _detectedPincode = loc['pin'];
      _areaController.text = _detectedArea;
      _pincodeController.text = _detectedPincode;
    });
    _mapController.move(ll.LatLng(_lat, _lng), 16.5);
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, (currentZoom + 1).clamp(3.0, 19.0));
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, (currentZoom - 1).clamp(3.0, 19.0));
  }

  void _scrollToKey(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (key.currentContext != null) {
        Scrollable.ensureVisible(
          key.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.25,
        );
      }
    });
  }

  void _saveAddress() {
    if (!_isServiceable && widget.requireDoorstepServiceability) {
      _submitExpansionInterest();
      return;
    }

    // 0. Unified 8-address ceiling
    if (widget.initialAddress == null && widget.cartState.addresses.length >= CartState.maxSavedAddresses) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maximum ${CartState.maxSavedAddresses} saved addresses allowed per account. Please delete or edit an existing address.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final flat = _flatController.text.trim();
    final area = _areaController.text.trim();
    final pin = _pincodeController.text.trim();
    final tag = _tagController.text.trim();

    setState(() {
      _flatError = null;
      _pincodeError = null;
      _tagError = null;
    });

    if (flat.isEmpty || flat.toLowerCase() == 'current location' || flat.toLowerCase() == 'home' || flat.toLowerCase() == 'work') {
      setState(() => _flatError = 'Please enter your specific house / flat / floor / building number *');
      _scrollToKey(_flatKey);
      return;
    }

    if (pin.length != 6) {
      setState(() => _pincodeError = 'Please enter a valid 6-digit delivery pincode *');
      _scrollToKey(_pincodeKey);
      return;
    }

    if (tag.isEmpty) {
      setState(() => _tagError = 'Please enter an address label / tag (e.g. Home, Work, Shop) *');
      _scrollToKey(_tagKey);
      return;
    }

    // Verify for duplicate tags
    final isDuplicate = widget.cartState.addresses.any((a) =>
      a.id != widget.initialAddress?.id &&
      a.tag.trim().toLowerCase() == tag.toLowerCase()
    );

    if (isDuplicate) {
      setState(() => _tagError = tag.toLowerCase() == 'home'
          ? 'Address label "Home" is already saved. Please enter a different label'
          : 'Address label "$tag" is already saved. Each address must have a unique label');
      _scrollToKey(_tagKey);
      return;
    }

    final recName = _recipientNameController.text.trim();
    final recPhone = _recipientPhoneController.text.replaceAll(RegExp(r'\D'), '');
    final recState = _stateController.text.trim();

    final newAddress = UserAddress(
      id: widget.initialAddress?.id ?? 'addr-${DateTime.now().millisecondsSinceEpoch}',
      sk: widget.initialAddress?.sk,
      tag: tag,
      addressType: 'UNIFIED',
      recipientName: recName.isNotEmpty ? recName : null,
      recipientPhone: recPhone.isNotEmpty ? recPhone : null,
      flatNo: flat,
      streetArea: area.isNotEmpty ? area : _detectedArea,
      landmark: _landmarkController.text.trim(),
      city: _detectedCity,
      stateName: recState.isNotEmpty ? recState : null,
      pincode: pin,
      latitude: _lat,
      longitude: _lng,
      isDefault: _isDefault,
    );

    if (widget.initialAddress != null) {
      widget.cartState.updateAddress(widget.initialAddress!.id, newAddress);
    } else {
      widget.cartState.addAddress(newAddress);
    }

    widget.cartState.selectAddress(newAddress);

    // Pop the bottom sheet first and return newAddress to awaiter
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    nav.pop(newAddress);

    messenger.showSnackBar(
      SnackBar(
        content: Text('Delivery address saved to $tag ($pin • $_detectedCity)'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    widget.onAddressSaved?.call(newAddress);
  }

  IconData _getTagIcon(String tag) {
    switch (tag.toLowerCase()) {
      case 'home':
        return Icons.home_rounded;
      case 'work':
      case 'office':
        return Icons.work_outline_rounded;
      case 'workshop':
      case 'warehouse':
        return Icons.build_circle_outlined;
      default:
        return Icons.location_on_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final keyboardBottom = MediaQuery.of(context).viewInsets.bottom;
    final hasHomeAlready = widget.cartState.addresses.any((a) =>
      a.id != widget.initialAddress?.id &&
      a.tag.trim().toLowerCase() == 'home'
    );

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.94,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboardBottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Drag Handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // 2. Header Bar: Title + Close Button
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.initialAddress != null ? 'Edit Delivery Address' : 'Select Delivery Location',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Drag map or pinch to zoom pinpoint',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF1F5F9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 18, color: Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

              // 3. Main Scrollable Content
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    // 3A. Search Bar with Quick Locations (Placed ABOVE the map!)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.search_rounded, size: 20, color: Color(0xFF0284C7)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                textInputAction: TextInputAction.search,
                                onSubmitted: _searchLocation,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                  hintText: _detectedArea.isNotEmpty
                                      ? _detectedArea
                                      : 'Search area, street, landmark...',
                                  hintStyle: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward_rounded, size: 18, color: Color(0xFF0284C7)),
                              tooltip: 'Search location',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _searchLocation(_searchController.text),
                            ),
                            PopupMenuButton<Map<String, dynamic>>(
                              icon: const Icon(Icons.tune_rounded, size: 20, color: Color(0xFF64748B)),
                              tooltip: 'Quick locations',
                              onSelected: _selectQuickLocation,
                              itemBuilder: (context) {
                                return _quickLocations.map((loc) {
                                  return PopupMenuItem(
                                    value: loc,
                                    child: Text(loc['name'], style: const TextStyle(fontSize: 13)),
                                  );
                                }).toList();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 3B. Interactive Map Viewport (OSM / CartoDB)
                    _buildMapViewport(),

                    // 3C. Address Details Form
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Pinpoint Summary Box (Meta-Ad Serviceability Status)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _isCheckingServiceability
                                  ? const Color(0xFFF8FAFC)
                                  : (_isServiceable ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB)),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _isCheckingServiceability
                                    ? const Color(0xFFE2E8F0)
                                    : (_isServiceable ? const Color(0xFFBBF7D0) : const Color(0xFFFDE68A)),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: _isCheckingServiceability
                                        ? const Color(0xFF64748B)
                                        : (_isServiceable ? const Color(0xFF16A34A) : const Color(0xFFD97706)),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Icon(
                                    _isCheckingServiceability
                                        ? Icons.sync_rounded
                                        : (_isServiceable ? Icons.my_location_rounded : Icons.explore_off_rounded),
                                    color: Colors.white,
                                    size: 17,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _detectedArea,
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        (_isCheckingServiceability || _isLocatingGps || _detectedArea == 'Locating address...')
                                            ? 'Detecting location & checking serviceability...'
                                            : (_isServiceable
                                                ? (_serviceabilityMessage ?? '$_detectedCity • $_detectedPincode • Serviceable Doorstep & Online')
                                                : (!widget.requireDoorstepServiceability
                                                    ? '$_detectedCity • $_detectedPincode • Pan-India Online Delivery Available'
                                                    : '$_detectedCity • $_detectedPincode • Coming Soon (Unavailable)')),
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: (_isCheckingServiceability || _isLocatingGps || _detectedArea == 'Locating address...')
                                              ? const Color(0xFF64748B)
                                              : ((_isServiceable || !widget.requireDoorstepServiceability)
                                                  ? const Color(0xFF16A34A)
                                                  : const Color(0xFFD97706)),
                                        ),
                                      ),
                                      if (!_isCheckingServiceability && !_isLocatingGps && _detectedArea != 'Locating address...' && !_isServiceable) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          !widget.requireDoorstepServiceability
                                              ? 'Pan-India courier spare orders ship here. Technician doorstep visits are currently outside hub radius.'
                                              : (_distanceFromNearestKm != null
                                                  ? 'We are ~${_distanceFromNearestKm!.toStringAsFixed(1)} km from ${_nearestAreaName ?? 'our active hub'}. Tap below to notify our team to expand here!'
                                                  : 'We have not launched here yet. Tap below to express interest!'),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF92400E),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),

                          // House / Flat / Floor No Field
                          KeyedSubtree(
                            key: _flatKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'HOUSE / FLAT / FLOOR / BUILDING * (REQUIRED)',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _flatController,
                                  onChanged: (val) {
                                    if (_flatError != null) setState(() => _flatError = null);
                                  },
                                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                                  decoration: InputDecoration(
                                    hintText: 'e.g. Flat 402, 4th Floor, Tower B',
                                    hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    errorText: _flatError,
                                    errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _flatError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                        width: _flatError != null ? 1.5 : 1.0,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _flatError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                        width: _flatError != null ? 1.5 : 1.0,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _flatError != null ? Colors.redAccent : const Color(0xFF0284C7),
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 14),

                          // Street / Road / Area
                          const Text(
                            'APARTMENT / ROAD / AREA *',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF475569),
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _areaController,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                            decoration: InputDecoration(
                              hintText: 'e.g. Green Glen Layout, Outer Ring Road',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.4),
                              ),
                            ),
                          ),

                          const SizedBox(height: 14),

                          // Landmark Field
                          const Text(
                            'LANDMARK (OPTIONAL)',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF475569),
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _landmarkController,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                            decoration: InputDecoration(
                              hintText: 'e.g. Behind Central Mall, Near Water Tank',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.4),
                              ),
                            ),
                          ),

                          const SizedBox(height: 14),

                          // Recipient Contact Row (Unified across Doorstep & Courier)
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'RECIPIENT NAME',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF475569),
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    TextField(
                                      controller: _recipientNameController,
                                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                                      decoration: InputDecoration(
                                        hintText: 'Full Name',
                                        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                        filled: true,
                                        fillColor: Colors.white,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.4),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'RECIPIENT PHONE',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF475569),
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    TextField(
                                      controller: _recipientPhoneController,
                                      keyboardType: TextInputType.phone,
                                      maxLength: 10,
                                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                                      decoration: InputDecoration(
                                        counterText: '',
                                        hintText: '10-digit mobile',
                                        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                        filled: true,
                                        fillColor: Colors.white,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.4),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 14),

                          // Pincode & State Row
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 4,
                                child: KeyedSubtree(
                                  key: _pincodeKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'PINCODE *',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF475569),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      TextField(
                                        controller: _pincodeController,
                                        keyboardType: TextInputType.number,
                                        maxLength: 6,
                                        onChanged: (val) {
                                          if (_pincodeError != null) setState(() => _pincodeError = null);
                                        },
                                        style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                          letterSpacing: 1.5,
                                        ),
                                        decoration: InputDecoration(
                                          counterText: '',
                                          hintText: '560034',
                                          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                          filled: true,
                                          fillColor: Colors.white,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                          errorText: _pincodeError,
                                          errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: _pincodeError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                              width: _pincodeError != null ? 1.5 : 1.0,
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: _pincodeError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                              width: _pincodeError != null ? 1.5 : 1.0,
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: _pincodeError != null ? Colors.redAccent : const Color(0xFF0284C7),
                                              width: 1.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'STATE',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF475569),
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    TextField(
                                      controller: _stateController,
                                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                                      decoration: InputDecoration(
                                        hintText: 'e.g. Karnataka',
                                        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                        filled: true,
                                        fillColor: Colors.white,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.4),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 18),

                          // 3D. "SAVE ADDRESS AS" Manual Tag Field + Quick Chips
                          KeyedSubtree(
                            key: _tagKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'SAVE ADDRESS AS (LABEL / TAG) * (REQUIRED)',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _tagController,
                                  onChanged: (val) {
                                    if (_tagError != null) setState(() => _tagError = null);
                                  },
                                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                                  decoration: InputDecoration(
                                    hintText: hasHomeAlready ? "e.g. Work, Workshop, Mom's Place, Shop" : "e.g. Home, Work, Workshop",
                                    hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    errorText: _tagError,
                                    errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _tagError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                        width: _tagError != null ? 1.5 : 1.0,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _tagError != null ? Colors.redAccent : const Color(0xFFCBD5E1),
                                        width: _tagError != null ? 1.5 : 1.0,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: _tagError != null ? Colors.redAccent : const Color(0xFF0284C7),
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    if (!hasHomeAlready) 'Home',
                                    'Work',
                                    'Workshop',
                                    'Office',
                                    'Warehouse',
                                  ].map((chip) {
                                    final isMatch = _tagController.text.trim().toLowerCase() == chip.toLowerCase();
                                    return BouncingWidget(
                                      onTap: () {
                                        setState(() {
                                          _tagController.text = chip;
                                          _tagError = null;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: isMatch ? const Color(0xFF0284C7) : const Color(0xFFF1F5F9),
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: isMatch ? const Color(0xFF0284C7) : const Color(0xFFCBD5E1),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _getTagIcon(chip),
                                              size: 13,
                                              color: isMatch ? Colors.white : const Color(0xFF475569),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              chip,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w700,
                                                color: isMatch ? Colors.white : const Color(0xFF334155),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Default Address Checkbox
                          GestureDetector(
                            onTap: () => setState(() => _isDefault = !_isDefault),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: _isDefault,
                                  onChanged: (val) => setState(() => _isDefault = val ?? false),
                                  activeColor: const Color(0xFF0284C7),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                ),
                                const Expanded(
                                  child: Text(
                                    'Set as default delivery address',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF334155),
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
              ),

              // 4. Sticky Bottom Action: Save & Deliver Here
              Container(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 0.8)),
                ),
                child: BouncingWidget(
                  onTap: (_isServiceable || !widget.requireDoorstepServiceability)
                      ? _saveAddress
                      : _submitExpansionInterest,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: (_isServiceable || !widget.requireDoorstepServiceability)
                          ? const Color(0xFF0F172A)
                          : (_interestSubmitted ? const Color(0xFF16A34A) : const Color(0xFFD97706)),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: ((_isServiceable || !widget.requireDoorstepServiceability)
                                  ? const Color(0xFF0F172A)
                                  : (_interestSubmitted ? const Color(0xFF16A34A) : const Color(0xFFD97706)))
                              .withValues(alpha: 0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _isSubmittingInterest
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                (_isServiceable || !widget.requireDoorstepServiceability)
                                    ? Icons.check_circle_rounded
                                    : (_interestSubmitted ? Icons.task_alt_rounded : Icons.notifications_active_rounded),
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  (_isServiceable || !widget.requireDoorstepServiceability)
                                      ? (widget.initialAddress != null
                                          ? 'Update Delivery Address'
                                          : (_isServiceable
                                              ? 'Save Address & Deliver Here'
                                              : 'Save for Pan-India Delivery'))
                                      : (_interestSubmitted
                                          ? 'Request Logged • We Will Notify You'
                                          : 'Notify Me When Available (Coming Soon)'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 4. OpenStreetMap / CartoDB Map Viewport (Zero Google Maps) ──
  Widget _buildMapViewport() {
    return Container(
      height: MediaQuery.of(context).viewInsets.bottom > 0 ? 180.0 : 300.0,
      width: double.infinity,
      color: const Color(0xFFE2E8F0),
      child: Stack(
        children: [
          // FlutterMap with CartoDB & OpenStreetMap (Zero Paid API waste)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: ll.LatLng(_lat, _lng),
              initialZoom: 16.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, hasGesture) {
                _lat = camera.center.latitude;
                _lng = camera.center.longitude;
                if (hasGesture && !_isPinBouncing) {
                  setState(() => _isPinBouncing = true);
                }
              },
              onMapEvent: (event) {
                if (event is MapEventMoveEnd) {
                  if (_isPinBouncing) {
                    setState(() => _isPinBouncing = false);
                  }
                  _reverseGeocode(_lat, _lng);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: ApiService.cartoTileUrl,
                userAgentPackageName: 'in.roparts.roparts',
                maxZoom: 20,
              ),
            ],
          ),

          // Center Pin with Radar Waves and Speech Balloon (Fixed at Exact Map Center)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Speech Balloon
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: _isServiceable ? const Color(0xFF0F172A) : const Color(0xFFD97706),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isServiceable ? Icons.person_pin_circle_rounded : Icons.explore_off_rounded,
                        size: 14,
                        color: _isServiceable ? const Color(0xFF38BDF8) : Colors.white,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _isServiceable ? 'I am here' : 'Coming Soon',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                // Balloon Triangle Pointer
                CustomPaint(
                  size: const Size(12, 6),
                  painter: _TrianglePainter(color: _isServiceable ? const Color(0xFF0F172A) : const Color(0xFFD97706)),
                ),
                const SizedBox(height: 2),

                // Animated Center Delivery Pin
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  transform: Matrix4.translationValues(0, _isPinBouncing ? -12 : 0, 0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(
                        Icons.location_on_rounded,
                        size: 46,
                        color: Color(0xFF0284C7),
                      ),
                      Positioned(
                        top: 10,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.water_drop_rounded,
                              size: 10,
                              color: Color(0xFF0284C7),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Radar Waves & Pin Tip Ground Shadow
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: _isPinBouncing ? 44 : 32,
                      height: _isPinBouncing ? 16 : 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.circular(999),
                        color: const Color(0xFF0284C7).withValues(alpha: _isPinBouncing ? 0.25 : 0.12),
                        border: Border.all(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.35),
                          width: 1.0,
                        ),
                      ),
                    ),
                    Container(
                      width: 12,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: _isPinBouncing ? 0.15 : 0.40),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
              ],
            ),
          ),

          // Floating Zoom In / Zoom Out Controls (+ and − buttons on Right Side)
          Positioned(
            right: 14,
            bottom: 64,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Zoom In Button (+)
                  BouncingWidget(
                    onTap: _zoomIn,
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      child: const Icon(Icons.add_rounded, size: 20, color: Color(0xFF334155)),
                    ),
                  ),
                  const Divider(height: 1, thickness: 0.8, color: Color(0xFFE2E8F0)),
                  // Zoom Out Button (−)
                  BouncingWidget(
                    onTap: _zoomOut,
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      child: const Icon(Icons.remove_rounded, size: 20, color: Color(0xFF334155)),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Floating "Locate Me" Button (Bottom Right)
          Positioned(
            bottom: 12,
            right: 14,
            child: BouncingWidget(
              onTap: _isLocatingGps ? () {} : () => _requestAndFetchDeviceLocation(isRetry: true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _isLocatingGps
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0284C7)),
                          )
                        : const Icon(Icons.my_location_rounded, size: 16, color: Color(0xFF0284C7)),
                    const SizedBox(width: 6),
                    const Text(
                      'Locate Me',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0284C7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) => false;
}
