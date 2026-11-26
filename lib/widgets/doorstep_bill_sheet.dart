import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/doorstep_pricing.dart';
import '../services/qr_product_registry.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/phone_normalizer.dart';
import '../utils/unit_helper.dart';
import 'bouncing_widget.dart';

class DoorstepBillItem {
  final ScannedRoItem item;
  int quantity;

  DoorstepBillItem({required this.item, this.quantity = 1});

  double get totalPrice => item.price * quantity;
}

class DoorstepBillSheet extends StatefulWidget {
  final List<DoorstepBillItem> initialItems;
  final CartState cartState;
  final ServiceTrackingState? serviceState;
  final VoidCallback onScanMore;
  final VoidCallback? onPaymentComplete;

  const DoorstepBillSheet({
    super.key,
    this.initialItems = const [],
    required this.cartState,
    this.serviceState,
    required this.onScanMore,
    this.onPaymentComplete,
  });

  @override
  State<DoorstepBillSheet> createState() => _DoorstepBillSheetState();
}

class _DoorstepBillSheetState extends State<DoorstepBillSheet> {
  late List<DoorstepBillItem> _items;
  String? _appliedCouponCode;
  double _couponDiscount = 0.0;
  final double _technicianDirectFee = 49.0;
  bool _isProcessing = false;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _items = List<DoorstepBillItem>.from(widget.initialItems);
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  DoorstepFreeAllocation get _freeAllocation => DoorstepPricing.allocateFreeKitSpares(
        _items
            .map(
              (billItem) => DoorstepFreeItemInput(
                sku: billItem.item.sku,
                isKit: billItem.item.code == 'KIT-A001' || billItem.item.isKit,
                mrp: billItem.item.mrp,
                quantity: billItem.quantity,
                freeSpares: billItem.item.freeSpares,
                sealedFreeSpares: billItem.item.sealedFreeSpares,
                isExplicitComplimentary: billItem.item.isComplimentary,
              ),
            )
            .toList(),
      );

  DoorstepPriceBreakdown get _pricing => DoorstepPricing.calculate(
        totalMrp: _freeAllocation.billableMrp,
        couponDiscount: _couponDiscount,
        freeSparesMrp: _freeAllocation.freeSparesMrp,
      );

  double get _totalMrp => _pricing.totalMrp;

  double get _freeSparesSavings => _pricing.freeSparesMrp;

  double get _sealedFreeSparesValue {
    double total = 0.0;
    for (final billItem in _items) {
      if ((billItem.item.code == 'KIT-A001' || billItem.item.isKit) &&
          billItem.item.freeSpares.isNotEmpty) {
        final kitQty = billItem.quantity;
        for (final sp in billItem.item.freeSpares) {
          final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
          final u = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
          total += (q > 0 ? q : 1) * u * kitQty;
        }
      }
    }
    return total;
  }

  double get _maxDiscountAllowed => _pricing.maxDiscountAllowed;

  double get _effectiveDiscount => _pricing.effectiveDiscount;

  // Customer pays Total MRP (SUM of products) - Promo Discount; backend clears kit pouch to scrap.
  double get _inAppPayableAmount => _pricing.netPayable;

