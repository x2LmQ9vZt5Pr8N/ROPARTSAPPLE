import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';
import '../utils/display_sanitizer.dart';
import '../utils/phone_normalizer.dart';

enum TechnicianStatus {
  booked,
  onTheWay,
  arrived,
  inService,
  completed,
  cancelled,
}

class ServiceTrackingState extends ChangeNotifier {
  String _bookingId = '';
  String _serviceTitle = 'Quick RO Visit & Inspection';
  int _fee = 49;
  bool _isUpgraded = false;
  TechnicianStatus _status = TechnicianStatus.booked;
  bool _hasActiveBooking = false;
  int _etaMinutes = 15;
  String? _arrivalOtp;
  bool _isOtpShared = false;
  bool _preArrivalOtpOnly = false;

  String _technicianName = '';
  String _technicianPhone = '';
  String? _technicianBadge;
  String? _technicianPhotoUrl;
  double? _technicianRating;
  int _technicianRatingCount = 0;
  int? _completedJobs;
  int? _customerRating;
  String? _customerReview;
  DateTime? _ratedAt;
  String _customerAddress = '';
  double _customerLat = 12.9279;
  double _customerLng = 77.6740;
  double? _technicianLat;
  double? _technicianLng;
  double? _distanceKm;

  String? _receiverName;
  String? _receiverPhone;
  bool _isForSomeoneElse = false;
  String _visitPurpose = 'STANDARD';
  bool _isFreeVisit = false;

  final List<String> _checklist = [
    'Pre-Filter Sediment & Sand Inspection',
    'RO Membrane TDS Rejection Efficiency Test',
    'Booster Pump 24V DC Pressure Calibration',
    'Solenoid Valve Auto Shut-off & Electrical Check',
  ];

  // Getters
  String get bookingId => _bookingId;
  String get visitPurpose => _visitPurpose;
  bool get isFreeVisit =>
      _isFreeVisit || _visitPurpose == 'FREE_VISIT' || _visitPurpose == 'FREE_REVISIT';
  bool get isFreeRevisit => _visitPurpose == 'FREE_REVISIT';
  double get customerLat => _customerLat;
  double get customerLng => _customerLng;
  double? get technicianLat => _technicianLat;
  double? get technicianLng => _technicianLng;
  String get serviceTitle => _serviceTitle;
  int get fee => _fee;
  bool get isUpgraded => _isUpgraded;
  TechnicianStatus get status => _status;
  int get etaMinutes => _etaMinutes;
  String? get arrivalOtp => _isOtpShared ? null : _arrivalOtp;
  bool get isOtpShared => _isOtpShared;
  bool get hasPendingArrivalOtp =>
      _arrivalOtp != null && _arrivalOtp!.trim().isNotEmpty && !_isOtpShared;
  bool get shouldShowOtp =>
      hasPendingArrivalOtp &&
      (_status == TechnicianStatus.arrived || _status == TechnicianStatus.onTheWay);

  /// True once technician presses "I Have Arrived" — verified (ARRIVED) or >150m away waiting for OTP confirmation.
  bool get isArrivedOrConfirmingOtp =>
      _status == TechnicianStatus.arrived ||
      isLocationMismatchArrival;

  bool get isLocationMismatchArrival =>
      _status == TechnicianStatus.onTheWay &&
      hasPendingArrivalOtp &&
      !_preArrivalOtpOnly;
  double? get distanceKm => _distanceKm;
  double? get distanceMeters => _distanceKm != null ? _distanceKm! * 1000 : null;
  bool get isAboutToReach => isEnRoute && ((_distanceKm != null && _distanceKm! <= 0.5) || _etaMinutes <= 3);

