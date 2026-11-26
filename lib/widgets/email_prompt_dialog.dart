import 'package:flutter/material.dart';
import '../state/cart_state.dart';

/// Shared Apple-style modal popup with top-right cross button for capturing or editing
/// the customer's email address for Online Order updates & invoices.
Future<void> showOrderEmailPromptDialog(
  BuildContext context, {
  required CartState cartState,
  String? orderNumber,
  String titleText = 'Order Notification Email',
  String subtitleText =
      'Receive instant email updates for Order Confirmed, Shipped (AWB), Out for Delivery, and Delivered.',
}) async {
  if (!cartState.isLoggedIn) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Please log in with WhatsApp first to add an order alert email.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  final rootMessenger = ScaffoldMessenger.maybeOf(context);
  final emailCtrl = TextEditingController(text: cartState.userEmail ?? '');
  final bool isPostOrderPrompt = orderNumber != null && orderNumber.trim().isNotEmpty;
  bool saving = false;
  String? errorMsg;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2FE),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.mark_email_read_outlined,
                size: 18,
                color: Color(0xFF0284C7),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                titleText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('email_prompt_close_btn'),
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              onPressed: saving ? null : () => Navigator.pop(dialogCtx),
              icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF64748B)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleText,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.35),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              enabled: !saving,
              decoration: InputDecoration(
                labelText: 'Email Address',
                hintText: 'name@example.com',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMsg!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: saving
                ? null
                : () async {
                    final trimmed = emailCtrl.text.trim();
                    if (isPostOrderPrompt && trimmed.isEmpty) {
                      setDialogState(() => errorMsg = 'Enter an email address or tap × to close.');
                      return;
                    }
                    if (trimmed.isNotEmpty && !CartState.isValidNotificationEmail(trimmed)) {
                      setDialogState(() => errorMsg = 'Enter a valid email address (e.g. name@domain.com).');
                      return;
                    }
                    setDialogState(() {
                      saving = true;
                      errorMsg = null;
                    });
                    final res = await cartState.updateUserEmail(
                      trimmed,
                      orderNumber: orderNumber,
                    );
                    if (!dialogCtx.mounted) return;
                    if (res['success'] == true) {
                      Navigator.pop(dialogCtx);
                      rootMessenger?.showSnackBar(
                        SnackBar(
                          content: Text(
                            trimmed.isEmpty
                                ? 'Notification email cleared.'
                                : 'Email saved! Order updates will also be sent there.',
                          ),
                          backgroundColor: const Color(0xFF16A34A),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    } else {
                      setDialogState(() {
                        saving = false;
                        errorMsg = (res['message'] ?? res['error'] ?? 'Could not save email. Please retry.').toString();
                      });
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0071E3),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 42),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
            ),
            child: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    isPostOrderPrompt ? 'Save & Get Updates' : 'Save Email',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
          ),
        ],
      ),
    ),
  );
  emailCtrl.dispose();
}

