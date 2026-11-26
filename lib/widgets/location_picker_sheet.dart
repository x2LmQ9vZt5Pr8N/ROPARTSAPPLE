import 'package:flutter/material.dart';
import '../models/user_address.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';
import 'manage_addresses_sheet.dart';
import 'map_address_picker_sheet.dart';

class LocationPickerSheet extends StatefulWidget {
  final CartState cartState;

  const LocationPickerSheet({
    super.key,
    required this.cartState,
  });

  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  late TextEditingController _pincodeController;
  bool _isDetectingGps = false;

  @override
  void initState() {
    super.initState();
    _pincodeController = TextEditingController(text: widget.cartState.deliveryPincode);
  }

  @override
  void dispose() {
    _pincodeController.dispose();
    super.dispose();
  }

  String _lookupCity(String pin) {
    if (pin.startsWith('560')) return 'Bengaluru';
    if (pin.startsWith('110')) return 'New Delhi';
    if (pin.startsWith('400')) return 'Mumbai';
    if (pin.startsWith('600')) return 'Chennai';
    if (pin.startsWith('700')) return 'Kolkata';
    if (pin.startsWith('500')) return 'Hyderabad';
    if (pin.startsWith('411')) return 'Pune';
    if (pin.startsWith('380')) return 'Ahmedabad';
    return 'India';
  }

  void _applyLocation(String pincode, String city) {
    final messenger = ScaffoldMessenger.of(context);
    widget.cartState.setLocation(pincode, city);
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Delivery location set to $pincode • $city'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openMapPicker({UserAddress? addr, bool autoLocate = false}) {
    final nav = Navigator.of(context);
    nav.pop();
    showModalBottomSheet(
      context: nav.context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MapAddressPickerSheet(
        cartState: widget.cartState,
        initialAddress: addr,
        autoLocate: autoLocate,
      ),
    );
  }

  void _openManageAddresses() {
    final nav = Navigator.of(context);
    nav.pop();
    showModalBottomSheet(
      context: nav.context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ManageAddressesSheet(
        cartState: widget.cartState,
      ),
    );
  }

  void _detectGps() {
    setState(() => _isDetectingGps = true);
    _openMapPicker(autoLocate: true);
  }

  IconData _getTagIcon(String tag) {
    switch (tag) {
      case 'Home':
        return Icons.home_rounded;
      case 'Work':
        return Icons.work_outline_rounded;
      case 'Workshop':
        return Icons.build_circle_outlined;
      default:
        return Icons.location_on_outlined;
    }
  }