  String get technicianName => _technicianName;
  String get technicianPhone => _technicianPhone;
  String? get technicianBadge => _technicianBadge;
  String? get technicianPhotoUrl => _technicianPhotoUrl;
  String get cleanTechnicianPhone {
    final digits = _technicianPhone.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
  }
  double? get technicianRating => _technicianRating;
  int get technicianRatingCount => _technicianRatingCount;
  int? get completedJobs => _completedJobs;
  int? get customerRating => _customerRating;
  String? get customerReview => _customerReview;
  DateTime? get ratedAt => _ratedAt;
  String get customerAddress => _customerAddress;
  String get cleanCustomerAddress {
    if (_customerAddress.trim().isEmpty) return 'Doorstep Location';
    String addr = _customerAddress.trim();
    addr = addr.replaceAll(RegExp(r',\s*Bengaluru\s*\(\d{5,6}\)$', caseSensitive: false), '');
    addr = addr.replaceAll(RegExp(r',\s*Bangalore\s*\(\d{5,6}\)$', caseSensitive: false), '');
    addr = addr.replaceAll(RegExp(r'\bBengaluru,\s*Bengaluru\b', caseSensitive: false), 'Bengaluru');
    addr = addr.replaceAll(RegExp(r'\bBangalore,\s*Bangalore\b', caseSensitive: false), 'Bangalore');
    addr = addr.replaceAll(RegExp(r',\s*,'), ',');
    addr = addr.trim().replaceAll(RegExp(r'^,\s*|,\s*$'), '');
    return addr;
  }
  String? get receiverName => _receiverName;
  String? get receiverPhone => _receiverPhone;
  bool get isForSomeoneElse => _isForSomeoneElse;
  List<String> get checklist => List.unmodifiable(_checklist);

  String _rawStatus = 'REQUESTED';
  String get rawStatus => _rawStatus;
  bool get isWaitingForAcceptance => _status == TechnicianStatus.booked && _rawStatus == 'REQUESTED';
  bool get isOrderConfirmed => _status == TechnicianStatus.booked && (_rawStatus == 'ASSIGNED' || _rawStatus == 'ACCEPTED_CALLING_CUSTOMER');
  bool get isScheduledNextDay => _rawStatus == 'SCHEDULED_NEXT_DAY';
  bool get hasTechnicianAssigned =>
      !isWaitingForAcceptance &&
      !isScheduledNextDay &&
      _rawStatus != 'IDLE' &&
      _technicianName.trim().isNotEmpty &&
      _technicianName != 'Technician' &&
      _technicianName != 'Assigned Technician';

  String? _preferredTimeSlot;
  String _scheduledWindow = '06:00 AM - 07:00 PM';
  DateTime? _dispatchTimeoutAt;
  String? _cancelReason;
  String? _rescheduleReason;
  String? _activeQueueDate;
  Map<String, dynamic>? _mutualCancelRequest;

  String? get preferredTimeSlot => _preferredTimeSlot;
  String get scheduledWindow => _scheduledWindow;
  DateTime? get dispatchTimeoutAt => _dispatchTimeoutAt;
  String? get cancelReason => _cancelReason;
  String? get rescheduleReason => _rescheduleReason;
  String? get activeQueueDate => _activeQueueDate;
  Map<String, dynamic>? get mutualCancelRequest => _mutualCancelRequest;
  bool get hasMutualCancelRequest =>
      _mutualCancelRequest != null &&
      ((_mutualCancelRequest!['code']?.toString().trim().isNotEmpty ?? false) ||
          (_mutualCancelRequest!['reason']?.toString().trim().isNotEmpty ?? false));
  String? get mutualCancelCode => _mutualCancelRequest?['code']?.toString();
  String? get mutualCancelReason =>
      (_mutualCancelRequest?['display_reason'] ?? _mutualCancelRequest?['reason'])?.toString();

  bool get isBooked => _status == TechnicianStatus.booked;
  bool get isEnRoute => _status == TechnicianStatus.onTheWay;
  bool get isArrived => _status == TechnicianStatus.arrived;
  bool get isInService => _status == TechnicianStatus.inService;
  bool get isCompleted => _status == TechnicianStatus.completed;
  bool get isCancelled => _status == TechnicianStatus.cancelled;
  bool get hasActiveBooking =>
      _hasActiveBooking &&
      _status != TechnicianStatus.completed &&
      _status != TechnicianStatus.cancelled;

