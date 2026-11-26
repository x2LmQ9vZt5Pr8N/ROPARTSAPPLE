import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';
import 'manage_addresses_sheet.dart';
import 'auth_sheet.dart';
import 'email_prompt_dialog.dart';

class ProfileSheet extends StatelessWidget {
  final CartState cartState;
  final String? userName;
  final String? userPhone;

  const ProfileSheet({
    super.key,
    required this.cartState,
    this.userName,
    this.userPhone,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final defaultAddr = cartState.activeAddress;
    final effectiveName = cartState.isLoggedIn && cartState.userName.isNotEmpty
        ? cartState.userName
        : (userName ?? 'Guest Customer');
    final effectivePhone = cartState.isLoggedIn && cartState.userPhone.isNotEmpty
        ? PhoneNormalizer.formatIndianPhone(cartState.userPhone)
        : (userPhone ?? 'Not logged in');

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.88,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Drag Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'My Profile',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
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
                      alignment: Alignment.center,
                      child: const Icon(Icons.close, size: 18, color: Color(0xFF475569)),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0xFFE2E8F0)),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // User Avatar & Name Card or Login CTA
                  if (cartState.isLoggedIn)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: const Color(0xFF16A34A).withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF16A34A), width: 1.5),
                            ),
                            child: const Center(
                              child: Icon(Icons.person_rounded, size: 28, color: Color(0xFF16A34A)),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        effectiveName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDCFCE7),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'VERIFIED',
                                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF16A34A)),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  effectivePhone,
                                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                                ),
                                if (cartState.userEmail != null && cartState.userEmail!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    cartState.userEmail!,
                                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF16A34A).withValues(alpha: 0.06),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Center(
                                  child: Icon(Icons.chat_bubble_rounded, size: 22, color: Color(0xFF15803D)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Login or Sign Up',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Verify with WhatsApp in 5 seconds',
                                      style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          BouncingWidget(
                            onTap: () {
                              final nav = Navigator.of(context);
                              nav.pop();
                              if (nav.context.mounted) {
                                AuthSheet.show(nav.context, cartState: cartState);
                              }
                            },
                            child: Container(
                              height: 42,
                              decoration: BoxDecoration(
                                color: const Color(0xFF16A34A),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: const Text(
                                'Login with WhatsApp',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Default Delivery Address Box
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Row(
                                children: [
                                  Icon(Icons.location_on_rounded, size: 16, color: Color(0xFF0284C7)),
                                  SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      'DEFAULT DELIVERY ADDRESS',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF64748B),
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            BouncingWidget(
                              onTap: () {
                                final nav = Navigator.of(context);
                                nav.pop();
                                if (nav.context.mounted) {
                                  showModalBottomSheet(
                                    context: nav.context,
                                    isScrollControlled: true,
                                    backgroundColor: Colors.transparent,
                                    builder: (ctx) => ManageAddressesSheet(cartState: cartState),
                                  );
                                }
                              },
                              child: const Text(
                                'Change',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF0284C7)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          defaultAddr != null
                              ? defaultAddr.fullAddress
                              : 'No saved address (Add via Map)',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Account Settings List
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        _buildProfileTile(
                          icon: Icons.mark_email_read_outlined,
                          title: 'Email for Order & Invoice Alerts',
                          subtitle: (cartState.userEmail != null && cartState.userEmail!.isNotEmpty)
                              ? cartState.userEmail!
                              : 'Tap to add email for Confirmed, Shipped & Delivery mails',
                          onTap: () => _showEmailEditorDialog(context),
                        ),
                        const Divider(height: 1, indent: 48, color: Color(0xFFF1F5F9)),
                        _buildProfileTile(
                          icon: Icons.notifications_none_rounded,
                          title: 'Notifications & Order SMS',
                          subtitle: 'Managed via Android system notification settings',
                          onTap: () => _showPermissionsDialog(context),
                        ),
                        const Divider(height: 1, indent: 48, color: Color(0xFFF1F5F9)),
                        _buildProfileTile(
                          icon: Icons.language_rounded,
                          title: 'Language',
                          subtitle: 'English (India) — Default',
                          onTap: () {
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(
                                content: Text('English (India) is currently the active language.'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                        const Divider(height: 1, indent: 48, color: Color(0xFFF1F5F9)),
                        _buildProfileTile(
                          icon: Icons.security_rounded,
                          title: 'Security & App Permissions',
                          subtitle: 'Location, Camera & Notification controls',
                          onTap: () => _showPermissionsDialog(context),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Legal & Policies (Google Play Data Safety Compliance)
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        _buildProfileTile(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Privacy Policy',
                          subtitle: 'How we protect your profile & address data',
                          onTap: () => _openPolicyUrl(
                            context,
                            'https://www.roparts.in/privacy-policy',
                          ),
                        ),
                        const Divider(height: 1, indent: 48, color: Color(0xFFF1F5F9)),
                        _buildProfileTile(
                          icon: Icons.description_outlined,
                          title: 'Terms & Conditions',
                          subtitle: 'RO Parts & Drop Purity terms of service',
                          onTap: () => _openPolicyUrl(
                            context,
                            'https://www.roparts.in/terms',
                          ),
                        ),
                        const Divider(height: 1, indent: 48, color: Color(0xFFF1F5F9)),
                        _buildProfileTile(
                          icon: Icons.assignment_return_outlined,
                          title: 'Refund & Return Policy',
                          subtitle: 'Returns, cancellations & settlement terms',
                          onTap: () => _openPolicyUrl(
                            context,
                            'https://www.roparts.in/return-policy',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Logout & Account Deletion
                  if (cartState.isLoggedIn) ...[
                    BouncingWidget(
                      onTap: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        final nav = Navigator.of(context);
                        await cartState.logout();
                        if (nav.canPop()) nav.pop();
                        messenger?.showSnackBar(
                          const SnackBar(
                            content: Text('You have been logged out'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFECACA)),
                        ),
                        alignment: Alignment.center,
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.logout_rounded, size: 16, color: Color(0xFFDC2626)),
                            SizedBox(width: 6),
                            Text(
                              'Log Out',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFDC2626)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    BouncingWidget(
                      onTap: () => _startAccountDeletionFlow(context),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFECACA)),
                        ),
                        alignment: Alignment.center,
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFB91C1C)),
                            SizedBox(width: 6),
                            Text(
                              'Delete Account & Data',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB91C1C),
                              ),
                            ),
                          ],
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
    );
  }

  Future<void> _openPolicyUrl(BuildContext context, String rawUrl) async {
    final uri = Uri.parse(rawUrl);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) return;
      final fallbackLaunched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (fallbackLaunched) return;
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open browser. Visit $rawUrl'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showEmailEditorDialog(BuildContext context) {
    showOrderEmailPromptDialog(context, cartState: cartState);
  }

  void _showPermissionsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Security & App Permissions',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PermissionRow(
                icon: Icons.location_on_outlined,
                label: 'Location (While Using App)',
                detail: 'Used only to pin delivery addresses and verify doorstep serviceability.',
              ),
              SizedBox(height: 12),
              _PermissionRow(
                icon: Icons.qr_code_scanner_rounded,
                label: 'Camera',
                detail: 'Used only when you scan technician or spare-part QR codes.',
              ),
              SizedBox(height: 12),
              _PermissionRow(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                detail: 'Sends live technician arrival and order payment updates.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!kIsWeb) {
                await Geolocator.openAppSettings();
              } else if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please allow Location permission in your browser site settings.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F172A),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Open App Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _startAccountDeletionFlow(BuildContext context) async {
    final phone = cartState.userPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No registered phone number found for this session.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete Account & Data?',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        content: Text(
          'This permanently deletes your RO Parts profile, saved addresses, and active sessions linked to +91 $phone. Financial/GST order invoices may be retained solely for statutory compliance.',
          style: const TextStyle(fontSize: 13, color: Color(0xFF475569), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeleteAccountOtpDialog(
        phone: phone,
        customerId: cartState.customerId,
        authToken: cartState.authToken,
      ),
    );
    if (deleted == true) {
      await cartState.logout();
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your account and personal data have been permanently deleted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildProfileTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return BouncingWidget(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF64748B)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF94A3B8)),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;

  const _PermissionRow({
    required this.icon,
    required this.label,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF0F172A)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF64748B),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Self-owning account-deletion OTP dialog so [_otpCtrl] is disposed only after
/// the dialog route's exit transition finishes unmounting [TextField].
class _DeleteAccountOtpDialog extends StatefulWidget {
  final String phone;
  final String? customerId;
  final String? authToken;

  const _DeleteAccountOtpDialog({
    required this.phone,
    this.customerId,
    this.authToken,
  });

  @override
  State<_DeleteAccountOtpDialog> createState() =>
      _DeleteAccountOtpDialogState();
}

class _DeleteAccountOtpDialogState extends State<_DeleteAccountOtpDialog> {
  final TextEditingController _otpCtrl = TextEditingController();
  bool _isWorking = true;
  bool _needsOtp = false;
  String? _errorMsg;
  String? _statusMsg = 'Verifying account deletion request...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runInitialDelete();
    });
  }

  @override
  void dispose() {
    _otpCtrl.dispose();
    super.dispose();
  }

  void _close(bool deleted) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(deleted);
  }

  Future<void> _triggerOtpRequest() async {
    if (!mounted) return;
    setState(() {
      _isWorking = true;
      _errorMsg = null;
      _statusMsg = 'Sending verification OTP to +91 ${widget.phone}...';
    });
    final otpRes = await ApiService().requestAccountDeletionOtp(widget.phone);
    if (!mounted) return;
    setState(() {
      _isWorking = false;
      _needsOtp = true;
      if (otpRes['success'] == true) {
        _statusMsg = otpRes['message']?.toString() ??
            'Enter the verification OTP sent to +91 ${widget.phone}.';
      } else {
        _statusMsg = 'OTP verification is required before deletion.';
        _errorMsg = otpRes['error']?.toString() ?? 'Could not send OTP.';
      }
    });
  }

  Future<void> _runInitialDelete() async {
    final res = await ApiService().deleteCustomerAccount(
      phone: widget.phone,
      customerId: widget.customerId,
      authToken: widget.authToken,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      _close(true);
      return;
    }
    if (res['needs_otp'] == true) {
      await _triggerOtpRequest();
      return;
    }
    setState(() {
      _isWorking = false;
      _errorMsg = res['error']?.toString() ?? 'Could not delete account.';
    });
  }

  Future<void> _confirmDelete() async {
    final code = _otpCtrl.text.trim();
    if (code.length < 4) {
      setState(() => _errorMsg = 'Enter a valid OTP.');
      return;
    }
    setState(() {
      _isWorking = true;
      _errorMsg = null;
      _statusMsg = 'Deleting account permanently...';
    });
    final res = await ApiService().deleteCustomerAccount(
      phone: widget.phone,
      customerId: widget.customerId,
      authToken: widget.authToken,
      otp: code,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      _close(true);
      return;
    }
    setState(() {
      _isWorking = false;
      _errorMsg = res['error']?.toString() ?? 'OTP verification failed.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Confirm Account Deletion',
        style: TextStyle(
          fontSize: 16.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFF0F172A),
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_statusMsg != null)
              Text(
                _statusMsg!,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
              ),
            if (_isWorking) ...[
              const SizedBox(height: 16),
              const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
            if (!_isWorking && _needsOtp) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _otpCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Verification OTP',
                  hintText: '4-6 digit OTP',
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _triggerOtpRequest,
                  child: const Text('Resend OTP'),
                ),
              ),
            ],
            if (_errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorMsg!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isWorking ? null : () => _close(false),
          child: const Text('Cancel'),
        ),
        if (!_isWorking && _needsOtp)
          ElevatedButton(
            onPressed: _confirmDelete,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Confirm Delete'),
          ),
      ],
    );
  }
}
