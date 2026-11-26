import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/display_sanitizer.dart';
import '../utils/happy_hour_helper.dart';
import '../utils/phone_normalizer.dart';
import 'bouncing_widget.dart';
import 'technician_rating_widgets.dart';

class ServiceHistorySheet extends StatefulWidget {
  final VoidCallback onBookServiceTap;
  final ServiceTrackingState? serviceState;
  final CartState? cartState;
  final VoidCallback? onTrackServiceTap;

  const ServiceHistorySheet({
    super.key,
    required this.onBookServiceTap,
    this.serviceState,
    this.cartState,
    this.onTrackServiceTap,
  });

  @override
  State<ServiceHistorySheet> createState() => _ServiceHistorySheetState();
}

class _ServiceHistorySheetState extends State<ServiceHistorySheet> {
  final List<Map<String, dynamic>> _visits = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  int _totalVisits = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadHistory(refresh: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        !_isLoadingMore &&
        _hasMore) {
      _loadHistory();
    }
  }

  Future<void> _loadHistory({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _page = 1;
        _hasMore = true;
        _isLoading = true;
        _isLoadingMore = false;
        _errorMessage = null;
      });
    } else {
      if (_isLoadingMore || !_hasMore) return;
      setState(() => _isLoadingMore = true);
    }

    final rawId = (widget.cartState?.customerId?.isNotEmpty == true)
        ? widget.cartState!.customerId!
        : (widget.cartState?.userPhone.isNotEmpty == true
            ? widget.cartState!.userPhone
            : (widget.serviceState?.receiverPhone ?? ''));
    final customerId = PhoneNormalizer.toCustomerId(rawId);
    if (customerId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _visits.clear();
        _totalVisits = 0;
        _hasMore = false;
        _isLoading = false;
        _isLoadingMore = false;
      });
      return;
    }

    try {
      final res = await ApiService().getServiceHistoryPage(
        customerId: customerId,
        page: _page,
        limit: 10,
      );
      if (!mounted) return;
      if (res['success'] == true) {
        final list = (res['visits'] is List)
            ? List<Map<String, dynamic>>.from(res['visits'] as List)
            : <Map<String, dynamic>>[];
        setState(() {
          if (refresh) {
            _visits.clear();
          }
          _visits.addAll(list);
          final reportedTotal = int.tryParse('${res['total'] ?? ''}') ?? _visits.length;
          _totalVisits = reportedTotal > _visits.length ? reportedTotal : _visits.length;
          _hasMore = res['has_more'] == true;
          if (_hasMore) _page++;
          _isLoading = false;
          _isLoadingMore = false;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
          if (_visits.isEmpty) {
            _hasMore = false;
            _errorMessage = res['error']?.toString() ??
                'Unable to load service history. Pull down to retry.';
          }
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        if (_visits.isEmpty) {
          _hasMore = false;
          _errorMessage = 'Unable to load service history. Pull down to retry.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final active = widget.serviceState;
    final hasActiveVisit = active != null && active.hasActiveBooking && !active.isCompleted;

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
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.history_rounded, size: 20, color: Color(0xFF0284C7)),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Service History',
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
                                'Technician visits, maintenance & TDS logs',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                              ),
                            ],
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
                      alignment: Alignment.center,
                      child: const Icon(Icons.close, size: 18, color: Color(0xFF475569)),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0xFFE2E8F0)),

            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _loadHistory(refresh: true),
                child: Builder(
                  builder: (context) {
                    final displayTotal =
                        _totalVisits > _visits.length ? _totalVisits : _visits.length;
                    final topWidgets = <Widget>[
                      if (hasActiveVisit) ...[
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: const Color(0xFFBAE6FD), width: 1.5),
                            boxShadow: const [
                              BoxShadow(
                                  color: Color(0x0C000000),
                                  blurRadius: 10,
                                  offset: Offset(0, 4)),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: active.isArrived
                                                ? const Color(0xFFDCFCE7)
                                                : (active.isInService
                                                    ? const Color(0xFFF3E8FF)
                                                    : const Color(0xFFE0F2FE)),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            active.isArrived
                                                ? 'AT DOORSTEP'
                                                : (active.isInService
                                                    ? 'IN SERVICE'
                                                    : (active.isEnRoute
                                                        ? 'EN ROUTE'
                                                        : ((active.isOrderConfirmed ||
                                                                active.hasTechnicianAssigned)
                                                            ? 'ASSIGNED'
                                                            : 'BOOKED'))),
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                              color: active.isArrived
                                                  ? const Color(0xFF16A34A)
                                                  : (active.isInService
                                                      ? const Color(0xFF9333EA)
                                                      : const Color(0xFF0284C7)),
                                            ),
                                          ),
                                        ),
                                        if (active.isFreeRevisit ||
                                            active.isFreeVisit)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 7, vertical: 2.5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFEF3C7),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                  color:
                                                      const Color(0xFFFDE68A)),
                                            ),
                                            child: Text(
                                              active.isFreeRevisit
                                                  ? 'REVISIT'
                                                  : 'FREE VISIT',
                                              style: const TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w900,
                                                color: Color(0xFFB45309),
                                              ),
                                            ),
                                          ),
                                        const Text(
                                          'Doorstep Service',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF64748B)),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    active.fee == 0
                                        ? 'FREE (₹0)'
                                        : '₹${active.fee}',
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF0F172A)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                active.serviceTitle,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A)),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Technician: ${active.technicianName}${active.technicianRating != null ? ' (${active.technicianRating}★ Certified)' : ' (Certified)'}',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF475569)),
                              ),
                              const SizedBox(height: 12),
                              if (active.shouldShowOtp &&
                                  active.arrivalOtp != null) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFEF3C7),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFFFCD34D)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.key_rounded,
                                          size: 14, color: Color(0xFF92400E)),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Doorstep OTP: ${active.arrivalOtp}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w900,
                                              color: Color(0xFF92400E),
                                              fontFamily: 'monospace'),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Flexible(
                                        child: Text(
                                          'Share at doorstep',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFFB45309)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ] else if (active.isInService) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF86EFAC)),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.check_circle_rounded,
                                          size: 14, color: Color(0xFF16A34A)),
                                      SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'OTP Verified • Service In Progress',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF15803D)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0284C7),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12)),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 11),
                                    elevation: 0,
                                  ),
                                  icon: const Icon(Icons.location_on_rounded,
                                      size: 16),
                                  label: const Text(
                                      'Track Technician & Spares Hub',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13)),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    widget.onTrackServiceTap?.call();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'Past Service Records',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$displayTotal Completed',
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_isLoading && _visits.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else if (_visits.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 32, horizontal: 20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                _errorMessage != null
                                    ? Icons.cloud_off_rounded
                                    : Icons.history_rounded,
                                size: 40,
                                color: const Color(0xFF94A3B8),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _errorMessage != null
                                    ? 'Could Not Load History'
                                    : 'No Past Service History',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A)),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _errorMessage ??
                                    'Completed technician visits and TDS calibration reports will be recorded here.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF64748B),
                                    height: 1.3),
                              ),
                              const SizedBox(height: 14),
                              BouncingWidget(
                                onTap: _errorMessage != null
                                    ? () => _loadHistory(refresh: true)
                                    : () {
                                        Navigator.pop(context);
                                        widget.onBookServiceTap();
                                      },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0284C7),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _errorMessage != null
                                        ? 'Retry'
                                        : (HappyHourHelper.currentInspectionFee ==
                                                0
                                            ? 'Book RO Service (FREE)'
                                            : 'Book RO Service (₹${HappyHourHelper.currentInspectionFee})'),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ];

                    final visitCount =
                        (_isLoading && _visits.isEmpty) ? 0 : _visits.length;
                    final itemCount =
                        topWidgets.length + visitCount + (_isLoadingMore ? 1 : 0);

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics()),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        if (index < topWidgets.length) {
                          return topWidgets[index];
                        }
                        final visitIdx = index - topWidgets.length;
                        if (visitIdx >= _visits.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          );
                        }
                        final v = _visits[visitIdx];
                        final visitKey =
                            (v['id'] ?? v['visit_number'] ?? visitIdx)
                                .toString();
                        return ServiceHistoryVisitCard(
                          key: ValueKey('sh_visit_$visitKey'),
                          visit: v,
                          onVisitRated: (updated) {
                            if (!mounted) return;
                            setState(() => _visits[visitIdx] = updated);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared service history visit card displaying a compact collapsed summary by
/// default and lazily revealing TDS readings, technician rating, and collapsible
/// installed spare parts/kits with serial numbers on demand.
class ServiceHistoryVisitCard extends StatefulWidget {
  final Map<String, dynamic> visit;
  final void Function(Map<String, dynamic> updatedVisit)? onVisitRated;
  final bool initiallyExpanded;
  final bool initiallyPartsExpanded;

  const ServiceHistoryVisitCard({
    super.key,
    required this.visit,
    this.onVisitRated,
    this.initiallyExpanded = false,
    this.initiallyPartsExpanded = false,
  });

  static String extractSerial(Map<String, dynamic> item) {
    final raw = (item['serial_number'] ??
            item['kit_qr'] ??
            item['component_qr'] ??
            item['serial_qr'] ??
            item['serial'] ??
            item['code'] ??
            item['qr'] ??
            '')
        .toString()
        .trim();
    return raw.toUpperCase();
  }

  static List<Map<String, dynamic>> extractInstalledParts(
      Map<String, dynamic> visit) {
    final direct = visit['installed_parts'];
    if (direct is List) {
      return direct
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    final purchases = visit['purchases'];
    if (purchases is List) {
      final out = <Map<String, dynamic>>[];
      for (final p in purchases.whereType<Map>()) {
        final items = p['items'];
        if (items is List) {
          for (final it in items.whereType<Map>()) {
            out.add(Map<String, dynamic>.from(it));
          }
        }
      }
      return out;
    }
    return const [];
  }

  /// Computes the 15-day Free Technician Revisit window (distinct from product/part warranty).
  static ({int daysSince, int daysRemaining, int daysOverdue, bool withinWindow})?
      computeFreeRevisitInfo(Map<String, dynamic> visit, {DateTime? now}) {
    final win = visit['free_revisit_window'];
    if (win is Map &&
        win['days_since_visit'] != null &&
        win['within_free_window'] != null) {
      final ds = int.tryParse(win['days_since_visit'].toString()) ?? 0;
      final dr = int.tryParse(win['days_remaining']?.toString() ?? '') ??
          (ds <= 15 ? 15 - ds : 0);
      final dov = int.tryParse(win['days_overdue']?.toString() ?? '') ??
          (ds > 15 ? ds - 15 : 0);
      final within = win['within_free_window'] == true;
      return (
        daysSince: ds < 0 ? 0 : ds,
        daysRemaining: dr < 0 ? 0 : dr,
        daysOverdue: dov < 0 ? 0 : dov,
        withinWindow: within,
      );
    }

    final rawTs =
        (visit['completed_at'] ?? visit['updated_at'] ?? visit['created_at'])
            ?.toString();
    if (rawTs == null || rawTs.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(rawTs.trim());
    if (parsed == null) return null;

    const istOffset = Duration(hours: 5, minutes: 30);
    final refIst = parsed.toUtc().add(istOffset);
    final nowIst = (now ?? DateTime.now()).toUtc().add(istOffset);
    final refDate = DateTime.utc(refIst.year, refIst.month, refIst.day);
    final nowDate = DateTime.utc(nowIst.year, nowIst.month, nowIst.day);
    final diff = nowDate.difference(refDate).inDays;
    final daysSince = diff < 0 ? 0 : diff;
    final within = daysSince <= 15;
    return (
      daysSince: daysSince,
      daysRemaining: within ? (15 - daysSince) : 0,
      daysOverdue: within ? 0 : (daysSince - 15),
      withinWindow: within,
    );
  }

  @override
  State<ServiceHistoryVisitCard> createState() =>
      _ServiceHistoryVisitCardState();
}

class _ServiceHistoryVisitCardState extends State<ServiceHistoryVisitCard> {
  late bool _isExpanded;
  late bool _isPartsExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _isPartsExpanded = widget.initiallyPartsExpanded;
  }

  void _copySerial(BuildContext context, String serial) {
    Clipboard.setData(ClipboardData(text: serial));
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied serial number: $serial'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.visit;
    final visitKey =
        (v['id'] ?? v['visit_id'] ?? v['visit_number'] ?? '').toString();
    final visitId =
        (v['visit_number'] ?? v['visit_id'] ?? v['id'] ?? 'SRV').toString();
    final dateStr =
        (v['completed_at'] ?? v['scheduled_date'] ?? v['created_at'] ?? '')
            .toString()
            .split('T')
            .first;
    final techName = DisplaySanitizer.technicianName(
      v['technician_name']?.toString(),
      fallback: 'Certified Technician',
    );
    final techBadge =
        (v['technician_badge'] ?? v['assigned_technician_id'] ?? '').toString();
    final tdsIn = v['tds_input'] != null ? '${v['tds_input']} ppm' : null;
    final tdsOut = v['tds_output'] != null ? '${v['tds_output']} ppm' : null;
    final fee = v['labor_fee'] ?? v['service_charge'] ?? 49;
    final techRating = v['technician_rating'] != null
        ? double.tryParse('${v['technician_rating']}')
        : null;
    final techRatingCount =
        int.tryParse('${v['technician_rating_count'] ?? 0}') ?? 0;
    final techJobs = v['technician_completed_jobs'] != null
        ? int.tryParse('${v['technician_completed_jobs']}')
        : null;
    final custRating = v['customer_rating'] != null
        ? int.tryParse('${v['customer_rating']}')
        : null;
    final custReview = v['customer_review']?.toString();
    final installedParts = ServiceHistoryVisitCard.extractInstalledParts(v);
    final sparesSummary = v['spares_summary'];
    final sparesPaid = sparesSummary is Map
        ? (num.tryParse('${sparesSummary['spares_paid_total'] ?? 0}') ?? 0)
        : 0;
    final visitPurpose = (v['visit_purpose'] ?? '').toString().trim().toUpperCase();
    final isFreeRevisitCard = visitPurpose == 'FREE_REVISIT';
    final isFreeVisitCard = v['is_free_visit'] == true || visitPurpose == 'FREE_VISIT' || isFreeRevisitCard;
    final revisitInfo = ServiceHistoryVisitCard.computeFreeRevisitInfo(v);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isExpanded
              ? const Color(0xFFBAE6FD)
              : const Color(0xFFE2E8F0),
        ),
        boxShadow: const [
          BoxShadow(
              color: Color(0x06000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Always-visible Compact Header (tap to expand/collapse visit details)
              InkWell(
                key: ValueKey('visit_header_$visitId'),
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2.5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'COMPLETED',
                                    style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF16A34A)),
                                  ),
                                ),
                                if (isFreeRevisitCard || isFreeVisitCard)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2.5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFEF3C7),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: const Color(0xFFFDE68A)),
                                    ),
                                    child: Text(
                                      isFreeRevisitCard
                                          ? 'REVISIT'
                                          : 'FREE VISIT',
                                      style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFFB45309)),
                                    ),
                                  ),
                                const Text(
                                  'Doorstep Service',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A)),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '₹$fee',
                                style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF0F172A)),
                              ),
                              if (sparesPaid > 0)
                                Text(
                                  '+ ₹${sparesPaid % 1 == 0 ? sparesPaid.toInt() : sparesPaid.toStringAsFixed(0)} spares',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F766E)),
                                ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF1F5F9),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _isExpanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: const Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Technician: $techName • ${dateStr.isNotEmpty ? dateStr : 'Completed'}',
                        maxLines: _isExpanded ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF334155)),
                      ),
                      if (!_isExpanded) ...[
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: installedParts.isNotEmpty
                                    ? const Color(0xFFF0FDFA)
                                    : const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: installedParts.isNotEmpty
                                      ? const Color(0xFF99F6E4)
                                      : const Color(0xFFE2E8F0),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    installedParts.isNotEmpty
                                        ? Icons.verified_rounded
                                        : Icons.build_circle_outlined,
                                    size: 12,
                                    color: installedParts.isNotEmpty
                                        ? const Color(0xFF0F766E)
                                        : const Color(0xFF64748B),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    installedParts.isNotEmpty
                                        ? '${installedParts.length} ${installedParts.length == 1 ? 'Part' : 'Parts'} Installed'
                                        : 'Inspection Only',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: installedParts.isNotEmpty
                                          ? const Color(0xFF0F766E)
                                          : const Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (tdsIn != null || tdsOut != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF0FDF4),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: const Color(0xFFBBF7D0)),
                                ),
                                child: Text(
                                  'TDS ${tdsIn ?? "N/A"} → ${tdsOut ?? "N/A"}',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF15803D),
                                  ),
                                ),
                              ),
                            if (custRating != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEFCE8),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: const Color(0xFFFDE047)),
                                ),
                                child: Text(
                                  'Rated $custRating★',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFA16207),
                                  ),
                                ),
                              ),
                            if (revisitInfo != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: revisitInfo.withinWindow
                                      ? const Color(0xFFEFF6FF)
                                      : const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: revisitInfo.withinWindow
                                        ? const Color(0xFFBFDBFE)
                                        : const Color(0xFFFED7AA),
                                  ),
                                ),
                                child: Text(
                                  revisitInfo.withinWindow
                                      ? (revisitInfo.daysRemaining == 0
                                          ? 'Free Revisit: Last Day (15/15)'
                                          : 'Free Revisit: ${revisitInfo.daysRemaining}d left (Day ${revisitInfo.daysSince}/15)')
                                      : '⚠ 15d Revisit Expired (${revisitInfo.daysSince}d ago)',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: revisitInfo.withinWindow
                                        ? const Color(0xFF1D4ED8)
                                        : const Color(0xFFC2410C),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Expanded Visit Body (built lazily on tap)
              if (_isExpanded) ...[
                const Divider(height: 16, color: Color(0xFFF1F5F9)),
                TechnicianRatingBadgeRow(
                  rating: techRating,
                  ratingCount: techRatingCount,
                  completedJobs: techJobs,
                  showViewReviewsHint: visitKey.isNotEmpty || techBadge.isNotEmpty,
                  onTap: (visitKey.isEmpty && techBadge.isEmpty)
                      ? null
                      : () => showTechnicianReviewsSheet(
                            context,
                            visitId: visitKey,
                            technicianId: techBadge,
                            technicianName: techName,
                            initialAvg: techRating,
                            initialCount: techRatingCount,
                            initialJobs: techJobs,
                          ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Date: ${dateStr.isNotEmpty ? dateStr : 'Completed'} • Doorstep Visit',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
                if (revisitInfo != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: revisitInfo.withinWindow
                          ? const Color(0xFFEFF6FF)
                          : const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: revisitInfo.withinWindow
                            ? const Color(0xFFBFDBFE)
                            : const Color(0xFFFDBA74),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          revisitInfo.withinWindow
                              ? 'Technician Free Revisit: ${revisitInfo.daysRemaining} days left (Day ${revisitInfo.daysSince}/15)'
                              : '⚠ 15-Day Free Revisit Expired (${revisitInfo.daysSince} days ago • +${revisitInfo.daysOverdue}d past 15d)',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: revisitInfo.withinWindow
                                ? const Color(0xFF1E40AF)
                                : const Color(0xFFC2410C),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          revisitInfo.withinWindow
                              ? 'This 15-day window is for Free Technician Revisit only (not 15-day part warranty; product warranties remain separate).'
                              : 'This 15-day window covers Free Technician Revisit only (not part warranty). After 15 days, ₹0 revisit depends on Manager approval.',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: revisitInfo.withinWindow
                                ? const Color(0xFF1E3A8A)
                                : const Color(0xFF9A3412),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // TDS Calibration Readings
                if (tdsIn != null || tdsOut != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.water_drop_outlined,
                            size: 14, color: Color(0xFF16A34A)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'TDS Raw: ${tdsIn ?? "N/A"}  →  TDS Pure: ${tdsOut ?? "N/A"}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF15803D)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Collapsible Parts Installed in This Service + Serial Numbers
                const SizedBox(height: 10),
                if (installedParts.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFCCFBF1)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          key: ValueKey('parts_toggle_$visitId'),
                          onTap: () => setState(
                              () => _isPartsExpanded = !_isPartsExpanded),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                const Icon(Icons.verified_rounded,
                                    size: 15, color: Color(0xFF0F766E)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Parts Installed (${installedParts.length})',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F766E),
                                    ),
                                  ),
                                ),
                                Text(
                                  _isPartsExpanded ? 'Hide' : 'Show serials',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F766E),
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Icon(
                                  _isPartsExpanded
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 17,
                                  color: const Color(0xFF0F766E),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isPartsExpanded) ...[
                          const SizedBox(height: 7),
                          ...installedParts.map((part) {
                            final partName = (part['name'] ??
                                    part['product_name'] ??
                                    'Genuine RO Spare')
                                .toString();
                            final serial =
                                ServiceHistoryVisitCard.extractSerial(part);
                            final spec = CbmSpecHelper.resolveItemSpec(part);
                            final children = part['components'] is List
                                ? (part['components'] as List)
                                    .whereType<Map>()
                                    .map((c) => Map<String, dynamic>.from(c))
                                    .toList()
                                : const <Map<String, dynamic>>[];

                            return Container(
                              margin: const EdgeInsets.only(bottom: 5),
                              padding: const EdgeInsets.all(7.5),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(9),
                                border:
                                    Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        spec.icon,
                                        size: 14,
                                        color: spec.hasSpec
                                            ? spec.pillForeground
                                            : const Color(0xFF0284C7),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              partName,
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0F172A),
                                              ),
                                            ),
                                            if (spec.shortBadge != null)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 1.5),
                                                decoration: BoxDecoration(
                                                  color: spec.pillBackground,
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Text(
                                                  spec.shortBadge!,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: spec.pillForeground,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (serial.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    InkWell(
                                      onTap: () =>
                                          _copySerial(context, serial),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6.5, vertical: 2.5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF1F5F9),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                              color: const Color(0xFFCBD5E1)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.qr_code_2_rounded,
                                                size: 11.5,
                                                color: Color(0xFF334155)),
                                            const SizedBox(width: 4),
                                            Flexible(
                                              child: Text(
                                                'Serial: $serial',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w800,
                                                  fontFamily: 'monospace',
                                                  color: Color(0xFF0F172A),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            const Icon(Icons.copy_rounded,
                                                size: 10.5,
                                                color: Color(0xFF64748B)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (children.isNotEmpty) ...[
                                    const SizedBox(height: 5),
                                    ...children.map((child) {
                                      final cName = (child['name'] ??
                                              child['product_name'] ??
                                              'Kit Part')
                                          .toString();
                                      final cSerial =
                                          ServiceHistoryVisitCard.extractSerial(
                                              child);
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                            left: 8, top: 2.5),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text('• ',
                                                style: TextStyle(
                                                    color: Color(0xFF64748B),
                                                    fontSize: 11)),
                                            Expanded(
                                              child: Wrap(
                                                spacing: 6,
                                                runSpacing: 2,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: [
                                                  Text(
                                                    cName,
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color:
                                                            Color(0xFF334155),
                                                        fontWeight:
                                                            FontWeight.w600),
                                                  ),
                                                  if (cSerial.isNotEmpty)
                                                    GestureDetector(
                                                      onTap: () => _copySerial(
                                                          context, cSerial),
                                                      child: Text(
                                                        'SN: $cSerial',
                                                        style: const TextStyle(
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          fontFamily:
                                                              'monospace',
                                                          color:
                                                              Color(0xFF0284C7),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ],
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.build_circle_outlined,
                            size: 14, color: Color(0xFF64748B)),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Inspection & servicing only • No parts replaced',
                            style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (visitKey.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  TechnicianRateCard(
                    key: ValueKey('hist_rate_$visitKey'),
                    compact: true,
                    technicianName: techName,
                    technicianBadge: techBadge,
                    initialCustomerRating: custRating,
                    initialCustomerReview: custReview,
                    onViewReviews: (visitKey.isEmpty && techBadge.isEmpty)
                        ? null
                        : () => showTechnicianReviewsSheet(
                              context,
                              visitId: visitKey,
                              technicianId: techBadge,
                              technicianName: techName,
                              initialAvg: techRating,
                              initialCount: techRatingCount,
                              initialJobs: techJobs,
                            ),
                    onSubmit: ({required rating, required tags, reviewText}) async {
                      final res = await ApiService().rateServiceVisit(
                        visitId: visitKey,
                        rating: rating,
                        tags: tags,
                        reviewText: reviewText,
                      );
                      if (res['success'] == true &&
                          widget.onVisitRated != null) {
                        final updated = Map<String, dynamic>.from(v);
                        updated['customer_rating'] =
                            res['customer_rating'] ?? rating;
                        if (reviewText != null &&
                            reviewText.trim().isNotEmpty) {
                          updated['customer_review'] = reviewText.trim();
                        }
                        if (res['technician_stats'] is Map) {
                          final st = Map<String, dynamic>.from(
                              res['technician_stats'] as Map);
                          updated['technician_rating'] = st['rating_avg'];
                          updated['technician_rating_count'] =
                              st['rating_count'];
                          updated['technician_completed_jobs'] =
                              st['completed_jobs_count'];
                        }
                        widget.onVisitRated!(updated);
                      }
                      return res;
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