  /// Lifecycle Capability Helpers
  bool get isRouteMapActive => _status == TechnicianStatus.onTheWay || _status == TechnicianStatus.arrived;
  bool get canUpgradeAndBuySpares => _status == TechnicianStatus.inService;
  int get finalPayableAmount => _fee;
  String get finalPayableText => _fee == 0 ? 'FREE ₹0' : '₹$_fee';

  String get statusDisplay {
    switch (_status) {
      case TechnicianStatus.booked:
        if (_rawStatus == 'SCHEDULED_NEXT_DAY') {
          return 'Scheduled for Tomorrow ($_scheduledWindow)';
        }
        if (_rawStatus == 'REQUESTED') {
          return _preferredTimeSlot != null
              ? 'Slot Booked • $_preferredTimeSlot'
              : 'Slot Booked • Awaiting Technician';
        }
        final cleanName = DisplaySanitizer.technicianName(_technicianName, fallback: '');
        return cleanName.isNotEmpty ? 'Technician Assigned • $cleanName' : 'Technician Assigned';
      case TechnicianStatus.onTheWay:
        return isLocationMismatchArrival
            ? 'Technician Arrived • Share OTP to Confirm'
            : 'Arriving in $_etaMinutes mins • Live GPS';
      case TechnicianStatus.arrived:
        return 'Technician Arrived at Doorstep';
      case TechnicianStatus.inService:
        return 'Service & Diagnostics in Progress';
      case TechnicianStatus.completed:
        return 'Service Completed';
      case TechnicianStatus.cancelled:
        final reason = _cancelReason?.trim();
        return reason != null && reason.isNotEmpty
            ? 'Booking Cancelled • $reason'
            : 'Booking Cancelled';
    }
  }

  void setPreferredTimeSlot(String slot) {
    _preferredTimeSlot = slot;
    notifyListeners();
  }

  /// Customer books new doorstep service with preferred slot
  void bookNewService({
    required String address,
    String? receiverName,
    String? receiverPhone,
    bool isHappyHour = false,
    double? latitude,
    double? longitude,
    String? preferredSlot,
  }) {
    _bookingId = PhoneNormalizer.generateUniqueRef('ROP-SRV');
    _customerAddress = address;
    if (latitude != null) _customerLat = latitude;
    if (longitude != null) _customerLng = longitude;
    if (preferredSlot != null) _preferredTimeSlot = preferredSlot;
    _receiverName = receiverName?.trim().isNotEmpty == true ? receiverName!.trim() : null;
    _receiverPhone = receiverPhone?.trim().isNotEmpty == true ? receiverPhone!.trim() : null;
    _isForSomeoneElse = _receiverName != null;
    _fee = isHappyHour ? 0 : 49;
    _serviceTitle = isHappyHour
        ? 'Free Happy Hour RO Inspection'
        : 'Quick RO Inspection & Diagnostics';
    _isUpgraded = false;
    _status = TechnicianStatus.booked;
    _rawStatus = 'REQUESTED';
    _hasActiveBooking = true;
    _etaMinutes = 15;
    _isOtpShared = false;
    _preArrivalOtpOnly = false;
    _arrivalOtp = null; // Generated upon arrival
    notifyListeners();
  }

  /// 1-Tap Upgrade to Full Service (₹149)
  Future<bool> upgradeToFullService() async {
    if (_bookingId.trim().isEmpty) return false;

    final prevUpgraded = _isUpgraded;
    final prevFee = _fee;
    final prevTitle = _serviceTitle;
    _isUpgraded = true;
    _fee = 149;
    _serviceTitle = 'Full RO Service & Comprehensive Repair';
    notifyListeners();

    try {
      final res = await ApiService().upgradeServiceVisit(_bookingId);
      if (res['success'] == true) {
        return true;
      }
    } catch (e) {
      debugPrint('[ServiceTrackingState] upgradeServiceVisit error: $e');
    }

    _isUpgraded = prevUpgraded;
    _fee = prevFee;
    _serviceTitle = prevTitle;
    notifyListeners();
    return false;
  }

