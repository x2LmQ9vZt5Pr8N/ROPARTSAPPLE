import 'package:flutter/material.dart';
import '../models/user_address.dart';
import '../state/cart_state.dart';
import 'bouncing_widget.dart';
import 'map_address_picker_sheet.dart';

class ManageAddressesSheet extends StatelessWidget {
  final CartState cartState;

  const ManageAddressesSheet({
    super.key,
    required this.cartState,
  });

  void _openAddOrEditAddress(BuildContext context, [UserAddress? address]) {
    if (address == null && cartState.addresses.length >= CartState.maxSavedAddresses) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maximum ${CartState.maxSavedAddresses} saved addresses allowed per account. Please delete or edit an existing address.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MapAddressPickerSheet(
        cartState: cartState,
        initialAddress: address,
      ),
    );
  }

  void _confirmDelete(BuildContext context, UserAddress addr) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444), size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Delete Address?',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to remove this ${addr.tag} address (${addr.pincode} • ${addr.city})?',
          style: const TextStyle(fontSize: 13.5, color: Color(0xFF475569), height: 1.4),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              cartState.deleteAddress(addr.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${addr.tag} address removed'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
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
        maxHeight: screenHeight * 0.92,
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
            // Drag handle bar
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Sheet Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.bookmark_border_rounded, color: Color(0xFF0284C7), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Manage Delivery Addresses',
                          style: TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Select, edit, or pin new delivery destinations',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
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

            // Top action: Add New Address
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: BouncingWidget(
                onTap: () => _openAddOrEditAddress(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
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
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7),
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.add_location_alt_rounded, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Add New Address via Map',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0284C7),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Pinpoint exact workshop or home entrance on map',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF64748B),
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
            ),

            // Address List Section
            Expanded(
              child: ListenableBuilder(
                listenable: cartState,
                builder: (context, _) {
                  final addresses = cartState.addresses;
                  final activeId = cartState.activeAddress?.id;

                  if (addresses.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(Icons.location_off_rounded, size: 32, color: Color(0xFF0284C7)),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No Saved Addresses',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Add your home, office, or RO servicing workshop location for rapid 1-click dispatch.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    itemCount: addresses.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final addr = addresses[index];
                      final isSelected = activeId == addr.id;
                      final tagColor = _getTagColor(addr.tag);

                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF0284C7) : const Color(0xFFE2E8F0),
                            width: isSelected ? 1.6 : 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isSelected
                                  ? const Color(0xFF0284C7).withValues(alpha: 0.08)
                                  : Colors.black.withValues(alpha: 0.03),
                              blurRadius: isSelected ? 12 : 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(15),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Top Badges Row
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        // Tag Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: tagColor.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(_getTagIcon(addr.tag), size: 13, color: tagColor),
                                              const SizedBox(width: 4),
                                              Text(
                                                addr.tag.toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 0.5,
                                                  color: tagColor,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (addr.isDefault)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF1F5F9),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: const Color(0xFFE2E8F0)),
                                            ),
                                            child: const Text(
                                              'DEFAULT',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF475569),
                                                letterSpacing: 0.4,
                                              ),
                                            ),
                                          ),
                                        if (addr.hasMapPin)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFEFF6FF),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: const Color(0xFFBFDBFE)),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.gps_fixed_rounded, size: 10, color: Color(0xFF0284C7)),
                                                SizedBox(width: 3),
                                                Text(
                                                  'GPS PIN',
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFF0369A1),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF0FDF4),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: const Color(0xFFBBF7D0)),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF16A34A)),
                                          SizedBox(width: 4),
                                          Text(
                                            'Delivering Here',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF16A34A),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 10),

                              if (addr.recipientName != null && addr.recipientName!.trim().isNotEmpty) ...[
                                Text(
                                  addr.recipientPhone != null && addr.recipientPhone!.trim().isNotEmpty
                                      ? '${addr.recipientName} • ${addr.recipientPhone}'
                                      : addr.recipientName!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                                const SizedBox(height: 3),
                              ],

                              // Flat / House No
                              Text(
                                addr.flatNo,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 3),

                              // Street & Area
                              Text(
                                addr.streetArea,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF475569),
                                ),
                              ),

                              // Landmark
                              if (addr.landmark.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  addr.landmark.toLowerCase().startsWith('near ')
                                      ? addr.landmark
                                      : 'Near ${addr.landmark}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w400,
                                    color: Color(0xFF64748B),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],

                              const SizedBox(height: 3),
                              // City + State + PIN
                              Text(
                                '${addr.city}${(addr.stateName != null && addr.stateName!.trim().isNotEmpty) ? ', ${addr.stateName}' : ''} • ${addr.pincode}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0284C7),
                                ),
                              ),

                              const SizedBox(height: 12),
                              const Divider(height: 1, thickness: 0.8, color: Color(0xFFF1F5F9)),
                              const SizedBox(height: 10),

                              // Bottom Actions Row: Deliver Here | Edit | Delete
                              Row(
                                children: [
                                  // Deliver Here button
                                  Expanded(
                                    child: BouncingWidget(
                                      onTap: () {
                                        final messenger = ScaffoldMessenger.of(context);
                                        cartState.selectAddress(addr);
                                        Navigator.pop(context);
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Delivery location updated to ${addr.tag} (${addr.pincode})'),
                                            behavior: SnackBarBehavior.floating,
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 9),
                                        decoration: BoxDecoration(
                                          color: isSelected ? const Color(0xFF0284C7) : const Color(0xFFF1F5F9),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        alignment: Alignment.center,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            isSelected ? 'Current Address' : 'Deliver to this Address',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w800,
                                              color: isSelected ? Colors.white : const Color(0xFF0F172A),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),

                                  // Edit Button
                                  BouncingWidget(
                                    onTap: () => _openAddOrEditAddress(context, addr),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.edit_outlined, size: 14, color: Color(0xFF475569)),
                                          SizedBox(width: 4),
                                          Text(
                                            'Edit',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF475569),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),

                                  // Delete Button
                                  BouncingWidget(
                                    onTap: () => _confirmDelete(context, addr),
                                    child: Container(
                                      padding: const EdgeInsets.all(9),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFEF2F2),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFFFECACA), width: 0.8),
                                      ),
                                      child: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFEF4444)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
