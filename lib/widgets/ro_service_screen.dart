import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/user_address.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import '../utils/display_sanitizer.dart';
import '../utils/happy_hour_helper.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';
import 'auth_sheet.dart';
import 'map_address_picker_sheet.dart';
import 'service_history_sheet.dart';
import 'zone_support_chat_sheet.dart';

class RoServiceScreen extends StatefulWidget {
  final String initialPincode;
  final Function(Map<String, String> bookingData)? onBookSuccess;
  final ServiceTrackingState? serviceState;
  final VoidCallback? onTrackTap;
  final CartState? cartState;

  const RoServiceScreen({
    super.key,
    this.initialPincode = '560034',
    this.onBookSuccess,
    this.serviceState,
    this.onTrackTap,
    this.cartState,
  });

  @override
  State<RoServiceScreen> createState() => _RoServiceScreenState();
}

class _RoServiceScreenState extends State<RoServiceScreen> {
  final ScrollController _scrollController = ScrollController();

  // Form Controllers
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _streetController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  late final TextEditingController _pincodeController;
  final TextEditingController _landmarkController = TextEditingController();
  final TextEditingController _referralController = TextEditingController();

  // Receiver Controllers (When booking for someone else)
  final TextEditingController _receiverNameController = TextEditingController();
  final TextEditingController _receiverPhoneController = TextEditingController();
  bool _isBookingForSomeoneElse = false;

  // Mandatory Form Field Validation Errors (Highlighted in Red)
  bool _highlightErrors = false;
  String? _receiverNameError;
  String? _receiverPhoneError;
  String? _addressError;

  // Address Book Integration
  UserAddress? _selectedAddress;
  bool _forceShowNewBooking = false;

  // Referral State
  bool _showReferralInput = false;
  bool _isReferralApplied = false;
  bool _isApplyingReferral = false;
  bool _isBooking = false;
  String? _appliedPromoCode;
  double? _promoNetPayable;
  String? _referralMessage;

  int get _baseVisitFee => HappyHourHelper.currentInspectionFee;

  int get _effectiveVisitFee => HappyHourHelper.isHappyHourLive()
      ? 0
      : (_isReferralApplied && _promoNetPayable != null
          ? _promoNetPayable!.round()
          : _baseVisitFee);

  bool get _isVisitFree => _effectiveVisitFee <= 0;

  // Booking Status State
  bool _isSubmitting = false;
  bool _isServiceDetailsExpanded = false;
  bool _hasCheckedProximity = false;
  bool _userDismissedProximityAlert = false;