  void setCustomerAddress(String address) {
    _customerAddress = address;
    notifyListeners();
  }

  /// Marks arrival OTP verified locally after backend/tracking confirmation.
  void confirmArrival() {
    _status = TechnicianStatus.inService;
    _isOtpShared = true;
    _preArrivalOtpOnly = false;
    _arrivalOtp = null; // Deleted from DB
    notifyListeners();
  }

  void setBackendBookingId(String id) {
    _bookingId = id;
    notifyListeners();
  }

  void resetToIdle() {
    _status = TechnicianStatus.booked;
    _rawStatus = 'IDLE';
    _hasActiveBooking = false;
    _bookingId = '';
    _arrivalOtp = null;
    _isOtpShared = false;
    _preArrivalOtpOnly = false;
    _receiverPhone = null;
    _receiverName = null;
    _isForSomeoneElse = false;
    _technicianLat = null;
    _technicianLng = null;
    _distanceKm = null;
    _etaMinutes = 15;
    _isUpgraded = false;
    _fee = 49;
    _visitPurpose = 'STANDARD';
    _isFreeVisit = false;
    _serviceTitle = 'Quick RO Visit & Inspection';
    _technicianName = '';
    _technicianPhone = '';
    _technicianBadge = null;
    _technicianPhotoUrl = null;
    _technicianRating = null;
    _technicianRatingCount = 0;
    _completedJobs = null;
    _customerRating = null;
    _customerReview = null;
    _ratedAt = null;
    _customerAddress = '';
    _preferredTimeSlot = null;
    _dispatchTimeoutAt = null;
    _cancelReason = null;
    _rescheduleReason = null;
    _activeQueueDate = null;
    _mutualCancelRequest = null;
    notifyListeners();
  }

  Future<Map<String, dynamic>> _applyVisitMutation(
    Future<Map<String, dynamic>> Function(String id) action, {
    bool clearMutualCancel = false,
  }) async {
    final id = _bookingId.trim();
    if (id.isEmpty) {
      return {'success': false, 'message': 'No active booking found.'};
    }
    final res = await action(id);
    if (res['success'] == true) {
      if (clearMutualCancel) {
        _mutualCancelRequest = null;
      }
      final updatedVisit = res['visit'];
      if (updatedVisit is Map<String, dynamic>) {
        updateFromBackend(updatedVisit);
      } else if (updatedVisit is Map) {
        updateFromBackend(Map<String, dynamic>.from(updatedVisit));
      } else {
        notifyListeners();
      }
    }
    return res;
  }

  /// Respond to a technician-initiated mutual cancellation (APPROVE or REJECT)
  Future<Map<String, dynamic>> respondToMutualCancel({
    required String decision,
    String? reason,
  }) =>
      _applyVisitMutation(
        (id) => ApiService().respondToMutualCancel(
          id,
          decision: decision,
          reason: reason,
        ),
        clearMutualCancel: true,
      );