  Color _getTagColor(String tag) {
    switch (tag) {
      case 'Home':
        return const Color(0xFF0284C7);
      case 'Work':
        return const Color(0xFF475569);
      case 'Workshop':
        return const Color(0xFFD97706);
      default:
        return const Color(0xFF059669);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.90,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header Row: Select Delivery Location + Close
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select Delivery Location',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Check spare parts availability & delivery speed',
                          maxLines: 2,
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

            // Content List
            Flexible(
              child: ListView(
                padding: const EdgeInsets.all(16),
                shrinkWrap: true,
                children: [
                  // Active Delivery Location Card
                  ListenableBuilder(
                    listenable: widget.cartState,
                    builder: (context, _) {
                      final activeAddr = widget.cartState.activeAddress;
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                activeAddr != null ? _getTagIcon(activeAddr.tag) : Icons.location_on_rounded,
                                color: const Color(0xFF0284C7),
                                size: 19,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Flexible(
                                        child: Text(
                                          'ACTIVE DELIVERY LOCATION',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF059669),
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                      if (activeAddr != null) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF1F5F9),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            activeAddr.tag.toUpperCase(),
                                            style: const TextStyle(
                                              fontSize: 8.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF334155),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${widget.cartState.deliveryPincode} • ${widget.cartState.deliveryCity}',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A),
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  if (activeAddr != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      activeAddr.fullAddress,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF64748B),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: const Color(0xFFBBF7D0)),
                              ),
                              child: const Text(
                                'Active',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF16A34A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 12),

                  // Option 1: Use Live Map / GPS Pinpoint
                  BouncingWidget(
                    onTap: _isDetectingGps ? () {} : _detectGps,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.35), width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.06),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0284C7),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: _isDetectingGps
                                ? const Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
                                    ),
                                  )
                                : const Icon(Icons.my_location_rounded, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Set Location on Interactive Map',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0284C7),
                                  ),
                                ),
                                SizedBox(height: 1),
                                Text(
                                  'Drag map pin directly to your door / workshop',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF64748B),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.arrow_forward_ios_rounded, size: 13, color: Color(0xFF0284C7)),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Option 2: Enter Delivery Pincode
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ENTER DELIVERY PINCODE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Color(0xFF475569),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                constraints: const BoxConstraints(minHeight: 42),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFCBD5E1), width: 1.2),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                alignment: Alignment.center,
                                child: TextField(
                                  controller: _pincodeController,
                                  keyboardType: TextInputType.number,
                                  maxLength: 6,
                                  decoration: const InputDecoration(
                                    hintText: 'e.g. 560034',
                                    counterText: '',
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F172A),
                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () {
                                final pin = _pincodeController.text.trim();
                                if (pin.length == 6) {
                                  final city = _lookupCity(pin);
                                  _applyLocation(pin, city);
                                }
                              },
                              child: const Text('Apply', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Option 3: Saved Addresses (with Manage Addresses >)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'SAVED ADDRESSES',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      BouncingWidget(
                        onTap: _openManageAddresses,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Manage Addresses',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0284C7),
                              ),
                            ),
                            SizedBox(width: 2),
                            Icon(Icons.arrow_forward_ios_rounded, size: 10, color: Color(0xFF0284C7)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Saved Addresses List from CartState
                  ListenableBuilder(
                    listenable: widget.cartState,
                    builder: (context, _) {
                      final addresses = widget.cartState.addresses;
                      final activeId = widget.cartState.activeAddress?.id;

                      if (addresses.isEmpty) {
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                'No saved addresses found',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF64748B)),
                              ),
                              const SizedBox(height: 8),
                              BouncingWidget(
                                onTap: () => _openMapPicker(),
                                child: const Text(
                                  '+ Pin an address on map',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF0284C7)),
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return Column(
                        children: addresses.map((addr) {
                          final isCurrent = activeId == addr.id;
                          final tagColor = _getTagColor(addr.tag);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: BouncingWidget(
                              onTap: () {
                                final messenger = ScaffoldMessenger.of(context);
                                widget.cartState.selectAddress(addr);
                                Navigator.pop(context);
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text('Delivery set to ${addr.tag} (${addr.pincode} • ${addr.city})'),
                                    behavior: SnackBarBehavior.floating,
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isCurrent ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                                    width: isCurrent ? 1.5 : 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: isCurrent
                                          ? const Color(0xFF0284C7).withValues(alpha: 0.06)
                                          : Colors.black.withValues(alpha: 0.02),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: tagColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(_getTagIcon(addr.tag), size: 16, color: tagColor),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                addr.tag.toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 0.4,
                                                  color: tagColor,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  '${addr.pincode} • ${addr.city}',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w800,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                              ),
                                              if (addr.isDefault) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFF1F5F9),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text(
                                                    'DEFAULT',
                                                    style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Color(0xFF475569)),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            addr.flatNo.isNotEmpty
                                                ? '${addr.flatNo}, ${addr.streetArea}'
                                                : addr.streetArea,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF64748B),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (isCurrent)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF0FDF4),
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF16A34A)),
                                      )
                                    else
                                      const Text(
                                        'Select →',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF0284C7),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),

                  const SizedBox(height: 4),

                  // Bottom Add Button
                  BouncingWidget(
                    onTap: () => _openMapPicker(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      alignment: Alignment.center,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_location_alt_outlined, size: 16, color: Color(0xFF0284C7)),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Add New Address via Map',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0284C7),
                              ),
                            ),
                          ),
                        ],
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
}