  void _openCouponPicker() {
    final customerId = widget.cartState.customerId ??
        (widget.cartState.userPhone.isNotEmpty ? widget.cartState.userPhone : null);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DoorstepCouponPickerSheet(
        customerId: customerId,
        totalMrp: _totalMrp,
        onApplied: (code, discount) {
          if (!mounted) return;
          setState(() {
            _appliedCouponCode = code;
            _couponDiscount = discount;
          });
        },
        onError: (msg) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red),
          );
        },
      ),
    );
  }

  /// Live CBM Doorstep Dynamic Checkout Initiation (Online Payment Only)
  Future<void> _processSparesPayment() async {
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your doorstep spares bill is empty.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (_pricing.isBelowGatewayMinimum) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(DoorstepPricing.belowGatewayMinimumMessage(_inAppPayableAmount)),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final customerId = PhoneNormalizer.toCustomerId(
      widget.cartState.customerId ?? widget.cartState.userPhone,
    );
    if (customerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please sign in before paying for spares.'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isProcessing = true);
    final visitId = int.tryParse(widget.serviceState?.bookingId ?? '0') ?? 0;

    late final Map<String, dynamic> res;
    try {
      res = await ApiService().initiateDoorstepCheckout(
        visitId: visitId,
        customerId: customerId,
        items: List<Map<String, dynamic>>.generate(_items.length, (idx) {
          final i = _items[idx];
          final isFree = _freeAllocation.isItemComplimentary(idx);
          return {
            'serial_qr': i.item.code,
            'type': i.item.type == QrItemType.kit ? 'KIT' : 'PRODUCT',
            if (i.item.sku != null && i.item.sku!.isNotEmpty) 'sku': i.item.sku,
            'qty': i.quantity,
            'mrp': i.item.mrp,
            if (isFree) 'is_complimentary': true,
          };
        }),
        couponCode: _appliedCouponCode,
        amount: _inAppPayableAmount,
        totalMrp: _totalMrp,
        discountAmount: _effectiveDiscount,
        allowZeroComplimentary: _pricing.isZeroComplimentary,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Checkout initiation failed: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    } finally {
      if (mounted && _isProcessing) {
        setState(() => _isProcessing = false);
      }
    }

    if (!mounted) return;

    if (res['success'] == true || res['status'] == 'APPROVED' || res['already_paid'] == true) {
      final rawPayable = res['breakdown']?['net_payable'];
      final payable = (rawPayable is num)
          ? rawPayable.toDouble()
          : (double.tryParse(rawPayable?.toString() ?? '') ?? _inAppPayableAmount);
      final refId = (res['order']?['order_number'] ?? res['order_id'] ?? res['cbm_checkout_token'] ?? '')
          .toString()
          .trim();

      if ((res['complimentary_zero_settled'] == true ||
              (res['already_paid'] == true && payable <= 0)) &&
          refId.isNotEmpty) {
        widget.onPaymentComplete?.call();
        _showPaymentSuccessDialog(refId: refId, paidAmount: 0);
        return;
      }

      final upiQrString =
          (res['upi_uri'] ?? res['payment_url'] ?? '').toString().trim();

      if (refId.isEmpty || upiQrString.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Payment link missing from server. Please retry.'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      _showDynamicUpiQrModal(
        refId: refId,
        upiQrString: upiQrString,
        payableAmount: payable,
        customerPhone: customerId,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['error'] ?? 'Checkout initiation failed. Please retry.'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Apple-Style Dynamic UPI QR Modal with Live Polling
  void _showDynamicUpiQrModal({
    required String refId,
    required String upiQrString,
    required double payableAmount,
    required String customerPhone,
  }) {
    _pollingTimer?.cancel();
    bool isPollingInFlight = false;
    int pollAttempts = 0;

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          // Start live polling every 2.5 seconds with concurrency & TTL guard
          _pollingTimer ??= Timer.periodic(const Duration(milliseconds: 2500), (timer) async {
            if (isPollingInFlight) return;
            pollAttempts++;
            if (pollAttempts > 240) {
              timer.cancel();
              if (ctx.mounted) Navigator.pop(ctx);
              return;
            }
            isPollingInFlight = true;
            try {
              final pollRes = await ApiService().checkCheckoutStatus(refId, live: true);
              final status = (pollRes['status'] ?? '').toString().trim().toUpperCase();
              final isPaid = pollRes['paid'] == true ||
                  pollRes['is_cleared'] == true ||
                  pollRes['already_paid'] == true ||
                  status == 'COMPLETED' ||
                  status == 'CLEARED' ||
                  status == 'PAID' ||
                  status == 'SETTLED';
              if (isPaid) {
                timer.cancel();
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
                if (mounted) {
                  widget.onPaymentComplete?.call();
                  _showPaymentSuccessDialog(refId: refId, paidAmount: payableAmount);
                }
                return;
              }
              if (pollRes['is_failed'] == true ||
                  pollRes['is_expired'] == true ||
                  pollRes['is_refunded'] == true ||
                  status == 'FAILED' ||
                  status == 'EXPIRED' ||
                  status == 'CANCELLED' ||
                  status == 'REFUNDED') {
                timer.cancel();
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              }
            } catch (_) {
            } finally {
              isPollingInFlight = false;
            }
          });

          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + MediaQuery.of(ctx).viewPadding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.qr_code_2_rounded, color: Color(0xFF0284C7), size: 24),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Scan Dynamic UPI QR',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'LIVE POLLING',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Scan using any UPI App or tap below to pay directly on this device',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 16),

                // Crisp Dynamic QR Code
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x08000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: upiQrString,
                    version: QrVersions.auto,
                    size: 200.0,
                    gapless: true,
                  ),
                ),

                const SizedBox(height: 14),

                Text(
                  'Amount to Pay: ₹${payableAmount.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Ref: $refId • UPI / QR Checkout',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),

                const SizedBox(height: 16),

                // 1-Tap UPI Apps Launcher
                Row(
                  children: [
                    _buildUpiAppButton('GPay', const Color(0xFF4285F4), () => _launchUpi(upiQrString)),
                    const SizedBox(width: 8),
                    _buildUpiAppButton('PhonePe', const Color(0xFF5F259F), () => _launchUpi(upiQrString)),
                    const SizedBox(width: 8),
                    _buildUpiAppButton('Paytm', const Color(0xFF00B9F5), () => _launchUpi(upiQrString)),
                  ],
                ),

                const SizedBox(height: 16),

                // Live Polling Indicator + Instant Verification Trigger
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0284C7)),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Waiting for payment confirmation from Central CBM...',
                          style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      _pollingTimer?.cancel();
      _pollingTimer = null;
    });
  }

  Widget _buildUpiAppButton(String name, Color color, VoidCallback onTap) {
    return Expanded(
      child: BouncingWidget(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          alignment: Alignment.center,
          child: Text(
            name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launchUpi(String uri) async {
    final parsed = Uri.parse(uri);
    if (await canLaunchUrl(parsed)) {
      await launchUrl(parsed, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open external UPI app directly. Please scan the QR code above.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showPaymentSuccessDialog({required String refId, required double paidAmount}) {
    final invoiceNumber = 'ROP-GST-2026-${refId.replaceAll(RegExp(r'\D'), '').padRight(4, '0').substring(0, 4)}';

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(22, 16, 22, 24 + MediaQuery.viewPaddingOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Color(0xFFDCFCE7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF16A34A),
                  size: 38,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Spares Payment Verified!',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '₹${paidAmount.toStringAsFixed(0)} cleared via CBM Central Clearinghouse',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),

              // Digital Tax Invoice card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Tax Invoice $invoiceNumber',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0F172A)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'GST PAID & CLEARED',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF0284C7)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final specLabels = _items
                            .map((bi) => CbmSpecHelper.resolveItemSpec(bi.item.toJson()))
                            .map((s) => s.shortBadge ?? s.primaryRatingLabel)
                            .whereType<String>()
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toSet()
                            .toList();
                        final countLabel =
                            '${_items.length} ${_items.length == 1 ? 'item' : 'items'} verified';
                        final summaryLine = specLabels.isNotEmpty
                            ? '$countLabel • ${specLabels.join(' • ')}'
                            : '$countLabel • Factory seal cleared';
                        return Text(
                          summaryLine,
                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
                        );
                      },
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 14),

            // Direct technician reminder
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.handshake_rounded, color: Color(0xFFD97706), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hand Over ₹${_technicianDirectFee.toStringAsFixed(0)} to Partner Technician',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF92400E),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Please pay the ₹${_technicianDirectFee.toStringAsFixed(0)} visit/service fee directly to the technician via Cash or personal UPI.',
                          style: const TextStyle(fontSize: 11, color: Color(0xFFB45309), height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Done & Close Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () {
                  Navigator.pop(ctx); // close success
                  Navigator.pop(context); // close bill sheet
                  widget.onPaymentComplete?.call();
                },
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text('Done & Return to Home', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: Column(
        children: [
          // 1. Top grab handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 2. Sheet Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF0284C7), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Doorstep Spares Bill',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.3,
                              ),
                            ),
                            Text(
                              'Drop Technologies Certified Parts',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Color(0xFF64748B)),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

          // 3. Scrollable Content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              physics: const BouncingScrollPhysics(),
              children: [
                // "🛡️ Verified Genuine Drop Technologies Part" Badge
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF0FDF4), Color(0xFFECFDF5)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF86EFAC), width: 1.2),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.verified_user_rounded, color: Color(0xFF16A34A), size: 24),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '🛡️ Verified Genuine Drop Technologies Part',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF15803D),
                                letterSpacing: 0.2,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Factory Sealed Hologram • 365-Day Direct Replacement Guarantee',
                              style: TextStyle(fontSize: 10.5, color: Color(0xFF166534)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Scanned Spares Section Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'SCANNED HARDWARE (${_items.length})',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF64748B),
                        letterSpacing: 0.6,
                      ),
                    ),
                    BouncingWidget(
                      onTap: widget.onScanMore,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_rounded, size: 14, color: Color(0xFF0284C7)),
                            SizedBox(width: 4),
                            Text(
                              '+ Scan More',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF0284C7)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Scanned items list with Nested Constituent Child Filters
                ...List.generate(_items.length, (index) {
                  final billItem = _items[index];
                  final item = billItem.item;
                  final isKit = item.code == 'KIT-A001' || item.isKit;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x04000000),
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Product Thumbnail
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.all(4),
                              child: Image.asset(
                                item.imageAsset,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) => const Icon(
                                  Icons.build_circle_outlined,
                                  color: Color(0xFF0284C7),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),

                            // Product details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isKit ? const Color(0xFFEFF6FF) : const Color(0xFFF0FDF4),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          isKit
                                              ? 'SERVICE KIT'
                                              : (_freeAllocation.isItemComplimentary(index)
                                                  ? 'FREE WITH KIT • ₹0'
                                                  : 'GENUINE SPARE'),
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w900,
                                            color: isKit ? const Color(0xFF0284C7) : const Color(0xFF16A34A),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        item.code,
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF94A3B8),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  Builder(
                                    builder: (_) {
                                      final spec = CbmSpecHelper.resolveItemSpec(item.toJson());
                                      final parts = <String>[
                                        if (spec.shortBadge != null)
                                          spec.shortBadge!
                                        else if (item.warranty.trim().isNotEmpty)
                                          item.warranty.trim(),
                                        if (item.batchNumber.trim().isNotEmpty)
                                          item.batchNumber.trim(),
                                      ];
                                      if (parts.isEmpty) return const SizedBox.shrink();
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          parts.join(' • '),
                                          style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        // Nested Constituent Child Filters for KIT-A001
                        if (isKit) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.account_tree_outlined, size: 14, color: Color(0xFF0284C7)),
                                    SizedBox(width: 6),
                                    Text(
                                      'CONSTITUENT CHILD FILTERS (2-STAGE SEAL)',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF0284C7),
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                ...item.rawComponents.where((comp) => comp['is_complimentary'] != true).map((comp) {
                                  final cName = (comp['name'] ?? comp['component_name'] ?? 'Spare Component').toString();
                                  final cDesc = (comp['description'] ?? comp['sku'] ?? 'Genuine kit part').toString();
                                  final cMrp = (comp['mrp'] is num)
                                      ? (comp['mrp'] as num).toDouble()
                                      : (double.tryParse(comp['mrp']?.toString() ?? '') ?? 0.0);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: _buildChildComponentRow(cName, cDesc, cMrp),
                                  );
                                }),
                                if (item.rawComponents.isEmpty)
                                  ...item.bundledItems.map(
                                    (partDesc) => Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: _buildChildComponentRow(partDesc, 'Included in verified kit', 0.0),
                                    ),
                                  ),
                                if (item.freeSpares.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFECFDF5),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFFA7F3D0)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '🎁 SEALED FREE SPARES INSIDE POUCH (₹0)',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFF047857),
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        ...item.freeSpares.map((sp) {
                                          final q = (int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1) * billItem.quantity;
                                          final uMrp = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
                                          final worth = q * uMrp;
                                          return Padding(
                                            padding: const EdgeInsets.only(bottom: 3),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    ProductUnitHelper.formatBomOrFreeName(
                                                      Map<String, dynamic>.from(sp),
                                                      multiplier: billItem.quantity,
                                                    ),
                                                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF065F46)),
                                                  ),
                                                ),
                                                Text(
                                                  worth > 0 ? 'Worth ₹${DoorstepPricing.formatRupees(worth)} FREE' : 'FREE',
                                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                                                ),
                                              ],
                                            ),
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                ],
                                const Divider(height: 14, thickness: 0.8, color: Color(0xFFE2E8F0)),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Verified Kit MRP Total:',
                                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                                    ),
                                    Text(
                                      '₹${DoorstepPricing.formatRupees(item.mrp * billItem.quantity)}',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),

                // Doorstep Coupon Selector (Managed by RO Admin: Technician Channel, 85% Max Cap)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _appliedCouponCode != null ? const Color(0xFF16A34A) : const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _appliedCouponCode != null ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.local_offer_rounded, color: _appliedCouponCode != null ? const Color(0xFF16A34A) : const Color(0xFF64748B), size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _appliedCouponCode != null ? 'Coupon Applied: $_appliedCouponCode' : 'Apply Doorstep Coupon',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: _appliedCouponCode != null ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
                              ),
                            ),
                            Text(
                              _appliedCouponCode != null 
                                  ? 'Saved ₹${_effectiveDiscount.toStringAsFixed(2)}'
                                  : 'Select technician offers or enter promo code',
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                      if (_appliedCouponCode != null)
                        TextButton(
                          onPressed: () => setState(() {
                            _appliedCouponCode = null;
                            _couponDiscount = 0.0;
                          }),
                          child: const Text('Remove', style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold)),
                        )
                      else
                        TextButton(
                          onPressed: _openCouponPicker,
                          child: const Text('Apply', style: TextStyle(color: Color(0xFF0284C7), fontSize: 12.5, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // Itemized Pricing Card (Customer Kit MRP = SUM of products)
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
                        'PRICE BREAKDOWN',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text('Total Product MRP', style: TextStyle(fontSize: 12.5, color: Color(0xFF475569))),
                          ),
                          const SizedBox(width: 8),
                          Text('₹${_totalMrp.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                        ],
                      ),
                      if (_freeSparesSavings > 0) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Text(
                                'Free Kit Spares Allowance (₹0)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12.5, color: Color(0xFF16A34A)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('FREE (-₹${_freeSparesSavings.toStringAsFixed(2)})', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                          ],
                        ),
                      ] else if (_sealedFreeSparesValue > 0) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                'Sealed Free Kit Spares (Worth ₹${_sealedFreeSparesValue.toStringAsFixed(2)})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: Color(0xFF047857), fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('₹0 FREE', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                          ],
                        ),
                      ],
                      if (_effectiveDiscount > 0) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                'Promotional Discount (${_appliedCouponCode ?? "Coupon"})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: Color(0xFF16A34A)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('-₹${_effectiveDiscount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text('18% GST Statutory Tax', style: TextStyle(fontSize: 12.5, color: Color(0xFF475569))),
                          ),
                          SizedBox(width: 8),
                          Text('INCLUDED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0284C7))),
                        ],
                      ),
                      const Divider(height: 16, thickness: 1, color: Color(0xFFF1F5F9)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Net Online Payable', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                                Text('Online Gateway Only (No Cash)', style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('₹${_inAppPayableAmount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0284C7))),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // Dedicated Separate Partner Technician Advisory Card
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFDE68A), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFDE68A),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.handshake_rounded, color: Color(0xFFB45309), size: 16),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Direct Partner Technician Fee',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFB45309),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '₹${_technicianDirectFee.toStringAsFixed(0)} CASH/UPI',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '• Hand over ₹${_technicianDirectFee.toStringAsFixed(0)} directly to your assigned partner technician.\n• ROParts does not deduct commission from technician service fees.',
                        style: const TextStyle(fontSize: 10.5, color: Color(0xFF92400E), height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 4. Fixed Bottom Action Bar: Initiates CBM Dynamic Checkout
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 0.8)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Net Payable',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                      Text(
                        '₹${DoorstepPricing.formatRupees(_inAppPayableAmount)}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        onPressed: _isProcessing ? null : _processSparesPayment,
                        child: _isProcessing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.qr_code_scanner_rounded, size: 18),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _pricing.isZeroComplimentary
                                          ? 'Confirm Free Kit Spares (₹0)'
                                          : 'Generate Dynamic UPI QR (₹${DoorstepPricing.formatRupees(_inAppPayableAmount)})',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
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
        ],
      ),
    );
  }

  Widget _buildChildComponentRow(String serial, String name, double price) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  serial,
                  style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '₹${price.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
        ),
      ],
    );
  }
}

