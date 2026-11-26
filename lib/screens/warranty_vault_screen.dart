import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../utils/phone_normalizer.dart';
import '../widgets/bouncing_widget.dart';

class WarrantyVaultScreen extends StatefulWidget {
  final CartState cartState;

  const WarrantyVaultScreen({
    super.key,
    required this.cartState,
  });

  @override
  State<WarrantyVaultScreen> createState() => _WarrantyVaultScreenState();
}

class _WarrantyVaultScreenState extends State<WarrantyVaultScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  Map<String, dynamic>? _vaultData;

  @override
  void initState() {
    super.initState();
    _fetchWarrantyDetails();
  }

  Future<void> _fetchWarrantyDetails() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final cleanPhone = PhoneNormalizer.cleanPhone10(widget.cartState.userPhone);
    if (cleanPhone.length != 10) {
      if (!mounted) return;
      setState(() {
        _vaultData = null;
        _errorMessage = 'Log in with your registered mobile number to view warranty coverage & GST invoices.';
        _isLoading = false;
      });
      return;
    }

    final res = await ApiService().getWarrantyVault(cleanPhone);
    if (!mounted) return;

    if (res['success'] == true && res['purifier'] is Map) {
      setState(() {
        _vaultData = res;
        _errorMessage = null;
        _isLoading = false;
      });
    } else {
      setState(() {
        _vaultData = null;
        _errorMessage = (res['error'] ?? res['message'] ?? 'No active warranty record found for your account.').toString();
        _isLoading = false;
      });
    }
  }

  void _showInvoiceDialog(Map<String, dynamic> invoice) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.receipt_long_rounded, color: Color(0xFF0284C7), size: 24),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'GST Tax Invoice',
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
                        color: const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'PAID & CLEARED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF15803D),
                        ),
                      ),
                    ),
                  ],
                ),
            const SizedBox(height: 16),

            // Itemized Invoice Box
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  _buildInvoiceRow('Invoice Number', '${invoice['invoice_number'] ?? 'N/A'}'),
                  const SizedBox(height: 8),
                  _buildInvoiceRow('Invoice Date', '${invoice['invoice_date'] ?? 'N/A'}'),
                  if ((invoice['gstin'] ?? '').toString().trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildInvoiceRow('GSTIN', '${invoice['gstin']}'),
                  ],
                  if ((invoice['hsn_code'] ?? '').toString().trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildInvoiceRow('HSN / SAC Code', '${invoice['hsn_code']}'),
                  ],
                  const Divider(height: 18, thickness: 1, color: Color(0xFFE2E8F0)),
                  _buildInvoiceRow('Taxable Value', '₹${invoice['taxable_value'] ?? 0}'),
                  const SizedBox(height: 6),
                  _buildInvoiceRow('CGST (9%)', '₹${invoice['cgst_amount'] ?? 0}'),
                  const SizedBox(height: 6),
                  _buildInvoiceRow('SGST (9%)', '₹${invoice['sgst_amount'] ?? 0}'),
                  const Divider(height: 18, thickness: 1, color: Color(0xFFE2E8F0)),
                  _buildInvoiceRow(
                    'Total Paid (All Inclusive)',
                    '₹${invoice['net_payable'] ?? 0}',
                    isBold: true,
                    highlight: true,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () async {
                  final rawUrl = (invoice['pdf_url'] ?? invoice['invoice_url'] ?? '').toString().trim();
                  final invNo = (invoice['invoice_number'] ?? '').toString().trim();
                  Navigator.pop(ctx);
                  if (rawUrl.isNotEmpty) {
                    final uri = Uri.tryParse(rawUrl);
                    if (uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                      return;
                    }
                  }
                  if (invNo.isNotEmpty) {
                    await Clipboard.setData(ClipboardData(text: invNo));
                  }
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        invNo.isNotEmpty
                            ? 'Invoice reference $invNo copied to clipboard.'
                            : 'Invoice PDF link is not available yet.',
                      ),
                      backgroundColor: const Color(0xFF0F172A),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: Icon(
                  ((invoice['pdf_url'] ?? invoice['invoice_url'] ?? '').toString().trim().isNotEmpty)
                      ? Icons.open_in_new_rounded
                      : Icons.copy_rounded,
                  size: 18,
                ),
                label: Text(
                  ((invoice['pdf_url'] ?? invoice['invoice_url'] ?? '').toString().trim().isNotEmpty)
                      ? 'Open Official GST PDF'
                      : 'Copy GST Invoice Number',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                ),
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildInvoiceRow(String label, String value, {bool isBold = false, bool highlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
              color: highlight ? const Color(0xFF0F172A) : const Color(0xFF64748B),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: isBold ? 14 : 12,
              fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
              color: highlight ? const Color(0xFF0284C7) : const Color(0xFF0F172A),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final purifier = _vaultData?['purifier'] as Map<String, dynamic>?;
    final invoice = _vaultData?['tax_invoice'] as Map<String, dynamic>?;
    final components = (purifier?['components'] as List<dynamic>?) ?? [];
    final daysRemaining = (purifier?['days_remaining'] is num)
        ? (purifier!['days_remaining'] as num).toInt()
        : (int.tryParse(purifier?['days_remaining']?.toString() ?? '') ?? 0);
    final totalDays = (purifier?['total_warranty_days'] is num)
        ? (purifier!['total_warranty_days'] as num).toInt()
        : (int.tryParse(purifier?['total_warranty_days']?.toString() ?? '') ?? 365);
    final double progress = totalDays > 0 ? (daysRemaining / totalDays).clamp(0.0, 1.0) : 0.0;
    final bool isWarrantyActive = daysRemaining > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Warranty Vault',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: -0.3,
              ),
            ),
            Text(
              '🛡️ Drop Technologies Genuine Hardware Protection',
              style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFF0284C7)),
            onPressed: _fetchWarrantyDetails,
            tooltip: 'Refresh Warranty Status',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF0284C7), strokeWidth: 2.5),
                  SizedBox(height: 12),
                  Text(
                    'Loading Hardware Warranty Vault...',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            )
          : (_errorMessage != null || purifier == null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.verified_user_outlined, size: 48, color: Color(0xFF94A3B8)),
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage ?? 'No active warranty record found.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _fetchWarrantyDetails,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              physics: const BouncingScrollPhysics(),
              children: [
                // 1. Primary Active Purifier Glassy Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x06000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
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
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.water_drop_rounded, color: Color(0xFF0284C7), size: 24),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${purifier['brand'] ?? 'Registered RO'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0284C7),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      Text(
                                        '${purifier['model_name'] ?? 'RO Water Purifier'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF0F172A),
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isWarrantyActive ? const Color(0xFFDCFCE7) : const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isWarrantyActive ? const Color(0xFFBBF7D0) : const Color(0xFFFECACA),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isWarrantyActive ? Icons.verified_rounded : Icons.error_outline_rounded,
                                  size: 12,
                                  color: isWarrantyActive ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isWarrantyActive ? 'ACTIVE' : 'EXPIRED',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: isWarrantyActive ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Device Serial Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.qr_code_2_rounded, size: 14, color: Color(0xFF64748B)),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Device Serial: ${purifier['serial_number'] ?? 'N/A'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF334155),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
                      const SizedBox(height: 14),

                      // 2. 365-Day Warranty Countdown Bar
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Row(
                              children: [
                                Icon(Icons.verified_user_outlined, size: 16, color: Color(0xFF16A34A)),
                                SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '365-Day Official Warranty',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$daysRemaining Days Left',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF16A34A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 9,
                          backgroundColor: const Color(0xFFE2E8F0),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF16A34A)),
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Active Protection: ${(progress * 100).toInt()}% Life Remaining',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Drop Technologies SLA',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFF0284C7)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 3. Constituent Child Filters Breakdown
                const Text(
                  'INSTALLED GENUINE COMPONENTS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF64748B),
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 10),

                ...components.map((comp) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.shield_outlined, color: Color(0xFF16A34A), size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${comp['name'] ?? 'Filter Component'}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Serial: ${comp['serial'] ?? 'N/A'} • SKU: ${comp['sku'] ?? 'N/A'}',
                                style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${comp['days_remaining'] ?? daysRemaining}d remaining',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF15803D),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              '100% Genuine',
                              style: TextStyle(fontSize: 9.5, color: Color(0xFF16A34A), fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),

                const SizedBox(height: 14),

                // 4. 1-Click GST Tax Invoice Card
                if (invoice != null)
                  Builder(
                    builder: (context) {
                      final inv = invoice;
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
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
                                      Icon(Icons.verified_rounded, color: Color(0xFF0284C7), size: 18),
                                      SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          'Tax Clearance & Invoice',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '${inv['invoice_number'] ?? 'N/A'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Official 18% GST input tax credit available for commercial & residential customers.',
                              style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: BouncingWidget(
                                onTap: () => _showInvoiceDialog(inv),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.download_rounded, color: Colors.white, size: 16),
                                      SizedBox(width: 8),
                                      Text(
                                        '1-Click GST Tax Invoice Download',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.bold,
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
                    },
                  ),
              ],
            ),
    );
  }
}