  /// Submit 1-5 star rating & optional review at visit completion
  Future<Map<String, dynamic>> submitVisitRating({
    required int rating,
    List<String> tags = const [],
    String? reviewText,
  }) async {
    final id = _bookingId.trim();
    if (id.isEmpty) {
      return {'success': false, 'message': 'No completed booking found to rate.'};
    }
    final res = await ApiService().rateServiceVisit(
      visitId: id,
      rating: rating,
      tags: tags,
      reviewText: reviewText,
    );
    if (res['success'] == true) {
      _customerRating = (res['customer_rating'] is int)
          ? res['customer_rating'] as int
          : rating;
      _ratedAt = DateTime.tryParse('${res['rated_at'] ?? ''}') ?? DateTime.now();
      final cleanReview = reviewText?.trim() ?? '';
      if (cleanReview.isNotEmpty) {
        _customerReview = cleanReview;
      }
      if (res['technician_stats'] is Map) {
        final stats = Map<String, dynamic>.from(res['technician_stats'] as Map);
        if (stats['rating_avg'] != null) {
          _technicianRating = double.tryParse('${stats['rating_avg']}');
        }
        if (stats['rating_count'] != null) {
          _technicianRatingCount =
              int.tryParse('${stats['rating_count']}') ?? _technicianRatingCount;
        }
        if (stats['completed_jobs_count'] != null) {
          _completedJobs =
              int.tryParse('${stats['completed_jobs_count']}') ?? _completedJobs;
        }
      }
      notifyListeners();
    }
    return res;
  }