/// Self-owning coupon picker bottom sheet so [TextEditingController] disposal waits
/// until the sheet closing animation finishes and unmounts [TextField].
class _DoorstepCouponPickerSheet extends StatefulWidget {
  final String? customerId;
  final double totalMrp;
  final void Function(String? code, double discount) onApplied;
  final void Function(String message) onError;

  const _DoorstepCouponPickerSheet({
    required this.customerId,
    required this.totalMrp,
    required this.onApplied,
    required this.onError,
  });

  @override
  State<_DoorstepCouponPickerSheet> createState() =>
      _DoorstepCouponPickerSheetState();
}

class _DoorstepCouponPickerSheetState
    extends State<_DoorstepCouponPickerSheet> {
  final TextEditingController _couponInputCtrl = TextEditingController();
  late final Future<List<Map<String, dynamic>>> _couponsFuture;

  @override
  void initState() {
    super.initState();
    _couponsFuture = ApiService().getCoupons(
      channel: 'TECHNICIAN',
      customerId: widget.customerId,
    );
  }

  @override
  void dispose() {
    _couponInputCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyCode() async {
    final code = _couponInputCtrl.text.trim();
    if (code.isEmpty) return;
    final res = await ApiService().validateCoupon(
      code: code,
      channel: 'TECHNICIAN',
      amount: widget.totalMrp,
      mrp: widget.totalMrp,
      customerId: widget.customerId,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      final d = res['discount'];
      final discount = (d is num)
          ? d.toDouble()
          : (double.tryParse(d?.toString() ?? '') ?? 0.0);
      widget.onApplied(res['code']?.toString(), discount);
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.pop(context);
    } else {
      widget.onError(res['error']?.toString() ?? 'Invalid coupon');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Apply Doorstep Coupon',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Exclusive technician & promo discounts applied at checkout',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _couponInputCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'Enter promo code (e.g. DOORSTEP85)',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF94A3B8),
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF0284C7),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                ),
                onPressed: _applyCode,
                child: const Text(
                  'Apply',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _couponsFuture,
            builder: (context, snapshot) {
              final coupons = snapshot.data ?? [];
              if (coupons.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Public Technician Offers:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF475569),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...coupons.map((c) {
                    final minOrder =
                        double.tryParse((c['min_order_value'] ?? '0').toString()) ??
                            0;
                    final isExhausted = c['is_exhausted'] == true;
                    final meetsMin = widget.totalMrp >= minOrder;
                    final isUsable = !isExhausted && meetsMin;
                    return Opacity(
                      opacity: isUsable ? 1.0 : 0.45,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isUsable
                              ? const Color(0xFFF0FDF4)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isUsable
                                ? const Color(0xFFBBF7D0)
                                : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.local_offer_rounded,
                              color: isUsable
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFF94A3B8),
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c['code'] ?? '',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: isUsable
                                          ? const Color(0xFF16A34A)
                                          : const Color(0xFF64748B),
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    isExhausted
                                        ? 'Already redeemed on your account'
                                        : (meetsMin
                                            ? (c['description'] ?? '')
                                            : 'Requires minimum order of ₹${minOrder.toInt()}'),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isUsable
                                          ? const Color(0xFF475569)
                                          : const Color(0xFF94A3B8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: isUsable
                                  ? () {
                                      _couponInputCtrl.text =
                                          (c['code'] ?? '').toString();
                                    }
                                  : null,
                              child: Text(
                                isExhausted ? 'Used' : 'Use',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: isUsable
                                      ? const Color(0xFF0284C7)
                                      : const Color(0xFFCBD5E1),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
