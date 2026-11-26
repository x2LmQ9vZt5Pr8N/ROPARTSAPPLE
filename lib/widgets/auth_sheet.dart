import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/local_cache_vault.dart';
import '../state/cart_state.dart';
import '../theme/app_theme.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';

enum AuthStep { phone, otp, name }

class AuthSheet extends StatefulWidget {
  final CartState cartState;
  final VoidCallback? onAuthSuccess;

  const AuthSheet({
    super.key,
    required this.cartState,
    this.onAuthSuccess,
  });

  static Future<void> show(BuildContext context, {required CartState cartState, VoidCallback? onAuthSuccess}) {
    if (cartState.isLoggedIn) {
      onAuthSuccess?.call();
      return Future.value();
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AuthSheet(
        cartState: cartState,
        onAuthSuccess: onAuthSuccess,
      ),
    );
  }

  @override
  State<AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends State<AuthSheet> with WidgetsBindingObserver {
  // Navigation / Wizard step
  AuthStep _step = AuthStep.phone;

  // Controllers
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  // Focus Nodes & Visibility Keys
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _otpFocus = FocusNode();
  final FocusNode _nameFocus = FocusNode();
  final GlobalKey _phoneFieldKey = GlobalKey();
  final GlobalKey _otpFieldKey = GlobalKey();
  final GlobalKey _nameFieldKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  // State
  bool _isLoading = false;
  bool _isOtpVerifiedLocked = false;
  bool _authCompleted = false;
  String? _lastAutoSubmittedOtp;
  String? _errorMessage;
  int _resendCountdown = 60;
  Timer? _countdownTimer;

  // Temporary auth payload after OTP verification
  String? _verifiedToken;
  String? _verifiedRefreshToken;
  int? _verifiedExpiresIn;
  Map<String, dynamic>? _verifiedCustomer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachFocusScroll(_phoneFocus, _phoneFieldKey);
    _attachFocusScroll(_otpFocus, _otpFieldKey);
    _attachFocusScroll(_nameFocus, _nameFieldKey);
    // Close immediately if user session is already active (prevents duplicate verify prompts)
    if (widget.cartState.isLoggedIn) {
      _authCompleted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _dismissSheetOnly());
      return;
    }
    // Prefill phone if already exists
    if (widget.cartState.userPhone.isNotEmpty) {
      _phoneController.text = PhoneNormalizer.cleanPhone10(widget.cartState.userPhone);
    }
    _restorePendingAuthIfAny();
  }

  Future<void> _restorePendingAuthIfAny() async {
    if (widget.cartState.isLoggedIn || _authCompleted) {
      _dismissSheetOnly();
      return;
    }
    final pendingPhone = await LocalCacheVault.getPendingAuthPhone();
    final pendingTs = await LocalCacheVault.getPendingAuthTimestamp();
    if (!mounted || widget.cartState.isLoggedIn || _authCompleted) return;
    if (pendingPhone != null && pendingTs != null) {
      final elapsed = (DateTime.now().millisecondsSinceEpoch - pendingTs) ~/ 1000;
      if (elapsed < 300) {
        setState(() {
          _phoneController.text = pendingPhone;
          _step = AuthStep.otp;
          _errorMessage = null;
        });
        _startResendTimer(initialSeconds: (60 - elapsed).clamp(0, 60));
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_authCompleted && _step == AuthStep.otp) _otpFocus.requestFocus();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.cartState.isLoggedIn || _authCompleted) {
        _dismissSheetOnly();
        return;
      }
      if (_step == AuthStep.otp) {
        LocalCacheVault.getPendingAuthTimestamp().then((ts) {
          if (ts != null && mounted && !_authCompleted && _step == AuthStep.otp) {
            final elapsed = (DateTime.now().millisecondsSinceEpoch - ts) ~/ 1000;
            final remaining = (60 - elapsed).clamp(0, 60);
            _startResendTimer(initialSeconds: remaining);
            _otpFocus.requestFocus();
          }
        });
      }
    }
  }

  void _dismissSheetOnly() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    } else if (navigator.canPop()) {
      navigator.pop();
    }
  }

  Future<void> _completeAndDismissAuth({required String welcomeName}) async {
    _authCompleted = true;
    await LocalCacheVault.clearPendingAuth();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            const Icon(Icons.verified_user_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Welcome, $welcomeName!',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
    final onSuccess = widget.onAuthSuccess;
    _dismissSheetOnly();
    onSuccess?.call();
  }

  void _attachFocusScroll(FocusNode node, GlobalKey key) {
    node.addListener(() {
      if (!node.hasFocus) return;
      Future.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
          return;
        }
        final ctx = key.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.4,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _scrollController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _phoneFocus.dispose();
    _otpFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _startResendTimer({int initialSeconds = 60}) {
    _resendCountdown = initialSeconds;
    _countdownTimer?.cancel();
    if (_resendCountdown <= 0) {
      if (mounted) setState(() {});
      return;
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCountdown > 0) {
        if (mounted) setState(() => _resendCountdown--);
      } else {
        timer.cancel();
      }
    });
  }

  // STEP 1: Send WhatsApp OTP
  Future<void> _handleSendOtp() async {
    if (_isLoading) return;
    final rawPhone = PhoneNormalizer.cleanPhone10(_phoneController.text);
    if (rawPhone.length != 10) {
      setState(() => _errorMessage = 'Please enter a valid 10-digit mobile number');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await ApiService().sendCustomerOtp(rawPhone);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      await LocalCacheVault.savePendingAuth(rawPhone);
      if (!mounted) return;
      setState(() {
        _step = AuthStep.otp;
        _errorMessage = null;
      });
      _startResendTimer();
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _otpFocus.requestFocus();
      });
    } else {
      setState(() {
        _errorMessage = res['error'] ?? 'Failed to send OTP. Please try again.';
      });
    }
  }

  // STEP 2: Verify OTP
  Future<void> _handleVerifyOtp() async {
    if (_isLoading || _isOtpVerifiedLocked || _authCompleted) return;
    if (widget.cartState.isLoggedIn) {
      _dismissSheetOnly();
      return;
    }

    final rawPhone = PhoneNormalizer.cleanPhone10(_phoneController.text);
    final otp = _otpController.text.trim();

    if (otp.length != 4) {
      setState(() => _errorMessage = 'Please enter the 4-digit verification code');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await ApiService().verifyCustomerOtp(phone: rawPhone, otp: otp);

    if (!mounted) return;

    if (res['success'] == true) {
      _isOtpVerifiedLocked = true;
      _countdownTimer?.cancel();

      final token = res['token'] as String?;
      final refreshToken = res['refresh_token'] as String?;
      final expiresIn = res['expires_in'] as int?;
      final customer = res['customer'] as Map<String, dynamic>?;
      final isNew = res['is_new'] == true;

      final existingName = customer?['full_name']?.toString().trim();
      final hasRealName = existingName != null &&
          existingName.isNotEmpty &&
          existingName.toLowerCase() != 'valued customer' &&
          existingName.toLowerCase() != 'customer';

      if (!isNew && hasRealName) {
        // Keep _isLoading = true while persisting session and closing sheet
        await widget.cartState.login(
          name: existingName,
          phone: rawPhone,
          token: token,
          refreshToken: refreshToken,
          expiresInSeconds: expiresIn,
          customerId: customer?['id']?.toString(),
          email: customer?['email']?.toString(),
          defaultAddress: customer?['default_address']?.toString(),
          defaultPincode: customer?['default_pincode']?.toString(),
        );
        if (!mounted) return;
        await _completeAndDismissAuth(welcomeName: existingName);
      } else {
        // NOT YET MADE ACCOUNT OR NAME MISSING -> Ask for full name
        _verifiedToken = token;
        _verifiedRefreshToken = refreshToken;
        _verifiedExpiresIn = expiresIn;
        _verifiedCustomer = customer;
        setState(() {
          _isLoading = false;
          _step = AuthStep.name;
          _errorMessage = null;
        });
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_authCompleted) _nameFocus.requestFocus();
        });
      }
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = res['error'] ?? 'Invalid verification code. Please check and retry.';
      });
    }
  }

  // STEP 3: Save Name & Complete Registration
  Future<void> _handleSaveName() async {
    if (_isLoading || _authCompleted) return;
    final name = _nameController.text.trim();
    if (name.length < 2) {
      setState(() => _errorMessage = 'Please enter your name');
      return;
    }

    final rawPhone = PhoneNormalizer.cleanPhone10(_phoneController.text);

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Update profile on live backend while keeping loading lock until sheet closes
    final res = await ApiService().updateProfile(
      phone: rawPhone,
      fullName: name,
      customerId: _verifiedCustomer?['id']?.toString(),
    );

    if (!mounted) return;

    if (res['success'] != true) {
      setState(() {
        _isLoading = false;
        _errorMessage = (res['error'] ?? res['message'] ?? 'Could not save your name. Please try again.').toString();
      });
      return;
    }

    await widget.cartState.login(
      name: name,
      phone: rawPhone,
      token: _verifiedToken,
      refreshToken: _verifiedRefreshToken,
      expiresInSeconds: _verifiedExpiresIn,
      customerId: _verifiedCustomer?['id']?.toString(),
      email: _verifiedCustomer?['email']?.toString(),
      defaultAddress: _verifiedCustomer?['default_address']?.toString(),
      defaultPincode: _verifiedCustomer?['default_pincode']?.toString(),
    );
    if (!mounted) return;
    await _completeAndDismissAuth(welcomeName: name);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom;
    final availableHeight = (media.size.height - bottomInset).clamp(0.0, media.size.height);
    final bool isCompactSheet = availableHeight < 540;
    final double usableHeight = (availableHeight * (isCompactSheet ? 0.96 : 0.90))
        .clamp(availableHeight < 210.0 ? availableHeight : 210.0, media.size.height);

    return PopScope(
      canPop: _authCompleted || _step != AuthStep.otp,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _step == AuthStep.otp) {
          // Keep active while switching to WhatsApp; if user wants to change, they can tap 'Edit' or 'Close'
        }
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 500,
            maxHeight: usableHeight,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
            isCompactSheet ? 18 : 20,
            isCompactSheet ? 8 : 10,
            isCompactSheet ? 18 : 20,
            isCompactSheet ? 12 : 20,
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: EdgeInsets.only(bottom: isCompactSheet ? 8 : 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Top Header Row with Close
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_rounded, size: 12, color: Color(0xFF15803D)),
                            SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'WhatsApp Verification',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF15803D),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () async {
                        await LocalCacheVault.clearPendingAuth();
                        if (context.mounted) Navigator.pop(context);
                      },
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

                SizedBox(height: isCompactSheet ? 8 : 16),

                // Wizard Step Content
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _buildCurrentStepContent(compact: isCompactSheet),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildCurrentStepContent({required bool compact}) {
    switch (_step) {
      case AuthStep.phone:
        return _buildPhoneStep(compact: compact);
      case AuthStep.otp:
        return _buildOtpStep(compact: compact);
      case AuthStep.name:
        return _buildNameStep(compact: compact);
    }
  }

  // --- STEP 1: PHONE NUMBER ---
  Widget _buildPhoneStep({required bool compact}) {
    return Column(
      key: const ValueKey('step_phone'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Login or Sign Up',
          style: TextStyle(
            fontSize: compact ? 19 : 22,
            fontWeight: FontWeight.w900,
            color: const Color(0xFF0F172A),
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Enter your mobile number to receive a one-tap WhatsApp verification code.',
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFF64748B),
            height: 1.35,
          ),
        ),
        SizedBox(height: compact ? 12 : 20),

        // Phone Input Card
        Container(
          key: _phoneFieldKey,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _errorMessage != null ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              const Text(
                '🇮🇳 +91',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(width: 10),
              Container(width: 1, height: 24, color: const Color(0xFFCBD5E1)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _phoneController,
                  focusNode: _phoneFocus,
                  keyboardType: TextInputType.phone,
                  autofocus: !kIsWeb,
                  maxLength: 10,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                    letterSpacing: 1.0,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Enter 10-digit number',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF94A3B8),
                      letterSpacing: 0,
                    ),
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  onSubmitted: (_) => _handleSendOtp(),
                ),
              ),
            ],
          ),
        ),

        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, size: 14, color: Color(0xFFDC2626)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626), fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],

        SizedBox(height: compact ? 12 : 20),

        // Send OTP CTA
        BouncingWidget(
          onTap: _isLoading ? () {} : _handleSendOtp,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.appleBlue,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.appleBlue.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline_rounded, color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Get WhatsApp OTP',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  // --- STEP 2: OTP INPUT ---
  Widget _buildOtpStep({required bool compact}) {
    final rawPhone = _phoneController.text.trim();

    return Column(
      key: const ValueKey('step_otp'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter Verification Code',
          style: TextStyle(
            fontSize: compact ? 19 : 22,
            fontWeight: FontWeight.w900,
            color: const Color(0xFF0F172A),
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Code sent to +91 $rawPhone via WhatsApp',
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            GestureDetector(
              onTap: _isLoading
                  ? null
                  : () async {
                      _countdownTimer?.cancel();
                      await LocalCacheVault.clearPendingAuth();
                      if (!mounted) return;
                      setState(() {
                        _step = AuthStep.phone;
                        _isOtpVerifiedLocked = false;
                        _lastAutoSubmittedOtp = null;
                        _otpController.clear();
                        _errorMessage = null;
                      });
                    },
              child: const Text(
                'Edit',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.appleBlue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 12 : 20),

        // OTP Input Field (Strict 4-digit customer code)
        Container(
          key: _otpFieldKey,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _errorMessage != null ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
          ),
          child: TextField(
            controller: _otpController,
            focusNode: _otpFocus,
            keyboardType: TextInputType.number,
            autofocus: true,
            maxLength: 4,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
              letterSpacing: 12.0,
            ),
            decoration: const InputDecoration(
              hintText: '••••',
              hintStyle: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Color(0xFFCBD5E1),
                letterSpacing: 12.0,
              ),
              border: InputBorder.none,
              counterText: '',
            ),
            onChanged: (val) {
              if (val.length < 4) {
                _lastAutoSubmittedOtp = null;
                return;
              }
              if (val.length == 4 &&
                  !_isLoading &&
                  !_isOtpVerifiedLocked &&
                  !_authCompleted &&
                  val != _lastAutoSubmittedOtp) {
                _lastAutoSubmittedOtp = val;
                _handleVerifyOtp();
              }
            },
            onSubmitted: (_) {
              if (!_isLoading && !_isOtpVerifiedLocked && !_authCompleted) {
                _handleVerifyOtp();
              }
            },
          ),
        ),

        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, size: 14, color: Color(0xFFDC2626)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626), fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],

        SizedBox(height: compact ? 10 : 14),

        // Resend countdown
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_resendCountdown > 0)
              Text(
                'Resend OTP via WhatsApp in ${_resendCountdown}s',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), fontWeight: FontWeight.w600),
              )
            else
              GestureDetector(
                onTap: _isLoading ? null : _handleSendOtp,
                child: const Text(
                  'Resend OTP via WhatsApp',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF15803D),
                  ),
                ),
              ),
          ],
        ),

        SizedBox(height: compact ? 12 : 20),

        // Verify CTA
        BouncingWidget(
          onTap: _isLoading ? () {} : _handleVerifyOtp,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.appleBlue,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.appleBlue.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : const Text(
                    'Verify & Continue',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // --- STEP 3: NAME INPUT (IF NEW ACCOUNT) ---
  Widget _buildNameStep({required bool compact}) {
    return Column(
      key: const ValueKey('step_name'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What should we call you? 👋',
          style: TextStyle(
            fontSize: compact ? 19 : 22,
            fontWeight: FontWeight.w900,
            color: const Color(0xFF0F172A),
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Please enter your full name so our technicians know who to ask for.',
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFF64748B),
            height: 1.35,
          ),
        ),
        SizedBox(height: compact ? 12 : 20),

        // Name Input Field
        Container(
          key: _nameFieldKey,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _errorMessage != null ? const Color(0xFFEF4444) : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
          ),
          child: TextField(
            controller: _nameController,
            focusNode: _nameFocus,
            textCapitalization: TextCapitalization.words,
            autofocus: !kIsWeb,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
            decoration: const InputDecoration(
              hintText: 'Enter your full name (e.g. Rahul Sharma)',
              hintStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: Color(0xFF94A3B8),
              ),
              border: InputBorder.none,
            ),
            onSubmitted: (_) => _handleSaveName(),
          ),
        ),

        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, size: 14, color: Color(0xFFDC2626)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626), fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],

        SizedBox(height: compact ? 12 : 20),

        // Save & Finish CTA
        BouncingWidget(
          onTap: _isLoading ? () {} : _handleSaveName,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A), // Success green
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF16A34A).withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_rounded, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Complete Setup',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