  void updateFromBackend(Map<String, dynamic> visit) {
    if (visit['unchanged'] == true) return;
    _bookingId = (visit['id'] ?? visit['visit_id'] ?? _bookingId).toString();
    _customerAddress = visit['service_address']?.toString() ?? _customerAddress;
    final backendStatus = visit['status']?.toString();
    _hasActiveBooking = (backendStatus != null &&
        backendStatus != 'COMPLETED' &&
        backendStatus != 'CANCELLED' &&
        backendStatus != 'CANCELLED_NO_CUSTOMER_SHOW');
    _rawStatus = backendStatus ?? _rawStatus;
    _cancelReason = visit['cancel_reason']?.toString().trim();
    _rescheduleReason = visit['reschedule_reason']?.toString().trim();
    final rawQueueDate = (visit['active_queue_date'] ?? visit['scheduled_date'])?.toString().trim();
    if (rawQueueDate != null && rawQueueDate.isNotEmpty && rawQueueDate != 'null') {
      _activeQueueDate = rawQueueDate.length >= 10 ? rawQueueDate.substring(0, 10) : rawQueueDate;
    }
    final rawMutual = visit['mutual_cancel_request'];
    if (rawMutual is Map) {
      _mutualCancelRequest = Map<String, dynamic>.from(rawMutual);
    } else if (visit.containsKey('mutual_cancel_request') ||
        backendStatus == 'CANCELLED' ||
        backendStatus == 'CANCELLED_NO_CUSTOMER_SHOW' ||
        backendStatus == 'COMPLETED') {
      _mutualCancelRequest = null;
    }
    if (backendStatus == 'CANCELLED' || backendStatus == 'CANCELLED_NO_CUSTOMER_SHOW') {
      _status = TechnicianStatus.cancelled;
      _arrivalOtp = null;
      _isOtpShared = false;
      _preArrivalOtpOnly = false;
    } else if (backendStatus == 'REQUESTED' ||
        backendStatus == 'ASSIGNED' ||
        backendStatus == 'ACCEPTED_CALLING_CUSTOMER' ||
        backendStatus == 'SCHEDULED_NEXT_DAY') {
      _status = TechnicianStatus.booked;
      _arrivalOtp = null;
      _isOtpShared = false;
      _preArrivalOtpOnly = false;
    } else if (backendStatus == 'ON_THE_WAY') {
      _status = TechnicianStatus.onTheWay;
      _syncArrivalOtpFromVisit(visit);
    } else if (backendStatus == 'ARRIVED') {
      _status = TechnicianStatus.arrived;
      _syncArrivalOtpFromVisit(visit);
    } else if (backendStatus == 'IN_PROGRESS') {
      _status = TechnicianStatus.inService;
      _arrivalOtp = null;
      _isOtpShared = true;
      _preArrivalOtpOnly = false;
    } else if (backendStatus == 'COMPLETED') {
      _status = TechnicianStatus.completed;
      _arrivalOtp = null;
      _isOtpShared = true;
      _preArrivalOtpOnly = false;
    }
    if (visit['preferred_time_slot'] != null) {
      _preferredTimeSlot = visit['preferred_time_slot'].toString();
    }
    if (visit['scheduled_window'] != null) {
      _scheduledWindow = visit['scheduled_window'].toString();
    }
    if (visit['dispatch_timeout_at'] != null) {
      _dispatchTimeoutAt = DateTime.tryParse(visit['dispatch_timeout_at'].toString());
    }
    final hasExplicitUnassigned =
        visit.containsKey('assigned_technician_id') &&
        visit['assigned_technician_id'] == null;
    if (backendStatus == 'REQUESTED' || backendStatus == 'SCHEDULED_NEXT_DAY') {
      _technicianName = '';
      _technicianPhone = '';
      _technicianBadge = null;
      _technicianPhotoUrl = null;
      _technicianRating = null;
      _technicianRatingCount = 0;
    } else if (visit.containsKey('technician_name') ||
        visit.containsKey('technician_photo_url') ||
        visit.containsKey('profile_picture_url') ||
        visit.containsKey('technician_badge') ||
        visit.containsKey('assigned_technician_id') ||
        hasExplicitUnassigned) {
      if (visit['technician_name'] != null && visit['technician_name'].toString().trim().isNotEmpty) {
        _technicianName = DisplaySanitizer.technicianName(
          visit['technician_name'].toString(),
          fallback: '',
        );
      } else if (visit.containsKey('technician_name') || hasExplicitUnassigned) {
        _technicianName = '';
      }
      if (visit['technician_phone'] != null && visit['technician_phone'].toString().trim().isNotEmpty) {
        _technicianPhone = visit['technician_phone'].toString().trim();
      } else if (visit.containsKey('technician_phone') || hasExplicitUnassigned) {
        _technicianPhone = '';
      }
      final rawBadge =
          (visit['technician_badge'] ?? visit['assigned_technician_id'])
              ?.toString()
              .trim();
      if (rawBadge != null && rawBadge.isNotEmpty && rawBadge != 'null') {
        _technicianBadge = rawBadge;
      } else if (hasExplicitUnassigned) {
        _technicianBadge = null;
      }
      if (visit.containsKey('technician_photo_url') ||
          visit.containsKey('profile_picture_url') ||
          hasExplicitUnassigned) {
        final rawPhoto =
            (visit['technician_photo_url'] ?? visit['profile_picture_url'])
                ?.toString()
                .trim();
        _technicianPhotoUrl =
            (rawPhoto != null && rawPhoto.isNotEmpty && rawPhoto != 'null')
                ? rawPhoto
                : null;
      }
    }
    final rawPurpose = visit['visit_purpose']?.toString().trim().toUpperCase();
    if (rawPurpose != null && rawPurpose.isNotEmpty) {
      _visitPurpose = rawPurpose;
    } else if (visit['is_free_visit'] == true) {
      _visitPurpose = 'FREE_VISIT';
    } else if (visit.containsKey('visit_purpose')) {
      _visitPurpose = 'STANDARD';
    }
    if (visit.containsKey('is_free_visit') || rawPurpose != null) {
      _isFreeVisit = visit['is_free_visit'] == true ||
          _visitPurpose == 'FREE_VISIT' ||
          _visitPurpose == 'FREE_REVISIT';
    }

    final rawFee = visit['labor_fee'] ?? visit['service_charge'];
    if (rawFee != null) {
      final parsedFee = double.tryParse(rawFee.toString())?.toInt();
      if (parsedFee != null && parsedFee >= 0) {
        _fee = parsedFee;
        if (_fee >= 149 || visit['service_type'] == 'COMPLETE_SERVICE') {
          _isUpgraded = true;
          _serviceTitle = 'Full RO Service & Comprehensive Repair';
        }
      }
    }
    if (!_isUpgraded) {
      if (_visitPurpose == 'FREE_REVISIT') {
        _serviceTitle = 'Free Technician Revisit (₹0)';
      } else if (_visitPurpose == 'FREE_VISIT' || _isFreeVisit) {
        _serviceTitle = 'Free Special Visit (₹0)';
      }
    }
    final rawRating = visit['technician_rating'];
    _technicianRating = rawRating != null ? double.tryParse('$rawRating') : null;
    final rawRatingCount = visit['technician_rating_count'];
    _technicianRatingCount =
        rawRatingCount != null ? (int.tryParse('$rawRatingCount') ?? 0) : 0;
    final rawJobs = visit['technician_completed_jobs'] ?? visit['completed_jobs'];
    _completedJobs = rawJobs != null ? int.tryParse('$rawJobs') : null;

    if (visit.containsKey('customer_rating')) {
      final rawCustRating = visit['customer_rating'];
      _customerRating =
          rawCustRating != null ? int.tryParse('$rawCustRating') : null;
    }
    if (visit.containsKey('rated_at')) {
      final rawRatedAt = visit['rated_at']?.toString().trim();
      _ratedAt = (rawRatedAt != null && rawRatedAt.isNotEmpty && rawRatedAt != 'null')
          ? DateTime.tryParse(rawRatedAt)
          : null;
    }

    final recPhone = visit['receiver_phone']?.toString().trim();
    _receiverPhone = (recPhone != null && recPhone.isNotEmpty) ? recPhone : null;
    final recName = visit['receiver_name']?.toString().trim();
    if (recName != null && recName.isNotEmpty) {
      _receiverName = recName;
      _isForSomeoneElse = true;
    }

    if (visit['service_latitude'] != null) {
      final parsed = double.tryParse('${visit['service_latitude']}');
      if (parsed != null && parsed != 0.0) _customerLat = parsed;
    }
    if (visit['service_longitude'] != null) {
      final parsed = double.tryParse('${visit['service_longitude']}');
      if (parsed != null && parsed != 0.0) _customerLng = parsed;
    }
    final rawTechLat = visit['current_latitude'] ?? visit['technician_latitude'];
    final rawTechLng = visit['current_longitude'] ?? visit['technician_longitude'];
    final parsedTechLat = rawTechLat != null ? double.tryParse('$rawTechLat') : null;
    final parsedTechLng = rawTechLng != null ? double.tryParse('$rawTechLng') : null;
    if (parsedTechLat != null && parsedTechLat != 0.0 && parsedTechLng != null && parsedTechLng != 0.0) {
      _technicianLat = parsedTechLat;
      _technicianLng = parsedTechLng;
    } else {
      _technicianLat = null;
      _technicianLng = null;
      _distanceKm = null;
    }

    // Dynamic real ETA calculation based on real distance
    if (_technicianLat != null && _technicianLng != null) {
      final distKm = _calculateDistanceKm(_technicianLat!, _technicianLng!, _customerLat, _customerLng);
      _distanceKm = distKm;
      if (distKm < 0.1) {
        _etaMinutes = 1;
      } else {
        _etaMinutes = (distKm * 3.0 + 2.0).ceil().clamp(1, 45);
      }
    }

    notifyListeners();
  }

  void _syncArrivalOtpFromVisit(Map<String, dynamic> visit) {
    final rawOtp = visit['arrival_otp']?.toString().trim();
    if (rawOtp != null && rawOtp.isNotEmpty && rawOtp != 'null') {
      _arrivalOtp = rawOtp;
      _isOtpShared = false;
      _preArrivalOtpOnly = visit.containsKey('arrival_otp_requested') &&
          visit['arrival_otp_requested'] != true;
    } else if (visit.containsKey('arrival_otp')) {
      _arrivalOtp = null;
      _isOtpShared = false;
      _preArrivalOtpOnly = false;
    }
  }

  double _calculateDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    final a = 0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lon2 - lon1) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a));
  }
}