  @override
  void initState() {
    super.initState();
    _pincodeController = TextEditingController(text: widget.cartState?.deliveryPincode ?? widget.initialPincode);
    widget.cartState?.addListener(_onCartStateChanged);

    // Auto-fetch and pre-populate from address book
    final activeAddr = widget.cartState?.activeAddress;
    if (activeAddr != null) {
      _selectedAddress = activeAddr;
      _streetController.text = activeAddr.fullAddress;
      _cityController.text = activeAddr.city;
      _pincodeController.text = activeAddr.pincode;
      _landmarkController.text = activeAddr.landmark;
    } else {
      _cityController.text = widget.cartState?.deliveryCity ?? '';
    }

    // Pre-populate customer name and phone
    if (_nameController.text.isEmpty && widget.cartState?.userName.isNotEmpty == true) {
      _nameController.text = widget.cartState!.userName;
    }
    if (_phoneController.text.isEmpty && widget.cartState?.userPhone.isNotEmpty == true) {
      _phoneController.text = widget.cartState!.userPhone;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLocationProximityOnOpen();
    });
  }

  Future<void> _checkLocationProximityOnOpen() async {
    if (_hasCheckedProximity || !mounted) return;
    _hasCheckedProximity = true;

    final activeAddr = _selectedAddress ?? widget.cartState?.activeAddress;
    if (activeAddr == null || activeAddr.latitude == 0.0 || activeAddr.longitude == 0.0) return;

    final pos = await widget.cartState?.getCurrentOrCachedPosition(requestPermission: false);
    if (pos == null || !mounted) return;

    final dist = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      activeAddr.latitude,
      activeAddr.longitude,
    );

    // If customer is > 50 meters away from their saved address (e.g. at work or traveling)
    if (dist > 50) {
      _showNewLocationDetectedSheet(
        currentPos: pos,
        distanceMeters: dist,
        currentSavedAddr: activeAddr,
        onConfirmed: () {
          _userDismissedProximityAlert = true;
          if (mounted) setState(() {});
        },
      );
    }
  }

  void _onCartStateChanged() {
    if (!mounted) return;
    final active = widget.cartState?.activeAddress;
    if (active != null && active.id != _selectedAddress?.id) {
      _applySelectedAddress(active);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.cartState?.removeListener(_onCartStateChanged);
    _scrollController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _streetController.dispose();
    _cityController.dispose();
    _pincodeController.dispose();
    _landmarkController.dispose();
    _referralController.dispose();
    _receiverNameController.dispose();
    _receiverPhoneController.dispose();
    super.dispose();
  }

  Future<void> _openZoneSupportChat() async {
    final activeState = widget.serviceState;
    final hasActive = activeState != null && activeState.hasActiveBooking;
    await showZoneSupportChatSheet(
      context,
      visitId: hasActive ? activeState.bookingId : null,
      issueType: 'BOOKING_SUPPORT',
      lat: _selectedAddress?.latitude ?? (hasActive ? activeState.customerLat : null),
      lng: _selectedAddress?.longitude ?? (hasActive ? activeState.customerLng : null),
      cartState: widget.cartState,
      quickPrompts: const <String>[
        'Check service availability in my area',
        'Happy Hour (₹0) slot question',
        'Reschedule or modify my RO service',
        'Ask Zone Manager for technician help',
      ],
    );
  }


  void _applySelectedAddress(UserAddress addr) {
    setState(() {
      _selectedAddress = addr;
      _addressError = null;
      _highlightErrors = false;
      _streetController.text = addr.fullAddress;
      _cityController.text = addr.city;
      _pincodeController.text = addr.pincode;
      _landmarkController.text = addr.landmark;
    });
  }

  void _openAddressSelector() {
    final addresses = widget.cartState?.addresses ?? [];
    if (addresses.isEmpty) {
      if (widget.cartState != null) {
        _openMapTuneLocation();
      } else {
        _showToast('No saved addresses found. Please enter your address below.');
      }
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Select Delivery Address',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...addresses.map((addr) {
                    final isSelected = _selectedAddress?.id == addr.id;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Material(
                        color: isSelected ? const Color(0xFFEFF6FF) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFFDBEAFE) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              addr.tag == 'Home'
                                  ? Icons.home_rounded
                                  : (addr.tag == 'Work' ? Icons.work_outline_rounded : Icons.location_on_rounded),
                              color: isSelected ? const Color(0xFF0284C7) : const Color(0xFF64748B),
                              size: 20,
                            ),
                          ),
                          title: Text(
                            addr.flatNo.isNotEmpty ? '${addr.tag} • ${addr.flatNo}' : addr.tag,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0F172A)),
                          ),
                          subtitle: Text(
                            '${addr.streetArea}, ${addr.city} (${addr.pincode})',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle_rounded, color: Color(0xFF0284C7), size: 20)
                              : null,
                          onTap: () {
                            Navigator.pop(ctx);
                            _applySelectedAddress(addr);
                          },
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  if (addresses.length < 5) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF0284C7),
                          side: const BorderSide(color: Color(0xFF0284C7)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.add_location_alt_rounded, size: 16),
                        label: const Text('+ Add New Address on Map', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openMapTuneLocation(null);
                        },
                      ),
                    ),
                  ] else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Address Limit Reached (5/5). Edit or delete an address to add a new one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMapTuneLocation([UserAddress? address, VoidCallback? onAddressSaved]) async {
    if (widget.cartState == null) return;
    final savedAddr = await showModalBottomSheet<UserAddress>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MapAddressPickerSheet(
        cartState: widget.cartState!,
        initialAddress: address,
        autoLocate: address == null,
        requireDoorstepServiceability: true,
      ),
    );
    if (mounted && (savedAddr != null || widget.cartState?.activeAddress != null)) {
      _applySelectedAddress(savedAddr ?? widget.cartState!.activeAddress!);
      onAddressSaved?.call();
    }
  }

  void _openLoginSheet() {
    if (widget.cartState != null) {
      AuthSheet.show(
        context,
        cartState: widget.cartState!,
        onAuthSuccess: () {
          if (mounted) {
            setState(() {
              if (_nameController.text.isEmpty && widget.cartState!.userName.isNotEmpty) {
                _nameController.text = widget.cartState!.userName;
              }
              if (_phoneController.text.isEmpty && widget.cartState!.userPhone.isNotEmpty) {
                _phoneController.text = widget.cartState!.userPhone;
              }
            });
          }
        },
      );
    }
  }

  Future<void> _applyReferral() async {
    final code = _referralController.text.trim().toUpperCase();
    if (code.isEmpty || _isApplyingReferral) return;

    final baseFee = _baseVisitFee.toDouble();
    final customerId = PhoneNormalizer.toCustomerId(
      widget.cartState?.customerId ?? widget.cartState?.userPhone ?? '',
    );

    setState(() {
      _isApplyingReferral = true;
      _referralMessage = null;
    });

    final res = await ApiService().validateCoupon(
      code: code,
      channel: 'ALL',
      amount: baseFee,
      mrp: baseFee,
      customerId: customerId.isEmpty ? null : customerId,
    );

    if (!mounted) return;
    setState(() {
      _isApplyingReferral = false;
      if (res['success'] == true) {
        final netPayable =
            double.tryParse(res['net_payable']?.toString() ?? '') ?? baseFee;
        _isReferralApplied = true;
        _appliedPromoCode = code;
        _promoNetPayable = netPayable;
        _referralMessage = netPayable <= 0
            ? 'Code $code applied! Visit fee waived (₹0)'
            : 'Code $code applied! Visit fee ₹${netPayable.round()}';
      } else {
        _isReferralApplied = false;
        _appliedPromoCode = null;
        _promoNetPayable = null;
        _referralMessage = res['error']?.toString() ??
            res['message']?.toString() ??
            'Invalid or ineligible promo code';
      }
    });
  }

  void _submitBooking() async {
    final isLoggedIn = widget.cartState?.isLoggedIn ?? true;
    if (!isLoggedIn) {
      _openLoginSheet();
      return;
    }

    final userName = widget.cartState?.userName.isNotEmpty == true
        ? widget.cartState!.userName
        : (_nameController.text.trim().isNotEmpty ? _nameController.text.trim() : 'Valued Customer');
    final userPhone = widget.cartState?.userPhone.isNotEmpty == true
        ? widget.cartState!.userPhone
        : _phoneController.text.trim();

    setState(() {
      _receiverNameError = null;
      _receiverPhoneError = null;
      _addressError = null;
    });

    if (_isBookingForSomeoneElse) {
      bool hasErr = false;
      if (_receiverNameController.text.trim().isEmpty) {
        _receiverNameError = "Receiver's full name is required *";
        hasErr = true;
      }
      if (_receiverPhoneController.text.trim().length < 10) {
        _receiverPhoneError = "Valid 10-digit mobile number is required *";
        hasErr = true;
      }
      if (hasErr) {
        setState(() => _highlightErrors = true);
        _showToast(_receiverNameError ?? _receiverPhoneError ?? "Required fields missing *");
        return;
      }
    }

    String street = _streetController.text.trim();
    String city = _cityController.text.trim();
    String pincode = _pincodeController.text.trim();

    if (_selectedAddress == null) {
      final active = widget.cartState?.activeAddress;
      if (active != null) {
        _selectedAddress = active;
      }
    }

    if (_selectedAddress != null) {
      street = _selectedAddress!.fullAddress;
      city = _selectedAddress!.city;
      pincode = _selectedAddress!.pincode;

      if (!_selectedAddress!.hasValidDoorstep) {
        setState(() => _highlightErrors = true);
        _openMapTuneLocation(_selectedAddress);
        _showToast('House / Flat number is required *');
        return;
      }
    } else {
      setState(() => _highlightErrors = true);
      _openMapTuneLocation(null);
      _showToast('Please pinpoint your doorstep on map so technician reaches directly');
      return;
    }

    if (street.isEmpty) {
      setState(() => _highlightErrors = true);
      _openMapTuneLocation(null);
      _showToast('Please pinpoint your doorstep on map');
      return;
    }
    if (city.isEmpty) {
      _showToast('Please enter your city');
      return;
    }
    if (pincode.isEmpty || pincode.length < 6) {
      _showToast('Please enter a valid 6-digit pincode');
      return;
    }

    // Show loading animation on button ONLY during async checks / slow network (0ms artificial wait)
    setState(() => _isSubmitting = true);

    try {
      // MANDATORY REAL-TIME GEOFENCE SERVICEABILITY CHECK
      if (_selectedAddress != null) {
        try {
          final servRes = await ApiService().checkServiceability(
            latitude: _selectedAddress!.latitude,
            longitude: _selectedAddress!.longitude,
            pincode: _selectedAddress!.pincode,
          );
          if (servRes['serviceable'] != true) {
            if (mounted) {
              setState(() => _isSubmitting = false);
              _showToast(servRes['message'] ?? 'This doorstep address is outside our serviceable operational area.');
              _openMapTuneLocation(_selectedAddress);
            }
            return;
          }
        } catch (e) {
          debugPrint('Pre-check serviceability exception: $e');
        }
      }


      final finalReceiverName = _isBookingForSomeoneElse ? _receiverNameController.text.trim() : userName;
      final finalReceiverPhone = _isBookingForSomeoneElse ? _receiverPhoneController.text.trim() : userPhone;

      // STEP 1: Proximity Check (> 50 meters) before opening slot sheet
      final activeAddr = _selectedAddress ?? widget.cartState?.activeAddress;
      if (!_userDismissedProximityAlert && activeAddr != null && activeAddr.latitude != 0.0 && activeAddr.longitude != 0.0) {
        final currentPos = await widget.cartState?.getCurrentOrCachedPosition(requestPermission: true);

        if (currentPos != null) {
          final dist = Geolocator.distanceBetween(
            currentPos.latitude,
            currentPos.longitude,
            activeAddr.latitude,
            activeAddr.longitude,
          );

          if (dist > 50) {
            if (!mounted) return;
            setState(() => _isSubmitting = false);
            _showNewLocationDetectedSheet(
              currentPos: currentPos,
              distanceMeters: dist,
              currentSavedAddr: activeAddr,
              onConfirmed: () {
                _userDismissedProximityAlert = true;
                _openSlotSelectionSheet(
                  street: _selectedAddress?.fullAddress ?? street,
                  city: _selectedAddress?.city ?? city,
                  pincode: _selectedAddress?.pincode ?? pincode,
                  userName: userName,
                  userPhone: userPhone,
                  finalReceiverName: finalReceiverName,
                  finalReceiverPhone: finalReceiverPhone,
                );
              },
            );
            return;
          }
        }
      }

      if (mounted) setState(() => _isSubmitting = false);
      _openSlotSelectionSheet(
        street: street,
        city: city,
        pincode: pincode,
        userName: userName,
        userPhone: userPhone,
        finalReceiverName: finalReceiverName,
        finalReceiverPhone: finalReceiverPhone,
      );
    } catch (e) {
      debugPrint('[ROService] Booking pre-flight error: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showNewLocationDetectedSheet({
    required Position currentPos,
    required double distanceMeters,
    required UserAddress currentSavedAddr,
    required VoidCallback onConfirmed,
  }) {
    String detectedArea = 'Detecting current area...';
    String detectedCity = '';
    String detectedPincode = '';
    bool isReverseGeocoding = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          if (isReverseGeocoding) {
            ApiService().reverseGeocode(currentPos.latitude, currentPos.longitude).then((geo) {
              if (ctx.mounted) {
                setSheetState(() {
                  detectedArea = geo['area'] ?? geo['formattedAddress'] ?? 'Current Location';
                  detectedCity = (geo['city'] ?? '').toString().trim();
                  detectedPincode = (geo['pincode'] ?? '').toString().trim();
                  isReverseGeocoding = false;
                });
              }
            }).catchError((err) {
              debugPrint('[ProximitySheet] Reverse geocode error: $err');
              if (ctx.mounted) {
                setSheetState(() {
                  detectedArea = 'Current Location';
                  isReverseGeocoding = false;
                });
              }
            });
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCBD5E1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.near_me_rounded,
                            color: Color(0xFFD97706),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '📍 New Location Detected (${distanceMeters.round()}m away)',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              Text(
                                "You appear to be away from saved address '${currentSavedAddr.tag}'",
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Detected GPS Area card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.gps_fixed_rounded, color: Color(0xFF16A34A), size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isReverseGeocoding
                                  ? 'Detecting current area...'
                                  : [
                                      detectedArea,
                                      detectedCity,
                                      detectedPincode,
                                    ]
                                      .where((s) => s.trim().isNotEmpty)
                                      .join(', '),
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF166534)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    const Text(
                      'Would you like to book for your saved address or pin this new location on the map?',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF64748B),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () {
                              _userDismissedProximityAlert = true;
                              Navigator.pop(ctx);
                              onConfirmed();
                            },
                            child: Text(
                              "Use '${currentSavedAddr.tag}' Anyway",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0F766E),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () {
                              _userDismissedProximityAlert = true;
                              Navigator.pop(ctx);
                              _openMapTuneLocation(null, onConfirmed);
                            },
                            icon: const Icon(Icons.map_rounded, size: 16),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Pin on Map & Book',
                                maxLines: 1,
                                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openSlotSelectionSheet({
    required String street,
    required String city,
    required String pincode,
    required String userName,
    required String userPhone,
    required String finalReceiverName,
    required String finalReceiverPhone,
  }) {
    final isHappyHour = HappyHourHelper.isHappyHourLive();
    final effectiveFee = _effectiveVisitFee;
    final isFree = _isVisitFree;

    String selectedDay = 'Tomorrow';
    String selectedSlot = '08:00 AM - 11:00 AM';
    final availableSlots = [
      '08:00 AM - 11:00 AM',
      '11:00 AM - 02:00 PM',
      '02:00 PM - 05:00 PM',
    ];

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.90),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCBD5E1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isFree ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isFree ? Icons.celebration_rounded : Icons.verified_user_rounded,
                            color: isFree ? const Color(0xFF16A34A) : const Color(0xFF0284C7),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Book Technician Slot',
                                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                              ),
                              Text(
                                'Zero Advance • Pay After Doorstep Service',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Service Time Slot Picker
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.access_time_rounded, size: 16, color: Color(0xFF0F766E)),
                              SizedBox(width: 6),
                              Text(
                                'Select Preferred Time Slot',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Next-Day Schedule Banner (Option A: Next Day Slots Only)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F766E).withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF0F766E).withValues(alpha: 0.25)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.event_available_rounded, size: 16, color: Color(0xFF0F766E)),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Tomorrow (Next Day Slot)',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F766E),
                                    ),
                                  ),
                                ),
                                Text(
                                  'MORNING RUN-SHEET',
                                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFF0F766E)),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Slot Chips
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: availableSlots.map((slot) {
                              final isSelected = selectedSlot == slot;
                              return GestureDetector(
                                onTap: () => setModalState(() => selectedSlot = slot),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFF0F766E).withValues(alpha: 0.12) : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSelected ? const Color(0xFF0F766E) : const Color(0xFFE2E8F0),
                                      width: isSelected ? 1.5 : 1.0,
                                    ),
                                  ),
                                  child: Text(
                                    slot,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                                      color: isSelected ? const Color(0xFF0F766E) : const Color(0xFF334155),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Transparent Fee Breakdown Box
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text('Quick Service & Inspection Fee:', style: TextStyle(fontSize: 12.5, color: Color(0xFF334155), fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isFree ? 'FREE ₹0' : '₹$effectiveFee',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  color: isFree ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text('Advance Payment Required Now:', style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B))),
                              ),
                              SizedBox(width: 8),
                              Text('₹0', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF16A34A))),
                            ],
                          ),
                          const Divider(height: 18, color: Color(0xFFE2E8F0)),
                          Row(
                            children: [
                              const Icon(Icons.info_outline, size: 15, color: Color(0xFF0284C7)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  isFree
                                      ? (isHappyHour
                                          ? '🎉 Free Hour Active! Quick service & inspection are 100% Free (₹0). Standard service charges will apply for complete servicing, major overhauls, or replacement parts.'
                                          : '🎉 Promo Applied! Quick service & inspection are 100% Free (₹0). Standard service charges apply for complete servicing or replacement parts.')
                                      : 'Pay ₹$effectiveFee in Cash or UPI only AFTER the technician inspects & sanitizes your RO at doorstep.',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600, height: 1.3),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Doorstep Address Preview
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on_outlined, color: Color(0xFF0284C7), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Doorstep: $street, $city ($pincode)',
                                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isBookingForSomeoneElse
                                      ? 'Receiver: $finalReceiverName ($finalReceiverPhone)'
                                      : 'Customer: $userName ($userPhone)',
                                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Actions: Cancel vs Confirm
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF64748B),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isFree ? const Color(0xFF16A34A) : const Color(0xFF0F766E),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: _isBooking
                                ? null
                                : () {
                                    Navigator.pop(ctx);
                                    _performConfirmedBooking(
                                      street: street,
                                      city: city,
                                      pincode: pincode,
                                      userName: userName,
                                      userPhone: userPhone,
                                      finalReceiverName: finalReceiverName,
                                      finalReceiverPhone: finalReceiverPhone,
                                      isHappyHour: isHappyHour,
                                      isFree: isFree,
                                      preferredSlot: '$selectedDay, $selectedSlot',
                                    );
                                  },
                            child: Text(
                              isFree ? 'Confirm Slot (FREE ₹0)' : 'Confirm Slot (Pay ₹$effectiveFee)',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _performConfirmedBooking({
    required String street,
    required String city,
    required String pincode,
    required String userName,
    required String userPhone,
    required String finalReceiverName,
    required String finalReceiverPhone,
    required bool isHappyHour,
    required bool isFree,
    String? preferredSlot,
  }) async {
    if (_isBooking) return;

    final fullAddress = _selectedAddress != null
        ? _selectedAddress!.fullAddress
        : (street.contains(pincode)
            ? street
            : [street, _landmarkController.text.trim(), '$city - $pincode']
                .where((s) => s.trim().isNotEmpty)
                .join(', '));

    final rawLat = _selectedAddress?.latitude ?? widget.cartState?.activeAddress?.latitude;
    final rawLng = _selectedAddress?.longitude ?? widget.cartState?.activeAddress?.longitude;
    final double? lat = (rawLat != null && rawLat != 0.0) ? rawLat : null;
    final double? lng = (rawLng != null && rawLng != 0.0) ? rawLng : null;
    final messenger = ScaffoldMessenger.of(context);
    final resolvedCustomerId = PhoneNormalizer.toCustomerId(
      widget.cartState?.customerId ?? userPhone,
    );

    setState(() => _isBooking = true);

    try {
      final res = await ApiService().bookServiceVisit(
        phone: finalReceiverPhone,
        customerId: resolvedCustomerId.isNotEmpty ? resolvedCustomerId : null,
        fullName: finalReceiverName,
        address: fullAddress,
        pincode: pincode,
        latitude: lat,
        longitude: lng,
        preferredSlot: preferredSlot,
        promoCode: _isReferralApplied ? _appliedPromoCode : null,
      );
      if (!mounted) return;

      if (res['success'] == true && res['visit_id'] != null) {
        widget.serviceState?.bookNewService(
          address: fullAddress,
          receiverName: finalReceiverName,
          receiverPhone: finalReceiverPhone,
          isHappyHour: isHappyHour,
          latitude: lat,
          longitude: lng,
          preferredSlot: preferredSlot,
        );
        widget.serviceState?.setBackendBookingId(res['visit_id'].toString());
        if (res['visit'] is Map<String, dynamic>) {
          widget.serviceState?.updateFromBackend(res['visit'] as Map<String, dynamic>);
        }
        widget.onBookSuccess?.call({
          'name': finalReceiverName,
          'phone': finalReceiverPhone,
          'address': fullAddress,
        });
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Slot confirmed: ${preferredSlot ?? "Booked"}. Live tracking active!'),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF0F766E),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      } else if (res['error'] == 'ACTIVE_VISIT_EXISTS' && res['active_visit'] is Map<String, dynamic>) {
        widget.serviceState?.updateFromBackend(res['active_visit'] as Map<String, dynamic>);
        messenger.showSnackBar(
          const SnackBar(
            content: Text('You already have an active service visit. Opening live status.'),
            backgroundColor: Color(0xFFD97706),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        final errMsg = res['message']?.toString() ?? res['error']?.toString() ?? 'Could not confirm booking. Please try again.';
        messenger.showSnackBar(
          SnackBar(
            content: Text(errMsg),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[ROService] Booking network error: $e');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Network error while booking service. Please try again.'),
            backgroundColor: Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isBooking = false);
      }
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openServiceHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ServiceHistorySheet(
        serviceState: widget.serviceState,
        cartState: widget.cartState,
        onBookServiceTap: () => Navigator.pop(ctx),
        onTrackServiceTap: widget.onTrackTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isHappyHour = _isVisitFree;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Book Doorstep RO Service',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded, size: 22, color: Color(0xFF0284C7)),
            tooltip: 'Service History',
            onPressed: _openServiceHistory,
          ),
          IconButton(
            icon: const Icon(Icons.chat_outlined, size: 20, color: Color(0xFF16A34A)),
            tooltip: 'Chat with Zone Support Desk',
            onPressed: _openZoneSupportChat,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. ACTIVE TECHNICIAN LIVE TRACKING & SETTLEMENT CARD
              if (widget.serviceState != null && widget.serviceState!.hasActiveBooking && !_forceShowNewBooking) ...[
                _buildActiveTrackingCard(),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFF0284C7), size: 20),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'You have an active technician booking in progress.',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _forceShowNewBooking = true),
                        child: const Text('Book Another', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // 2. CONSOLIDATED SERVICE SUMMARY CARD
                _buildServiceSummaryCard(isHappyHour),
                const SizedBox(height: 14),

                // 3. DOORSTEP ADDRESS CARD
                _buildAddressCard(),
                const SizedBox(height: 14),

                // 4. CUSTOMER / RECEIVER CONTACT CARD
                _buildContactCard(),
                const SizedBox(height: 14),

                // 5. COD PAYMENT MODE CARD
                _buildPaymentCard(isHappyHour),
                const SizedBox(height: 12),

                // 6. PROMO / REFERRAL SECTION
                _buildReferralSection(),
                const SizedBox(height: 16),

                // 7. 1-TAP CONFIRM BOOKING BUTTON
                _buildBookingButton(isHappyHour),
                const SizedBox(height: 16),
              ],

              // 8. TRUST BADGE
              const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_user_outlined, size: 14, color: Color(0xFF64748B)),
                    SizedBox(width: 5),
                    Text(
                      'Verified Technicians • Genuine Factory Parts',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Helper Widgets ---

  Widget _buildActiveTrackingCard() {
    return AnimatedBuilder(
      animation: widget.serviceState!,
      builder: (context, _) {
        final sState = widget.serviceState!;
        final isBooked = sState.isBooked;
        final isArrived = sState.isArrived || sState.isInService;
        final isCompleted = sState.isCompleted;

        // Requirement: Service history belongs in Service History page, NOT in booking page!
        if (isCompleted) {
          return const SizedBox.shrink();
        }

        // STEP 2: WAITING FOR TECHNICIAN CONFIRMATION CARD (Pending Acceptance)
        if (isBooked) {
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFBAE6FD), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 3)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_rounded, size: 11, color: Color(0xFF16A34A)),
                          const SizedBox(width: 4),
                          Text(
                            sState.rawStatus == 'ASSIGNED' ? 'TECHNICIAN ASSIGNED' : 'SLOT BOOKED',
                            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'Doorstep Service',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  sState.rawStatus == 'ASSIGNED'
                      ? 'Technician Assigned • ${DisplaySanitizer.technicianName(sState.technicianName)}'
                      : (sState.preferredTimeSlot != null
                          ? 'Slot: ${sState.preferredTimeSlot}'
                          : 'Service Slot Booked'),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 3),
                Text(
                  sState.rawStatus == 'ASSIGNED'
                      ? 'Your technician will call before arrival. Live GPS map will activate when they start travelling to your doorstep.'
                      : 'Slot confirmed. Our team is assigning a certified technician. Live tracking activates once technician starts travelling.',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B), height: 1.3),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F766E),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.calendar_month_rounded, size: 16),
                    label: const Text('View Slot Details & Tracking', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                    onPressed: () {
                      if (widget.onTrackTap != null) {
                        widget.onTrackTap!();
                      } else {
                        Navigator.pop(context);
                      }
                    },
                  ),
                ),
              ],
            ),
          );
        }

        // STEP 3 & STEP 4: EN ROUTE / AT DOORSTEP CARD
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isArrived ? const Color(0xFFF59E0B) : const Color(0xFFBAE6FD),
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 3)),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isArrived ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isArrived ? 'AT DOORSTEP' : 'EN ROUTE (${sState.etaMinutes} MIN)',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: isArrived ? const Color(0xFF16A34A) : const Color(0xFF0284C7),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Flexible(
                          child: Text(
                            'Doorstep Service',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sState.finalPayableText,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                sState.serviceTitle,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 2),
              Text(
                sState.hasTechnicianAssigned
                    ? (sState.technicianRating != null
                        ? 'Technician: ${sState.technicianName} (${sState.technicianRating!.toStringAsFixed(1)}★)'
                        : 'Technician: ${sState.technicianName}')
                    : 'Technician: Assignment in Progress',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
              ),
              if (sState.shouldShowOtp && sState.arrivalOtp != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.key_rounded, size: 14, color: Color(0xFF92400E)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Doorstep Arrival OTP: ${sState.arrivalOtp}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF92400E),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Flexible(
                        child: Text(
                          'Share at doorstep',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (sState.isInService) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.verified_rounded, size: 14, color: Color(0xFF16A34A)),
                      SizedBox(width: 6),
                      Text(
                        'OTP Verified • Service In Progress',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF15803D),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: const Icon(Icons.location_on_rounded, size: 15),
                  label: Text(
                    isArrived ? 'Open Live Tracking & Upgrade' : 'Open Live Tracking & Map',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  onPressed: () {
                    if (widget.onTrackTap != null) {
                      widget.onTrackTap!();
                    } else {
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildServiceSummaryCard(bool isHappyHour) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHappyHour ? const Color(0xFF86EFAC) : const Color(0xFFE2E8F0),
          width: isHappyHour ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _isServiceDetailsExpanded = !_isServiceDetailsExpanded),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Doorstep RO Inspection',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.3,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Machine Checkup • TDS Test • Tank Clean',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0284C7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isHappyHour)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '₹$_baseVisitFee ',
                                style: const TextStyle(
                                  fontSize: 12,
                                  decoration: TextDecoration.lineThrough,
                                  color: Color(0xFF94A3B8),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Text(
                                'FREE ₹0',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF16A34A),
                                ),
                              ),
                            ],
                          ),
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              HappyHourHelper.isHappyHourLive()
                                  ? 'HAPPY HOUR'
                                  : 'PROMO APPLIED',
                              style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '₹$_effectiveVisitFee',
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const Text(
                            'Pay after visit',
                            style: TextStyle(fontSize: 9.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      _isServiceDetailsExpanded ? 'Hide service details' : 'What is included & repair info',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _isServiceDetailsExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: const Color(0xFF64748B),
                    ),
                  ],
                ),
                if (_isServiceDetailsExpanded) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
                  const SizedBox(height: 10),
                  _buildFeatureBullet('Complete machine checkup & water TDS test'),
                  const SizedBox(height: 6),
                  _buildFeatureBullet('Storage tank deep cleaning & sanitization'),
                  const SizedBox(height: 6),
                  _buildFeatureBullet('Outer pre-filter cleaning & replacement fitting'),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, size: 14, color: Color(0xFF0284C7)),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Need leak/motor repair? Upgrade on visit (₹149). Spares extra at factory wholesale rates.',
                            style: TextStyle(fontSize: 10.5, color: Color(0xFF475569), height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureBullet(String text) {
    return Row(
      children: [
        const Icon(Icons.check_circle_rounded, size: 15, color: Color(0xFF16A34A)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddressCard() {
    final bool hasAddrErr = _addressError != null && _highlightErrors;
    return Container(
      decoration: BoxDecoration(
        color: hasAddrErr ? const Color(0xFFFEF2F2) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasAddrErr ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
          width: hasAddrErr ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasAddrErr) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _addressError!,
                      style: const TextStyle(color: Color(0xFFEF4444), fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_selectedAddress != null) ...[
            Row(
              children: [
                Icon(
                  _selectedAddress!.tag == 'Home'
                      ? Icons.home_rounded
                      : (_selectedAddress!.tag == 'Work' ? Icons.work_outline_rounded : Icons.location_on_rounded),
                  color: const Color(0xFF0284C7),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'DELIVERING TO ${_selectedAddress!.tag.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0284C7),
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF16A34A)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _selectedAddress!.fullAddress,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (!_selectedAddress!.hasValidDoorstep) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => _openMapTuneLocation(_selectedAddress),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.edit_location_alt_outlined, color: Colors.black, size: 15),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'House / Flat No. required • Tap to add',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.black),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: Colors.black, size: 16),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF0284C7),
                      side: const BorderSide(color: Color(0xFF0284C7), width: 1.0),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    icon: const Icon(Icons.edit_location_alt_rounded, size: 13),
                    label: const Text('Edit Location', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                    onPressed: () => _openMapTuneLocation(_selectedAddress),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF475569),
                    side: const BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                  ),
                  icon: const Icon(Icons.swap_horiz_rounded, size: 14),
                  label: const Text('Change', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  onPressed: _openAddressSelector,
                ),
              ],
            ),
          ] else ...[
            const Row(
              children: [
                Icon(Icons.location_off_rounded, color: Color(0xFF64748B), size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No Doorstep Address Selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0F172A)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Pinpoint your doorstep location on Google Maps for fast technician arrival.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.map_rounded, size: 16),
                label: const Text('🗺️ Pinpoint Doorstep on Map', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                onPressed: () => _openMapTuneLocation(null),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContactCard() {
    final isLoggedIn = widget.cartState?.isLoggedIn == true;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLoggedIn) ...[
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE0F2FE),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.person_rounded, color: Color(0xFF0284C7), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.cartState?.userName.isNotEmpty == true
                                  ? widget.cartState!.userName
                                  : 'Valued Customer',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Icon(Icons.verified_rounded, size: 15, color: Color(0xFF16A34A)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '+91 ${widget.cartState?.userPhone ?? ""}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Book for someone else?',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF475569),
                  ),
                ),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: _isBookingForSomeoneElse,
                    activeThumbColor: const Color(0xFF0284C7),
                    onChanged: (val) => setState(() => _isBookingForSomeoneElse = val),
                  ),
                ),
              ],
            ),
            if (_isBookingForSomeoneElse) ...[
              const SizedBox(height: 10),
              // Quick phone toggle: Call Me vs Enter Receiver's Phone
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _receiverPhoneController.text = widget.cartState?.userPhone ?? '';
                          _receiverPhoneError = null;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                        decoration: BoxDecoration(
                          color: _receiverPhoneController.text == (widget.cartState?.userPhone ?? '') && _receiverPhoneController.text.isNotEmpty
                              ? const Color(0xFFE0F2FE)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _receiverPhoneController.text == (widget.cartState?.userPhone ?? '') && _receiverPhoneController.text.isNotEmpty
                                ? const Color(0xFF0284C7)
                                : const Color(0xFFCBD5E1),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.phone_android_rounded, size: 13, color: Color(0xFF0284C7)),
                            SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Use My Phone',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF0284C7)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _receiverPhoneController.clear();
                          _receiverPhoneError = null;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                        decoration: BoxDecoration(
                          color: _receiverPhoneController.text != (widget.cartState?.userPhone ?? '')
                              ? const Color(0xFFE0F2FE)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _receiverPhoneController.text != (widget.cartState?.userPhone ?? '')
                                ? const Color(0xFF0284C7)
                                : const Color(0xFFCBD5E1),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.person_outline_rounded, size: 13, color: Color(0xFF475569)),
                            SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                "Receiver's Phone",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildFormLabel("RECEIVER'S FULL NAME *"),
              const SizedBox(height: 5),
              _buildTextField(
                controller: _receiverNameController,
                hint: 'e.g. Papa / Rahul Kumar',
                hasError: _receiverNameError != null,
                errorText: _receiverNameError,
                onChanged: (val) {
                  if (_receiverNameError != null && val.trim().isNotEmpty) {
                    setState(() => _receiverNameError = null);
                  }
                },
              ),
              const SizedBox(height: 10),
              _buildFormLabel("RECEIVER'S MOBILE NUMBER *"),
              const SizedBox(height: 5),
              _buildTextField(
                controller: _receiverPhoneController,
                hint: '10-digit mobile number for technician calls',
                keyboardType: TextInputType.phone,
                maxLength: 10,
                hasError: _receiverPhoneError != null,
                errorText: _receiverPhoneError,
                onChanged: (val) {
                  if (_receiverPhoneError != null && val.trim().length >= 10) {
                    setState(() => _receiverPhoneError = null);
                  }
                },
              ),
              const SizedBox(height: 12),

              // Past Saved Addresses from DynamoDB SSoT
              if ((widget.cartState?.addresses ?? []).isNotEmpty) ...[
                _buildFormLabel("SELECT SAVED ADDRESS FOR RECEIVER *"),
                const SizedBox(height: 6),
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.cartState!.addresses.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, idx) {
                      if (idx == widget.cartState!.addresses.length) {
                        return InkWell(
                          onTap: () => _openMapTuneLocation(null),
                          child: Container(
                            width: 100,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFCBD5E1)),
                            ),
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_location_alt_outlined, size: 18, color: Color(0xFF0284C7)),
                                SizedBox(height: 2),
                                Text(
                                  '+ Add New',
                                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      final addr = widget.cartState!.addresses[idx];
                      final isSel = _selectedAddress?.id == addr.id;
                      return InkWell(
                        onTap: () => _applySelectedAddress(addr),
                        child: Container(
                          width: 155,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFFEFF6FF) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSel ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                              width: isSel ? 1.5 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    addr.tag == 'Home' ? Icons.home_rounded : (addr.tag == 'Work' ? Icons.work_outline_rounded : Icons.location_on_rounded),
                                    size: 13,
                                    color: isSel ? const Color(0xFF0284C7) : const Color(0xFF64748B),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      addr.tag,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        color: isSel ? const Color(0xFF0284C7) : const Color(0xFF0F172A),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isSel)
                                    const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF0284C7)),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                addr.fullAddress,
                                style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ] else ...[
            Row(
              children: [
                const Icon(Icons.account_circle_outlined, color: Color(0xFFD97706), size: 28),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Login for 1-Tap Booking',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF92400E)),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Pre-fills name and phone automatically.',
                        style: TextStyle(fontSize: 11, color: Color(0xFFB45309)),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD97706),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _openLoginSheet,
                  child: const Text('Log In', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaymentCard(bool isFree) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFFDCFCE7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.payments_outlined, color: Color(0xFF16A34A), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cash / UPI on Visit',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 1),
                Text(
                  isFree
                      ? (HappyHourHelper.isHappyHourLive()
                          ? 'Free ₹0 (Happy Hour visit)'
                          : 'Free ₹0 (Promo applied)')
                      : 'Pay ₹$_effectiveVisitFee after service inspection',
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReferralSection() {
    if (_showReferralInput) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _referralController,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) {
                      if (_isReferralApplied || _referralMessage != null) {
                        setState(() {
                          _isReferralApplied = false;
                          _appliedPromoCode = null;
                          _promoNetPayable = null;
                          _referralMessage = null;
                        });
                      }
                    },
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Enter promo or referral code',
                      hintStyle: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _isApplyingReferral ? null : _applyReferral,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isApplyingReferral
                          ? const Color(0xFF64748B)
                          : const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _isApplyingReferral ? 'Applying...' : 'Apply',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            if (_referralMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                _referralMessage!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _isReferralApplied
                      ? const Color(0xFF16A34A)
                      : const Color(0xFFDC2626),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => setState(() => _showReferralInput = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Row(
          children: [
            Icon(Icons.discount_outlined, size: 16, color: Color(0xFF0284C7)),
            SizedBox(width: 8),
            Text(
              'Have a promo code?',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0284C7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookingButton(bool isFree) {
    final isLoggedIn = widget.cartState?.isLoggedIn == true;
    final hasAddress = _selectedAddress != null || _streetController.text.trim().isNotEmpty;
    final hasValidDoorstep = (_selectedAddress != null && _selectedAddress!.hasValidDoorstep) ||
        (_streetController.text.trim().isNotEmpty && _streetController.text.trim().toLowerCase() != 'current location');

    return BouncingWidget(
      onTap: () {
        if (_isSubmitting || _isBooking) return;
        if (!isLoggedIn) {
          _openLoginSheet();
        } else if (!hasAddress) {
          _openMapTuneLocation(null);
        } else if (!hasValidDoorstep) {
          _openMapTuneLocation(_selectedAddress);
          _showToast('Please enter your House / Flat / Building number');
        } else {
          _submitBooking();
        }
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isFree ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: (_isSubmitting || _isBooking)
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Verifying & Booking Slot...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_outline_rounded, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          !isLoggedIn
                              ? 'Log In to Book'
                              : (!hasAddress ? 'Set Delivery Address' : 'Book'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                        if (isLoggedIn && hasAddress) ...[
                          const SizedBox(height: 1),
                          Text(
                            isFree ? '₹0 Cash on Delivery' : '₹$_effectiveVisitFee Cash on Delivery',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildFormLabel(String label) {
    final bool hasStar = label.contains('*');
    final cleanLabel = label.replaceAll('*', '').trim();
    return RichText(
      text: TextSpan(
        text: cleanLabel,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFF0F172A),
          letterSpacing: 0.5,
        ),
        children: hasStar
            ? const [
                TextSpan(
                  text: ' *',
                  style: TextStyle(
                    color: Color(0xFFEF4444),
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ]
            : null,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
    int? maxLength,
    bool hasError = false,
    String? errorText,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: hasError ? const Color(0xFFFEF2F2) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hasError ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
              width: hasError ? 1.5 : 1.0,
            ),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLength: maxLength,
            onChanged: onChanged,
            buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A),
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF94A3B8),
                fontWeight: FontWeight.w400,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              isDense: true,
            ),
          ),
        ),
        if (hasError && errorText != null && errorText.isNotEmpty) ...[
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              errorText,
              style: const TextStyle(
                color: Color(0xFFEF4444),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
