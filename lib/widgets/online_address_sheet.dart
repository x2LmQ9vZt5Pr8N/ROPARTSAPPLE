import 'dart:async';
import 'package:flutter/material.dart';
import '../models/user_address.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../theme/app_theme.dart';
import 'map_address_picker_sheet.dart';

/// Unified Delivery Address Book Selector & Quick Pan-India Form.
/// Works identically for Direct Online E-Commerce and Doorstep Service Visits.
class OnlineAddressSheet extends StatefulWidget {
  final CartState cartState;

  const OnlineAddressSheet({super.key, required this.cartState});

  @override
  State<OnlineAddressSheet> createState() => _OnlineAddressSheetState();
}

class _OnlineAddressSheetState extends State<OnlineAddressSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _flatCtrl = TextEditingController();
  final _streetCtrl = TextEditingController();
  final _landmarkCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();

  String _tag = 'Home';
  bool _showAddForm = false;
  bool _checkingPin = false;
  bool _pinValid = false;
  String? _pinStatusMsg;
  String _lastAutoState = '';
  String _lastAutoCity = '';
  Timer? _pinDebounce;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.cartState.userName;
    _phoneCtrl.text = widget.cartState.userPhone.replaceAll(RegExp(r'\D'), '');
    if (widget.cartState.addresses.isEmpty) {
      _showAddForm = true;
    }
  }

  @override
  void dispose() {
    _pinDebounce?.cancel();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _pinCtrl.dispose();
    _flatCtrl.dispose();
    _streetCtrl.dispose();
    _landmarkCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    super.dispose();
  }

  void _onPinChanged(String raw) {
    final clean = raw.replaceAll(RegExp(r'\D'), '');
    _pinDebounce?.cancel();
    if (clean.length < 6) {
      setState(() {
        _pinValid = false;
        _checkingPin = false;
        _pinStatusMsg = clean.isEmpty ? null : 'Enter all 6 digits of Indian PIN code';
      });
      return;
    }
    setState(() => _checkingPin = true);
    _pinDebounce = Timer(const Duration(milliseconds: 220), () async {
      final res = await ApiService().validateIndianOnlinePincode(clean);
      if (!mounted) return;
      final isValid = res['valid'] == true;
      setState(() {
        _checkingPin = false;
        _pinValid = isValid;
        if (isValid) {
          final st = (res['state'] ?? '').toString();
          final region = (res['region'] ?? '').toString();
          final eta = (res['estimated_days'] ?? '3–6 business days').toString();
          if ((_stateCtrl.text.trim().isEmpty || _stateCtrl.text.trim() == _lastAutoState) && st.isNotEmpty) {
            _stateCtrl.text = st;
            _lastAutoState = st;
          }
          if ((_cityCtrl.text.trim().isEmpty || _cityCtrl.text.trim() == _lastAutoCity) && region.isNotEmpty) {
            _cityCtrl.text = region;
            _lastAutoCity = region;
          }
          _pinStatusMsg = 'All-India Delivery Available • $st ($eta)';
        } else {
          _pinStatusMsg = (res['error'] ?? 'Enter valid Indian PIN code (110001 - 855999)').toString();
        }
      });
    });
  }

  Future<void> _saveNewAddress() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!widget.cartState.canAddAddress) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maximum ${CartState.maxSavedAddresses} saved addresses allowed. Delete or edit an existing one.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final cleanPin = _pinCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (!_pinValid) {
      final res = await ApiService().validateIndianOnlinePincode(cleanPin);
      if (!mounted) return;
      if (res['valid'] != true) {
        setState(() => _pinStatusMsg = (res['error'] ?? 'Invalid 6-digit Indian PIN code').toString());
        return;
      }
      if (_stateCtrl.text.trim().isEmpty && res['state'] != null) {
        _stateCtrl.text = res['state'].toString();
      }
    }

    final addr = UserAddress(
      id: 'addr-${DateTime.now().millisecondsSinceEpoch}',
      tag: _tag,
      addressType: 'UNIFIED',
      recipientName: _nameCtrl.text.trim(),
      recipientPhone: _phoneCtrl.text.replaceAll(RegExp(r'\D'), ''),
      flatNo: _flatCtrl.text.trim(),
      streetArea: _streetCtrl.text.trim(),
      landmark: _landmarkCtrl.text.trim(),
      city: _cityCtrl.text.trim(),
      stateName: _stateCtrl.text.trim(),
      pincode: cleanPin,
      isDefault: widget.cartState.addresses.isEmpty,
    );

    final added = widget.cartState.addAddress(addr);
    if (!added) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Address limit reached (${CartState.maxSavedAddresses}).')),
        );
      }
      return;
    }
    if (mounted) Navigator.pop(context, widget.cartState.activeAddress ?? addr);
  }

  Future<void> _openMapEditor([UserAddress? existing]) async {
    if (existing == null && !widget.cartState.canAddAddress) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maximum ${CartState.maxSavedAddresses} saved addresses allowed.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    final saved = await showModalBottomSheet<UserAddress>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MapAddressPickerSheet(
        cartState: widget.cartState,
        initialAddress: existing,
        autoLocate: existing == null,
      ),
    );
    if (saved != null && mounted) {
      Navigator.pop(context, saved);
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final allAddrs = widget.cartState.addresses;
    final currentSelected = widget.cartState.activeAddress;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.viewPaddingOf(context).bottom,
      ),
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.of(context).size.height - MediaQuery.of(context).viewInsets.bottom)
            .clamp(240.0, MediaQuery.of(context).size.height * 0.90),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 38,
            height: 4,
            decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 14, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.location_on_rounded, color: Color(0xFF0284C7), size: 20),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Unified Delivery Address Book', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                      Text('Synced across Online Store & Doorstep Service across India', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_showAddForm) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Select Address', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton.icon(
                              onPressed: () => _openMapEditor(),
                              icon: const Icon(Icons.map_outlined, size: 16),
                              label: const Text('Map Pin', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                            ),
                            TextButton.icon(
                              onPressed: () => setState(() => _showAddForm = true),
                              icon: const Icon(Icons.add_circle_outline_rounded, size: 17),
                              label: const Text('Add PIN Address', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...allAddrs.map((addr) {
                      final isSelected = currentSelected?.id == addr.id;
                      return GestureDetector(
                        onTap: () {
                          widget.cartState.selectAddress(addr);
                          Navigator.pop(context, addr);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                              width: isSelected ? 1.8 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: isSelected ? const Color(0xFF0284C7) : const Color(0xFF94A3B8),
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(addr.tag, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppTheme.textPrimary)),
                                        if (addr.isDefault) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF1F5F9),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: const Text(
                                              'DEFAULT',
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF475569),
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (addr.hasMapPin) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFE0F2FE),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: const Text(
                                              'GPS PIN',
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0369A1),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (addr.recipientName != null && addr.recipientName!.isNotEmpty)
                                      Text('${addr.recipientName}${(addr.recipientPhone != null && addr.recipientPhone!.isNotEmpty) ? ' • ${addr.recipientPhone}' : ''}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF334155))),
                                    Text(addr.fullAddress, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    Text('PIN: ${addr.pincode}${addr.stateName != null && addr.stateName!.isNotEmpty ? ' • ${addr.stateName}' : ''}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0284C7))),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit Address',
                                icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF64748B)),
                                onPressed: () => _openMapEditor(addr),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('New Pan-India Shipping Address', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                        if (allAddrs.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() => _showAddForm = false),
                            child: const Text('Back to Saved'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _nameCtrl,
                            decoration: _inputDeco('Recipient Full Name *'),
                            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter recipient name' : null,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            maxLength: 10,
                            decoration: _inputDeco('Recipient 10-Digit Mobile *').copyWith(counterText: ''),
                            validator: (v) => (v == null || v.replaceAll(RegExp(r'\D'), '').length < 10) ? 'Enter valid 10-digit mobile' : null,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _pinCtrl,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            onChanged: _onPinChanged,
                            decoration: _inputDeco('6-Digit Indian PIN Code * (Anywhere in India)').copyWith(
                              counterText: '',
                              suffixIcon: _checkingPin
                                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                                  : (_pinValid ? const Icon(Icons.verified_rounded, color: Color(0xFF16A34A)) : null),
                            ),
                            validator: (v) => (v == null || !RegExp(r'^[1-9][0-9]{5}$').hasMatch(v.trim())) ? 'Enter valid 6-digit Indian PIN' : null,
                          ),
                          if (_pinStatusMsg != null) ...[
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: _pinValid ? const Color(0xFFECFDF5) : const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: _pinValid ? const Color(0xFFA7F3D0) : const Color(0xFFFDE68A)),
                              ),
                              child: Text(
                                _pinStatusMsg!,
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _pinValid ? const Color(0xFF065F46) : const Color(0xFF92400E)),
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _flatCtrl,
                            decoration: _inputDeco('House / Flat / Building No. *'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _streetCtrl,
                            decoration: _inputDeco('Street / Colony / Area *'),
                            validator: (v) => (v == null || v.trim().length < 3) ? 'Enter street or locality' : null,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _landmarkCtrl,
                            decoration: _inputDeco('Landmark (Optional)'),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _cityCtrl,
                                  decoration: _inputDeco('City / District *'),
                                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextFormField(
                                  controller: _stateCtrl,
                                  decoration: _inputDeco('State *'),
                                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: ['Home', 'Work', 'Other'].map((label) {
                              final sel = _tag == label;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label),
                                  selected: sel,
                                  onSelected: (_) => setState(() => _tag = label),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 46,
                            child: ElevatedButton(
                              onPressed: _saveNewAddress,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              child: const Text('Save & Deliver Across India', style: TextStyle(fontWeight: FontWeight.w800)),
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
        ],
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        labelText: hint,
        labelStyle: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      );
}

