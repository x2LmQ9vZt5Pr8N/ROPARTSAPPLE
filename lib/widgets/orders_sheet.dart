import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../state/service_tracking_state.dart';
import '../utils/cbm_spec_helper.dart';
import '../utils/display_sanitizer.dart';
import '../utils/phone_normalizer.dart';
import '../utils/unit_helper.dart';
import 'bouncing_widget.dart';
import 'cart_bottom_sheet.dart';
import 'product_detail_sheet.dart';
import 'service_history_sheet.dart';
import 'zone_support_chat_sheet.dart';

class OrdersSheet extends StatefulWidget {
  final CartState cartState;
  final ServiceTrackingState? serviceState;
  final VoidCallback? onTrackServiceTap;
  final Future<void> Function({String? draftId})? onResumeSavedDraft;

  const OrdersSheet({
    super.key,
    required this.cartState,
    this.serviceState,
    this.onTrackServiceTap,
    this.onResumeSavedDraft,
  });

  @override
  State<OrdersSheet> createState() => _OrdersSheetState();
}

class _OrdersSheetState extends State<OrdersSheet> with WidgetsBindingObserver {
  String _selectedTab = 'products'; // 'products' or 'services'
  String _selectedFilter = 'All';

  final List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _visitPurchasedSpares = [];
  final List<Map<String, dynamic>> _serviceHistory = [];
  bool _isLoading = false;
  bool _isLoadingServiceHistory = false;
  bool _isLoadingMoreServices = false;
  bool _serviceHistoryLoadedOnce = false;
  bool _hasMore = true;
  bool _hasMoreServices = true;
  String? _errorMessage;
  String? _serviceHistoryError;
  int _page = 1;
  int _servicePage = 1;
  int _serviceHistoryTotal = 0;
  int _fetchSeq = 0;
  int _serviceFetchSeq = 0;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _serviceScrollController = ScrollController();
  final Set<String> _expandedKits = {};
  final Set<String> _silentlyCheckedOrderIds = {};
  String? _lastOrdersVisitId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchOrders(refresh: true);
    if (!widget.cartState.hasActiveRecoveryDraft) {
      unawaited(widget.cartState.loadActiveOnlineDraft());
    }
    _scrollController.addListener(_onScroll);
    _serviceScrollController.addListener(_onServiceScroll);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _serviceScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_isLoading) {
      _fetchOrders(refresh: true);
      if (_selectedTab == 'services' && _serviceHistoryLoadedOnce) {
        _fetchServiceHistory(refresh: true);
      }
    }
  }

  void _onServiceScroll() {
    if (_selectedTab == 'services' &&
        _serviceScrollController.hasClients &&
        _serviceScrollController.position.pixels >=
            _serviceScrollController.position.maxScrollExtent - 200 &&
        !_isLoadingServiceHistory &&
        !_isLoadingMoreServices &&
        _hasMoreServices) {
      _fetchServiceHistory();
    }
  }

  Future<void> _fetchServiceHistory({bool refresh = false}) async {
    if (!refresh && (_isLoadingMoreServices || _isLoadingServiceHistory || !_hasMoreServices)) {
      return;
    }

    final rawId = widget.cartState.userPhone.isNotEmpty
        ? widget.cartState.userPhone
        : (widget.cartState.customerId ?? widget.serviceState?.receiverPhone ?? '');
    final customerParam = PhoneNormalizer.toCustomerId(rawId);
    if (customerParam.isEmpty) {
      if (!mounted) return;
      setState(() {
        _serviceHistory.clear();
        _serviceHistoryTotal = 0;
        _hasMoreServices = false;
        _serviceHistoryLoadedOnce = true;
        _isLoadingServiceHistory = false;
        _isLoadingMoreServices = false;
      });
      return;
    }

    final currentSeq = ++_serviceFetchSeq;
    if (mounted) {
      setState(() {
        if (refresh) {
          _servicePage = 1;
          _hasMoreServices = true;
          _isLoadingServiceHistory = true;
          _isLoadingMoreServices = false;
          _serviceHistoryError = null;
        } else {
          _isLoadingMoreServices = true;
        }
      });
    }

    try {
      final res = await ApiService().getServiceHistoryPage(
        customerId: customerParam,
        page: _servicePage,
        limit: 10,
      );
      if (!mounted || currentSeq != _serviceFetchSeq) return;
      if (res['success'] == true) {
        final list = (res['visits'] is List)
            ? List<Map<String, dynamic>>.from(res['visits'] as List)
            : <Map<String, dynamic>>[];
        setState(() {
          if (refresh) {
            _serviceHistory.clear();
          }
          _serviceHistory.addAll(list);
          final reportedTotal =
              int.tryParse('${res['total'] ?? ''}') ?? _serviceHistory.length;
          _serviceHistoryTotal = reportedTotal > _serviceHistory.length
              ? reportedTotal
              : _serviceHistory.length;
          _hasMoreServices = res['has_more'] == true;
          if (_hasMoreServices) _servicePage++;
          _serviceHistoryLoadedOnce = true;
          _isLoadingServiceHistory = false;
          _isLoadingMoreServices = false;
          _serviceHistoryError = null;
        });
      } else {
        setState(() {
          _serviceHistoryLoadedOnce = true;
          _isLoadingServiceHistory = false;
          _isLoadingMoreServices = false;
          if (_serviceHistory.isEmpty) {
            _hasMoreServices = false;
            _serviceHistoryError = res['error']?.toString() ??
                'Could not load service history. Pull down to retry.';
          }
        });
      }
    } catch (_) {
      if (!mounted || currentSeq != _serviceFetchSeq) return;
      setState(() {
        _serviceHistoryLoadedOnce = true;
        _isLoadingServiceHistory = false;
        _isLoadingMoreServices = false;
        if (_serviceHistory.isEmpty) {
          _hasMoreServices = false;
          _serviceHistoryError =
              'Could not load service history. Pull down to retry.';
        }
      });
    }
  }

  bool _isConfirmedOrder(Map<String, dynamic> order) {
    final status = (order['status'] ?? '').toString().trim().toUpperCase();
    final paymentStatus = (order['payment_status'] ?? '').toString().trim().toUpperCase();
    final paymentMethod = (order['payment_method'] ?? '').toString().trim().toUpperCase();
    final isCod = paymentMethod == 'COD' || paymentStatus == 'PENDING_COD';

    const nonConfirmed = {
      'PROCESSING',
      'IN_PROGRESS',
      'PENDING',
      'PENDING_PAYMENT',
      'INITIATED',
      'FAILED',
      'EXPIRED',
      'CANCELLED',
      'DECLINED',
      'REFUNDED',
    };

    if (nonConfirmed.contains(paymentStatus)) {
      return false;
    }
    if (const {'FAILED', 'EXPIRED', 'CANCELLED', 'DECLINED', 'REFUNDED'}.contains(status)) {
      return false;
    }
    if (!isCod &&
        const {'PROCESSING', 'IN_PROGRESS', 'PENDING', 'PENDING_PAYMENT', 'INITIATED'}
            .contains(status)) {
      return false;
    }

    final isPaid = paymentStatus == 'PAID' ||
        paymentStatus == 'COMPLETED' ||
        paymentStatus == 'SETTLED';
    final isDelivered = status == 'DELIVERED' || status == 'REPLACED' || status == 'RTO_RETURNED';
    final isCodConfirmed = isCod &&
        (status == 'PENDING_CONFIRMATION' ||
            status == 'CONFIRMED' ||
            status == 'DISPATCHED' ||
            status == 'OUT_FOR_DELIVERY' ||
            status == 'DELIVERED' ||
            status == 'COMPLETED' ||
            status == 'RTO_RETURNED');

    return isPaid ||
        isDelivered ||
        isCodConfirmed ||
        status == 'PENDING_CONFIRMATION' ||
        status == 'CONFIRMED' ||
        status == 'DISPATCHED' ||
        status == 'OUT_FOR_DELIVERY';
  }

  bool _isUnconfirmedProcessingOrder(Map<String, dynamic> order) {
    if (_isConfirmedOrder(order)) return false;
    final st = (order['status'] ?? '').toString().trim().toUpperCase();
    final pst = (order['payment_status'] ?? '').toString().trim().toUpperCase();
    final method = (order['payment_method'] ?? '').toString().trim().toUpperCase();
    if (method == 'COD') return false;
    return st == 'PROCESSING' ||
        st == 'IN_PROGRESS' ||
        st == 'PENDING' ||
        st == 'PENDING_PAYMENT' ||
        st == 'INITIATED' ||
        pst == 'PROCESSING' ||
        pst == 'IN_PROGRESS' ||
        pst == 'PENDING' ||
        pst == 'PENDING_PAYMENT' ||
        pst == 'INITIATED';
  }

  Future<void> _silentlyReconcileUnconfirmedOrders(List<String> orderIds) async {
    bool anyCleared = false;
    for (final orderId in orderIds) {
      if (!mounted) return;
      try {
        final statusRes = await ApiService().checkCheckoutStatus(orderId, live: true);
        final st = (statusRes['status'] ?? '').toString().trim().toUpperCase();
        final isCleared = statusRes['paid'] == true ||
            statusRes['is_cleared'] == true ||
            st == 'CLEARED' ||
            st == 'PAID' ||
            st == 'COMPLETED' ||
            st == 'SETTLED';
        if (isCleared) {
          anyCleared = true;
        }
      } catch (_) {}
    }
    if (anyCleared && mounted) {
      await _fetchOrders(refresh: true);
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _hasMore) {
      _fetchOrders();
    }
  }

  Future<void> _fetchOrders({bool refresh = false}) async {
    if (_isLoading && !refresh) return;
    final currentSeq = ++_fetchSeq;
    if (refresh) {
      _page = 1;
      _hasMore = true;
      _silentlyCheckedOrderIds.clear();
      _errorMessage = null;
    }
    setState(() => _isLoading = true);

    final rawPhone = widget.cartState.userPhone.isNotEmpty
        ? widget.cartState.userPhone
        : (widget.cartState.customerId ?? '');

    final customerParam = PhoneNormalizer.toCustomerId(rawPhone);
    if (customerParam.isEmpty) {
      setState(() {
        _isLoading = false;
        _orders.clear();
        _visitPurchasedSpares = [];
        _hasMore = false;
      });
      return;
    }

    try {
      final res = await ApiService().getOrderHistory(customerId: customerParam, page: _page, limit: 10);

      // Also fetch verified visit spares for active service card
      final visitId = widget.serviceState?.bookingId.trim() ?? '';
      if (visitId.isEmpty) {
        _lastOrdersVisitId = null;
        _visitPurchasedSpares = [];
      } else {
        if (_lastOrdersVisitId != visitId) {
          _visitPurchasedSpares = [];
          _lastOrdersVisitId = visitId;
        }
        final vRes = await ApiService().getVisitPurchases(visitId, customerId: customerParam);
        if (vRes != null && (vRes['success'] == true || vRes['purchases'] != null || vRes['movements'] != null)) {
          final purchases = (vRes['purchases'] is List)
              ? (vRes['purchases'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
              : <Map<String, dynamic>>[];
          final movements = (vRes['movements'] is List)
              ? (vRes['movements'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
              : <Map<String, dynamic>>[];
          final allVisitItems = <Map<String, dynamic>>[];
          for (final p in (purchases.isNotEmpty ? purchases : movements)) {
            final items = p['items'];
            if (items is List) {
              for (final it in items) {
                if (it is Map) allVisitItems.add(Map<String, dynamic>.from(it));
              }
            }
          }
          _visitPurchasedSpares = allVisitItems;
        }
      }

      if (!mounted || currentSeq != _fetchSeq) return;

      if (res['success'] == false) {
        setState(() {
          _isLoading = false;
          _errorMessage = res['error']?.toString() ?? 'Could not load orders. Pull down to retry.';
        });
        return;
      }

      final List<dynamic> list = res['orders'] ?? [];
      final rawMaps = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final confirmedOnly = rawMaps.where(_isConfirmedOrder).toList();

      final toSilentlyCheck = <String>[];
      for (final row in rawMaps) {
        if (_isUnconfirmedProcessingOrder(row)) {
          final orderId = (row['order_number'] ?? row['id'] ?? '').toString().trim();
          if (orderId.isNotEmpty && !_silentlyCheckedOrderIds.contains(orderId)) {
            _silentlyCheckedOrderIds.add(orderId);
            toSilentlyCheck.add(orderId);
          }
        }
      }
      if (toSilentlyCheck.isNotEmpty) {
        unawaited(_silentlyReconcileUnconfirmedOrders(toSilentlyCheck));
      }

      setState(() {
        _isLoading = false;
        _errorMessage = null;
        if (refresh) {
          _orders.clear();
        }
        _orders.addAll(confirmedOnly);
        if (list.length < 10) {
          _hasMore = false;
        } else {
          _page++;
        }
      });

      if (_orders.isEmpty && _hasMore && list.length >= 10 && _page <= 5) {
        unawaited(_fetchOrders());
      }
    } catch (_) {
      if (mounted && currentSeq == _fetchSeq) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Network error loading orders. Pull down to retry.';
        });
      }
    }
  }

  Future<void> _contactSupport(String orderId) async {
    await showZoneSupportChatSheet(
      context,
      orderId: orderId,
      issueType: 'ORDER_SUPPORT',
      cartState: widget.cartState,
      quickPrompts: const <String>[
        'Order tracking / courier delivery status',
        'Invoice / GST bill request',
        'Damaged or missing item query',
        'Installation / service help for purchased part',
      ],
    );
  }

  void _openProductDetail(Map<String, dynamic> comp) {
    final prod = Product(
      id: (comp['sku'] ?? comp['item_name'] ?? 'P1').toString(),
      sku: (comp['sku'] ?? 'GENUINE-PART').toString(),
      name: (comp['name'] ?? comp['item_name'] ?? 'Drop Genuine Part').toString(),
      slug: (comp['sku'] ?? 'part').toString().toLowerCase(),
      brand: 'Drop Technologies',
      sellingPrice: (comp['price'] is num)
          ? (comp['price'] as num).toInt()
          : (double.tryParse(comp['price']?.toString() ?? '')?.toInt() ?? 500),
      mrp: (comp['mrp'] is num)
          ? (comp['mrp'] as num).toInt()
          : (double.tryParse(comp['mrp']?.toString() ?? '')?.toInt() ?? 600),
      image: comp['image_url'] ?? 'assets/images/membrane.png',
      shortDescription: comp['type'] != null
          ? 'Genuine factory replacement ${comp['type']}'
          : 'Drop verified factory spare part',
      detailedDescription:
          'Factory sealed, genuine replacement cartridge certified for zero contamination, tested under burst pressure and micron filtration integrity.',
      keyFeatures: const [
        'Universal 1/4" quick-connect push-fit',
        '100% Food-Grade Virgin Polypropylene',
        'Burst pressure tested up to 125 PSI',
      ],
      lifeInLiters: '6,000 Litres',
      lifeDuration: '12 Months',
      comparisons: const [],
      youtubeVideoUrl: '',
      youtubeVideoTitle: '',
      specifications: {
        'Part Serial': (comp['serial_number'] ?? 'VERIFIED').toString(),
        'Category': (comp['type'] ?? 'Filter').toString(),
        'Warranty': '12 Months',
      },
      compatibility: const ['Kent', 'Aquaguard', 'Livpure', 'Pureit', 'All standard domestic ROs'],
      categoryId: 'spares',
      segment: 'domestic',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ProductDetailSheet(
        product: prod,
        cartState: widget.cartState,
      ),
    );
  }

  Future<void> _launchExternalTracking(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.tryParse(url.trim());
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openOnlineOrderTracker(String orderNumber) async {
    final phone = widget.cartState.userPhone;
    final res = await ApiService().fetchOnlineOrderTracking(orderNumber, phone: phone);
    if (!mounted) return;
    if (res['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text((res['error'] ?? 'Could not load tracking timeline').toString())),
      );
      return;
    }

    final timeline = (res['timeline'] is List) ? List<Map<String, dynamic>>.from(res['timeline'] as List) : <Map<String, dynamic>>[];
    final courierName = res['courier_name']?.toString();
    final trackingNumber = res['tracking_number']?.toString();
    final trackingUrl = res['tracking_url']?.toString();
    final serials = (res['assigned_serials'] is List) ? (res['assigned_serials'] as List) : const [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.local_shipping_rounded, color: Color(0xFF0284C7)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Track #$orderNumber', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    ),
                    IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded)),
                  ],
                ),
                if (trackingNumber != null && trackingNumber.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFF0F9FF), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFBAE6FD))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Courier: ${courierName ?? 'Express Partner'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0369A1))),
                        const SizedBox(height: 2),
                        Text('AWB Tracking: $trackingNumber', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 12.5)),
                        if (trackingUrl != null && trackingUrl.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: () => _launchExternalTracking(trackingUrl),
                            icon: const Icon(Icons.open_in_new_rounded, size: 15),
                            label: const Text('Track on Courier Site', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                const Text('Shipment Timeline', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                ...timeline.map((step) {
                  final done = step['done'] == true;
                  final ts = step['timestamp']?.toString();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                          color: done ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text((step['label'] ?? '').toString(), style: TextStyle(fontSize: 13, fontWeight: done ? FontWeight.w800 : FontWeight.w600, color: done ? const Color(0xFF0F172A) : const Color(0xFF64748B))),
                              if (ts != null && ts.isNotEmpty)
                                Text(ts.split('T').first, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (serials.isNotEmpty) ...[
                  const Divider(height: 20),
                  const Text('Delivered Serials & Active Warranty', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF065F46))),
                  const SizedBox(height: 6),
                  ...serials.whereType<Map>().map((s) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• ${s['qr_code'] ?? ''} (${s['name'] ?? s['sku'] ?? ''})', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      )),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final confirmedOrders = _orders.where(_isConfirmedOrder).toList();
    final filtered = confirmedOrders.where((o) {
      final status = (o['status'] ?? '').toString().trim().toUpperCase();
      if (_selectedFilter == 'Active') {
        return status == 'PENDING_CONFIRMATION' || status == 'DISPATCHED' || status == 'OUT_FOR_DELIVERY' || status == 'CONFIRMED';
      }
      if (_selectedFilter == 'Delivered') {
        return status == 'DELIVERED' || status == 'COMPLETED' || status == 'RTO_RETURNED';
      }
      return true;
    }).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.92,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            top: false,
            child: Column(
          children: [
            // 1. Drag Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // 2. Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3E8FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.inventory_2_rounded, size: 20, color: Color(0xFF7C3AED)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'My Bookings & Orders',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                  letterSpacing: -0.3,
                                ),
                              ),
                              Text(
                                _selectedTab == 'products'
                                    ? '${confirmedOrders.length} confirmed orders placed'
                                    : 'Active service status & technician visits',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
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

            // 3. Category Switcher (Products vs Doorstep Services)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedTab = 'products'),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: _selectedTab == 'products' ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            boxShadow: _selectedTab == 'products'
                                ? [const BoxShadow(color: Color(0x10000000), blurRadius: 4, offset: Offset(0, 2))]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.inventory_2_outlined, size: 15, color: _selectedTab == 'products' ? const Color(0xFF0F172A) : const Color(0xFF64748B)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Spare Orders (${confirmedOrders.length})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _selectedTab == 'products' ? FontWeight.w800 : FontWeight.w600,
                                    color: _selectedTab == 'products' ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _selectedTab = 'services');
                          if (!_serviceHistoryLoadedOnce &&
                              !_isLoadingServiceHistory) {
                            _fetchServiceHistory(refresh: true);
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: _selectedTab == 'services' ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            boxShadow: _selectedTab == 'services'
                                ? [const BoxShadow(color: Color(0x10000000), blurRadius: 4, offset: Offset(0, 2))]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.engineering_outlined, size: 15, color: _selectedTab == 'services' ? const Color(0xFF0284C7) : const Color(0xFF64748B)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  () {
                                    final activeCount =
                                        widget.serviceState?.hasActiveBooking ==
                                                true
                                            ? 1
                                            : 0;
                                    final historyCount = _serviceHistoryTotal >
                                            _serviceHistory.length
                                        ? _serviceHistoryTotal
                                        : _serviceHistory.length;
                                    if (_serviceHistoryLoadedOnce) {
                                      return 'Doorstep Services (${activeCount + historyCount})';
                                    }
                                    return activeCount > 0
                                        ? 'Doorstep Services ($activeCount)'
                                        : 'Doorstep Services';
                                  }(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _selectedTab == 'services' ? FontWeight.w800 : FontWeight.w600,
                                    color: _selectedTab == 'services' ? const Color(0xFF0284C7) : const Color(0xFF64748B),
                                  ),
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

            const SizedBox(height: 8),

            // Tab 1: Spare Parts Orders
            if (_selectedTab == 'products') ...[
              // Filter Segment Pills
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: ['All', 'Active', 'Delivered'].map((filter) {
                      final isSelected = _selectedFilter == filter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: BouncingWidget(
                          onTap: () => setState(() => _selectedFilter = filter),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF0F172A) : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Text(
                              filter,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isSelected ? Colors.white : const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

              // 7-Day Resumable Online Checkout / Failed Payment Card
              ListenableBuilder(
                listenable: widget.cartState,
                builder: (context, _) {
                  if (!widget.cartState.hasActiveRecoveryDraft) {
                    return const SizedBox.shrink();
                  }
                  return _buildSavedRecoveryDraftCard();
                },
              ),

              // Lazy Loaded Orders List
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await Future.wait([
                      _fetchOrders(refresh: true),
                      widget.cartState.loadActiveOnlineDraft(),
                    ]);
                  },
                  child: filtered.isEmpty && !_isLoading && !widget.cartState.hasActiveRecoveryDraft
                      ? ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          children: [
                            const SizedBox(height: 80),
                            Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _errorMessage != null ? Icons.cloud_off_rounded : Icons.inventory_2_outlined,
                                    size: 48,
                                    color: const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _errorMessage != null ? 'Could Not Load Orders' : 'No Orders Found',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _errorMessage ?? 'Orders placed in the app or via technician appear here.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                  ),
                                  if (_errorMessage != null) ...[
                                    const SizedBox(height: 12),
                                    TextButton.icon(
                                      onPressed: () => _fetchOrders(refresh: true),
                                      icon: const Icon(Icons.refresh_rounded, size: 16),
                                      label: const Text('Retry'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                          itemCount: filtered.length + (_isLoading ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= filtered.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }

                            final order = filtered[index];
                            final rawOrderId = (order['order_number'] ?? order['id'] ?? '').toString().trim();
                            final orderId = rawOrderId.isNotEmpty ? rawOrderId : 'ORDER';
                            final displayOrderId = orderId.length > 18
                                ? '#${orderId.substring(0, 10)}...${orderId.substring(orderId.length - 4)}'
                                : '#$orderId';
                            final channel = (order['purchase_channel'] ?? '').toString().toUpperCase();
                            final isTechnician = channel.contains('TECH') || channel.contains('DOORSTEP');
                            final status = (order['status'] ?? 'CONFIRMED').toString().trim().toUpperCase();
                            final isReplacedOrder = status == 'REPLACED' || channel == 'WARRANTY_REPLACEMENT';
                            final items = (order['items'] is List) ? (order['items'] as List) : [];
                            final isKitExpanded = _expandedKits.contains(orderId);

                            return Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isReplacedOrder
                                      ? const Color(0xFFC4B5FD)
                                      : (isTechnician ? const Color(0xFFA7F3D0) : const Color(0xFFE2E8F0)),
                                  width: (isTechnician || isReplacedOrder) ? 1.5 : 1.0,
                                ),
                                boxShadow: const [
                                  BoxShadow(color: Color(0x06000000), blurRadius: 8, offset: Offset(0, 2)),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Order Header
                                  Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Wrap(
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            spacing: 6,
                                            runSpacing: 4,
                                            children: [
                                              Text(
                                                displayOrderId,
                                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF0F172A)),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              // CHANNEL BADGE
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: isReplacedOrder
                                                      ? const Color(0xFFEDE9FE)
                                                      : (isTechnician ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE)),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  isReplacedOrder
                                                      ? 'WARRANTY REPLACEMENT'
                                                      : (isTechnician ? 'PURCHASE BY TECHNICIAN' : 'PAN-INDIA ONLINE'),
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w900,
                                                    color: isReplacedOrder
                                                        ? const Color(0xFF6D28D9)
                                                        : (isTechnician ? const Color(0xFF15803D) : const Color(0xFF0284C7)),
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ),
                                              // CONFIRMED STATUS BADGE
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                                decoration: BoxDecoration(
                                                  color: (status == 'REPLACED' || status == 'PENDING_CONFIRMATION')
                                                      ? const Color(0xFFFEF3C7)
                                                      : (status == 'RTO_RETURNED' || status == 'CANCELLED'
                                                          ? const Color(0xFFFEE2E2)
                                                          : ((status == 'DISPATCHED' || status == 'OUT_FOR_DELIVERY')
                                                              ? const Color(0xFFE0F2FE)
                                                              : const Color(0xFFDCFCE7))),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  status == 'REPLACED'
                                                      ? 'REPLACED'
                                                      : (status == 'PENDING_CONFIRMATION'
                                                          ? 'AWAITING CONFIRM'
                                                          : (status == 'DISPATCHED'
                                                              ? 'SHIPPED'
                                                              : (status == 'RTO_RETURNED'
                                                                  ? 'RTO RETURNED'
                                                                  : (status == 'COMPLETED'
                                                                      ? 'COMPLETED'
                                                                      : (status == 'DELIVERED'
                                                                          ? 'DELIVERED'
                                                                          : (status == 'OUT_FOR_DELIVERY'
                                                                              ? 'OUT FOR DELIVERY'
                                                                              : 'CONFIRMED')))))),
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w900,
                                                    color: (status == 'REPLACED' || status == 'PENDING_CONFIRMATION')
                                                        ? const Color(0xFFB45309)
                                                        : (status == 'RTO_RETURNED' || status == 'CANCELLED'
                                                            ? const Color(0xFF991B1B)
                                                            : ((status == 'DISPATCHED' || status == 'OUT_FOR_DELIVERY')
                                                                ? const Color(0xFF0284C7)
                                                                : const Color(0xFF15803D))),
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '₹${order['net_payable'] ?? order['total'] ?? 0}',
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Divider(height: 1, color: Color(0xFFF1F5F9)),

                                  // Order Items List (Filter out kit pouch / packaging fees to customer)
                                  ...items.whereType<Map>().where((item) {
                                    final sku = (item['sku'] ?? '').toString().toUpperCase();
                                    final name = (item['name'] ?? item['title'] ?? item['item_name'] ?? '').toString().toLowerCase();
                                    return !sku.contains('POUCH') && !name.contains('pouch packaging') && !name.contains('pouch fee');
                                  }).map((rawItem) {
                                    final item = Map<String, dynamic>.from(rawItem);
                                    final itemName = item['name'] ?? item['title'] ?? item['item_name'] ?? 'Genuine Part';
                                    final qty = item['quantity'] ?? item['qty'] ?? 1;
                                    final rawComps = (item['components'] is List) ? (item['components'] as List) : const [];
                                    final childSerialFallback = (item['child_serials'] is List)
                                        ? (item['child_serials'] as List)
                                            .where((s) => s != null && s.toString().trim().isNotEmpty)
                                            .map((s) => <String, dynamic>{
                                                  'serial_number': s.toString().trim(),
                                                  'item_name': 'Kit Filter Component',
                                                })
                                            .toList()
                                        : const <Map<String, dynamic>>[];
                                    final allComponents = rawComps.isNotEmpty ? rawComps : childSerialFallback;
                                    final isKit = item['type'] == 'KIT' ||
                                        item['item_type'] == 'KIT' ||
                                        item['is_kit'] == true ||
                                        item['replacement_scope'] == 'WHOLE_KIT' ||
                                        allComponents.isNotEmpty;
                                    // Never show kit pouch to customer in component breakdown
                                    final components = allComponents.whereType<Map>().map((c) => Map<String, dynamic>.from(c)).where((cMap) {
                                      final cSku = (cMap['sku'] ?? '').toString().toUpperCase();
                                      final cName = (cMap['item_name'] ?? cMap['name'] ?? '').toString().toLowerCase();
                                      return !cSku.contains('POUCH') && !cName.contains('pouch') && cMap['is_complimentary'] != true;
                                    }).toList();

                                    final rawPrice = item['selling_price'] ?? item['price'] ?? item['mrp'] ?? (items.length == 1 ? (order['net_payable'] ?? order['total']) : null);
                                    final num priceNum = (rawPrice is num)
                                        ? rawPrice
                                        : (num.tryParse(rawPrice?.toString() ?? '') ?? (items.length == 1 ? (num.tryParse((order['net_payable'] ?? '1').toString()) ?? 1) : 0));
                                    final priceStr = priceNum % 1 == 0 ? priceNum.toInt().toString() : priceNum.toStringAsFixed(2);

                                    return Column(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 38,
                                                height: 38,
                                                decoration: BoxDecoration(
                                                  color: isKit ? const Color(0xFFF3E8FF) : const Color(0xFFF8FAFC),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Icon(
                                                  isKit ? Icons.layers_rounded : Icons.water_drop,
                                                  color: isKit ? const Color(0xFF9333EA) : const Color(0xFF0284C7),
                                                  size: 20,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '$itemName (x$qty)',
                                                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    if (item['is_replacement'] == true || item['new_serial_qr'] != null) ...[
                                                      const SizedBox(height: 3),
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFFECFDF5),
                                                          borderRadius: BorderRadius.circular(5),
                                                        ),
                                                        child: const Text(
                                                          'REPLACED PRODUCT',
                                                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFF047857)),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        'New Serial: ${item['new_serial_qr'] ?? item['serial_qr'] ?? ''}',
                                                        style: const TextStyle(fontSize: 10.5, color: Color(0xFF059669), fontFamily: 'monospace', fontWeight: FontWeight.w700),
                                                      ),
                                                      if ((item['defect_reason'] ?? '').toString().trim().isNotEmpty ||
                                                          (item['replacement_scope'] ?? '').toString().trim().isNotEmpty ||
                                                          (item['source_order_number'] ?? '').toString().trim().isNotEmpty)
                                                        Padding(
                                                          padding: const EdgeInsets.only(top: 3),
                                                          child: Wrap(
                                                            spacing: 6,
                                                            runSpacing: 4,
                                                            children: [
                                                              if ((item['defect_reason'] ?? '').toString().trim().isNotEmpty)
                                                                Container(
                                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                                  decoration: BoxDecoration(
                                                                    color: const Color(0xFFFFF7ED),
                                                                    borderRadius: BorderRadius.circular(5),
                                                                    border: Border.all(color: const Color(0xFFFED7AA)),
                                                                  ),
                                                                  child: Text(
                                                                    'Reason: ${item['defect_reason'].toString().replaceAll('_', ' ')}',
                                                                    style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFFC2410C)),
                                                                  ),
                                                                ),
                                                              if (item['replacement_scope'] == 'WHOLE_KIT')
                                                                Container(
                                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                                  decoration: BoxDecoration(
                                                                    color: const Color(0xFFF3E8FF),
                                                                    borderRadius: BorderRadius.circular(5),
                                                                  ),
                                                                  child: const Text(
                                                                    'WHOLE KIT REPLACED',
                                                                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFF7E22CE)),
                                                                  ),
                                                                ),
                                                              if ((item['source_order_number'] ?? '').toString().trim().isNotEmpty)
                                                                Text(
                                                                  'Orig Order: ${item['source_order_number']}',
                                                                  style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                                                                ),
                                                            ],
                                                          ),
                                                        ),
                                                    ] else if (item['serial_qr'] != null || item['hologram'] != null)
                                                      Text(
                                                        'Serial: ${item['serial_qr'] ?? item['hologram']}',
                                                        style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontFamily: 'monospace'),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              Text(
                                                (isReplacedOrder && priceNum == 0) ? 'FREE (₹0)' : '₹$priceStr',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                  color: (isReplacedOrder && priceNum == 0) ? const Color(0xFF059669) : const Color(0xFF475569),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Nested Kit Components Accordion
                                        if (isKit && components.isNotEmpty) ...[
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                            child: InkWell(
                                              onTap: () {
                                                setState(() {
                                                  if (isKitExpanded) {
                                                    _expandedKits.remove(orderId);
                                                  } else {
                                                    _expandedKits.add(orderId);
                                                  }
                                                });
                                              },
                                              borderRadius: BorderRadius.circular(8),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFAF5FF),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: const Color(0xFFE9D5FF)),
                                                ),
                                                child: Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Expanded(
                                                      child: Row(
                                                        children: [
                                                          const Icon(Icons.account_tree_outlined, size: 14, color: Color(0xFF9333EA)),
                                                          const SizedBox(width: 6),
                                                          Flexible(
                                                            child: Text(
                                                              'Kit Components (${components.length} Items)',
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF7E22CE)),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Icon(
                                                      isKitExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                                      size: 16,
                                                      color: const Color(0xFF7E22CE),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (isKitExpanded)
                                            Container(
                                              margin: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF8FAFC),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(color: const Color(0xFFE2E8F0)),
                                              ),
                                              child: Column(
                                                children: components.map<Widget>((compMap) {
                                                  return Padding(
                                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                                    child: Row(
                                                      children: [
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFE0F2FE),
                                                            borderRadius: BorderRadius.circular(4),
                                                          ),
                                                          child: Text(
                                                            (compMap['serial_qr'] ?? compMap['component_qr'] ?? compMap['serial_number'] ?? compMap['sku'] ?? 'PART').toString(),
                                                            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, color: Color(0xFF0369A1), fontFamily: 'monospace'),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 8),
                                                        Expanded(
                                                          child: Text(
                                                            (compMap['item_name'] ?? compMap['name'] ?? 'Filter Cartridge').toString(),
                                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                                                          ),
                                                        ),
                                                        InkWell(
                                                          onTap: () => _openProductDetail(compMap),
                                                          child: const Padding(
                                                            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                            child: Text(
                                                              'View Spec ->',
                                                              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF0284C7), decoration: TextDecoration.underline),
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            ),
                                        ],
                                        if (isKit && ((item['free_spares'] is List && (item['free_spares'] as List).isNotEmpty) || (item['free_spares_snapshot'] is List && (item['free_spares_snapshot'] as List).isNotEmpty))) ...[
                                          Builder(builder: (_) {
                                            final freeListRaw = (item['free_spares'] is List && (item['free_spares'] as List).isNotEmpty)
                                                ? (item['free_spares'] as List)
                                                : (item['free_spares_snapshot'] as List);
                                            return Container(
                                              width: double.infinity,
                                              margin: const EdgeInsets.only(top: 6, bottom: 4),
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFECFDF5),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(color: const Color(0xFFA7F3D0)),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                    '🎁 SEALED FREE SPARES INCLUDED (₹0)',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w800,
                                                      color: Color(0xFF047857),
                                                      letterSpacing: 0.4,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  ...freeListRaw.whereType<Map>().map((sp) {
                                                    final q = int.tryParse((sp['qty'] ?? sp['quantity'] ?? '1').toString()) ?? 1;
                                                    final mrp = double.tryParse((sp['unit_mrp'] ?? sp['mrp'] ?? '0').toString()) ?? 0.0;
                                                    final worth = (q > 0 ? q : 1) * mrp;
                                                    return Padding(
                                                      padding: const EdgeInsets.only(bottom: 3),
                                                      child: Row(
                                                        children: [
                                                          const Icon(Icons.card_giftcard_rounded, size: 13, color: Color(0xFF059669)),
                                                          const SizedBox(width: 6),
                                                          Expanded(
                                                            child: Text(
                                                              ProductUnitHelper.formatBomOrFreeName(
                                                                Map<String, dynamic>.from(sp),
                                                              ),
                                                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF065F46)),
                                                            ),
                                                          ),
                                                          Text(
                                                            worth > 0 ? 'Worth ₹${worth.toStringAsFixed(0)} FREE' : 'FREE',
                                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF16A34A)),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  }),
                                                ],
                                              ),
                                            );
                                          }),
                                        ],
                                      ],
                                    );
                                  }),

                                  // Pan-India Courier Tracking & Delivery Summary Bar
                                  if (!isTechnician && !isReplacedOrder) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                                      child: Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF8FAFC),
                                          borderRadius: BorderRadius.circular(12),
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
                                                    'PIN ${order['delivery_pincode'] ?? ''}${order['delivery_state'] != null && order['delivery_state'].toString().isNotEmpty ? ' • ${order['delivery_state']}' : ''}',
                                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF334155)),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                Text(
                                                  (num.tryParse((order['delivery_fee'] ?? '0').toString()) ?? 0) > 0
                                                      ? 'Courier ₹${order['delivery_fee']}'
                                                      : 'Courier FREE',
                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0284C7)),
                                                ),
                                              ],
                                            ),
                                            if (order['tracking_number'] != null && order['tracking_number'].toString().isNotEmpty) ...[
                                              const SizedBox(height: 6),
                                              Row(
                                                children: [
                                                  const Icon(Icons.local_shipping_outlined, size: 14, color: Color(0xFF0284C7)),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      '${order['courier_name'] ?? 'Courier'}: ${order['tracking_number']}',
                                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), fontFamily: 'monospace'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  if (order['tracking_url'] != null && order['tracking_url'].toString().isNotEmpty)
                                                    InkWell(
                                                      onTap: () => _launchExternalTracking(order['tracking_url']?.toString()),
                                                      child: const Text('Track ↗', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF2563EB), decoration: TextDecoration.underline)),
                                                    ),
                                                ],
                                              ),
                                            ],
                                            if (status == 'DELIVERED' && order['assigned_serials'] is List && (order['assigned_serials'] as List).isNotEmpty) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                'Warranty Active • ${(order['assigned_serials'] as List).length} genuine serial(s) linked',
                                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF059669)),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],

                                  // Order Footer
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            order['created_at'] != null
                                                ? 'Placed on ${order['created_at'].toString().split('T').first}'
                                                : (isTechnician ? 'Doorstep Handover' : 'Standard Delivery'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                          ),
                                        ),
                                        if (!isTechnician && !isReplacedOrder)
                                          TextButton.icon(
                                            onPressed: () => _openOnlineOrderTracker(orderId),
                                            icon: const Icon(Icons.timeline_rounded, size: 14, color: Color(0xFF0284C7)),
                                            label: const Text('Track', style: TextStyle(fontSize: 11, color: Color(0xFF0284C7), fontWeight: FontWeight.bold)),
                                          ),
                                        const SizedBox(width: 4),
                                        TextButton.icon(
                                          onPressed: () => _contactSupport(orderId),
                                          icon: const Icon(Icons.chat_bubble_outline, size: 13, color: Color(0xFF16A34A)),
                                          label: const Text('Help', style: TextStyle(fontSize: 11, color: Color(0xFF16A34A), fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ]
            // Tab 2: Doorstep Services (Lazy-Loaded Active Booking + Collapsed Service History)
            else ...[
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => Future.wait([
                    _fetchOrders(refresh: true),
                    _fetchServiceHistory(refresh: true),
                  ]),
                  child: Builder(
                    builder: (context) {
                      final hasActive =
                          widget.serviceState?.hasActiveBooking == true;
                      final displayTotal =
                          _serviceHistoryTotal > _serviceHistory.length
                              ? _serviceHistoryTotal
                              : _serviceHistory.length;
                      final isInitialLoading =
                          (!_serviceHistoryLoadedOnce || _isLoadingServiceHistory) &&
                              _serviceHistory.isEmpty;

                      final topWidgets = <Widget>[
                        if (hasActive)
                          Container(
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                  color: const Color(0xFFBAE6FD), width: 1.5),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x0A000000),
                                    blurRadius: 10,
                                    offset: Offset(0, 4)),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
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
                                              color: widget.serviceState
                                                          ?.isArrived ==
                                                      true
                                                  ? const Color(0xFFDCFCE7)
                                                  : const Color(0xFFE0F2FE),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              widget.serviceState?.isArrived ==
                                                      true
                                                  ? 'AT DOORSTEP'
                                                  : (widget.serviceState
                                                              ?.isInService ==
                                                          true
                                                      ? 'IN SERVICE'
                                                      : (widget.serviceState
                                                                  ?.isEnRoute ==
                                                              true
                                                          ? 'EN ROUTE'
                                                          : ((widget.serviceState
                                                                          ?.isOrderConfirmed ==
                                                                      true ||
                                                                  widget.serviceState
                                                                          ?.hasTechnicianAssigned ==
                                                                      true)
                                                              ? 'ASSIGNED'
                                                              : 'BOOKED'))),
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w900,
                                                color: widget.serviceState
                                                            ?.isArrived ==
                                                        true
                                                    ? const Color(0xFF16A34A)
                                                    : const Color(0xFF0284C7),
                                              ),
                                            ),
                                          ),
                                          if (widget.serviceState
                                                      ?.isFreeRevisit ==
                                                  true ||
                                              widget.serviceState
                                                      ?.isFreeVisit ==
                                                  true)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 7,
                                                      vertical: 2.5),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFEF3C7),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                    color: const Color(
                                                        0xFFFDE68A)),
                                              ),
                                              child: Text(
                                                widget.serviceState
                                                            ?.isFreeRevisit ==
                                                        true
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
                                      widget.serviceState?.fee == 0
                                          ? 'FREE (₹0)'
                                          : '₹${widget.serviceState?.fee ?? 49}',
                                      style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF0F172A)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  widget.serviceState?.serviceTitle ??
                                      'Quick RO Inspection & Diagnostics',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Technician: ${DisplaySanitizer.technicianName(widget.serviceState?.technicianName, fallback: "Assigned Staff")}${widget.serviceState?.technicianRating != null ? ' (${widget.serviceState!.technicianRating}★)' : ''}',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF475569)),
                                ),
                                const SizedBox(height: 12),
                                if (widget.serviceState?.shouldShowOtp ==
                                        true &&
                                    widget.serviceState?.arrivalOtp != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFEF3C7),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '🔑 Arrival OTP: ${widget.serviceState!.arrivalOtp} (Share with technician)',
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF92400E)),
                                    ),
                                  )
                                else if (widget.serviceState?.isInService ==
                                    true)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDCFCE7),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      '✓ OTP Verified • Service In Progress',
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF16A34A)),
                                    ),
                                  ),
                                if (_visitPurchasedSpares.isNotEmpty) ...[
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF0FDF4),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: const Color(0xFFBBF7D0)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Row(
                                          children: [
                                            Icon(Icons.verified_rounded,
                                                size: 15,
                                                color: Color(0xFF16A34A)),
                                            SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                '100% Genuine Spare Verified & Installed',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.w800,
                                                    color: Color(0xFF15803D)),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        ..._visitPurchasedSpares.map((sp) {
                                          final name = (sp['name'] ??
                                                  sp['product_name'] ??
                                                  'Genuine RO Spare')
                                              .toString();
                                          final qr = (sp['serial_number'] ??
                                                  sp['kit_qr'] ??
                                                  sp['component_qr'] ??
                                                  sp['serial_qr'] ??
                                                  sp['code'] ??
                                                  '')
                                              .toString();
                                          final spec =
                                              CbmSpecHelper.resolveItemSpec(sp);
                                          final metaParts = <String>[
                                            if (qr.isNotEmpty) 'Serial: $qr',
                                            if (spec.shortBadge != null)
                                              spec.shortBadge!,
                                          ];
                                          return Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 6),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                              border: Border.all(
                                                  color:
                                                      const Color(0xFFE2E8F0)),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(spec.icon,
                                                    size: 16,
                                                    color: spec.hasSpec
                                                        ? spec.pillForeground
                                                        : const Color(
                                                            0xFF0284C7)),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        name,
                                                        style: const TextStyle(
                                                            fontSize: 12,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            color: Color(
                                                                0xFF0F172A)),
                                                      ),
                                                      if (metaParts.isNotEmpty)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(top: 2),
                                                          child: Text(
                                                            metaParts
                                                                .join(' • '),
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              color: spec
                                                                      .hasSpec
                                                                  ? spec
                                                                      .pillForeground
                                                                  : const Color(
                                                                      0xFF475569),
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 6,
                                                      vertical: 2.5),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                        0xFFDCFCE7),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            5),
                                                  ),
                                                  child: const Text(
                                                    'PAID',
                                                    style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        color:
                                                            Color(0xFF16A34A)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                ],
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF0284C7),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                    ),
                                    icon: const Icon(Icons.location_on_rounded,
                                        size: 16),
                                    label: const Text(
                                        'Open Live Tracking & Hub',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12.5)),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      widget.onTrackServiceTap?.call();
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (isInitialLoading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          )
                        else if (_serviceHistory.isEmpty && !hasActive)
                          Padding(
                            padding: const EdgeInsets.only(top: 64),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _serviceHistoryError != null
                                        ? Icons.cloud_off_rounded
                                        : Icons.engineering_outlined,
                                    size: 48,
                                    color: const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _serviceHistoryError != null
                                        ? 'Could Not Load Service History'
                                        : 'No Service Bookings Yet',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _serviceHistoryError ??
                                        'Completed doorstep visits and installed spare serial numbers will appear here.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 12, color: Color(0xFF64748B)),
                                  ),
                                  if (_serviceHistoryError != null) ...[
                                    const SizedBox(height: 12),
                                    OutlinedButton(
                                      onPressed: () =>
                                          _fetchServiceHistory(refresh: true),
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          )
                        else if (_serviceHistory.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Service History',
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
                          ),
                      ];

                      final visitCount =
                          isInitialLoading ? 0 : _serviceHistory.length;
                      final itemCount = topWidgets.length +
                          visitCount +
                          (_isLoadingMoreServices ? 1 : 0);

                      return ListView.builder(
                        controller: _serviceScrollController,
                        padding: EdgeInsets.fromLTRB(
                          20,
                          4,
                          20,
                          24 + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (index < topWidgets.length) {
                            return topWidgets[index];
                          }
                          final visitIdx = index - topWidgets.length;
                          if (visitIdx >= _serviceHistory.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            );
                          }
                          final visit = _serviceHistory[visitIdx];
                          final visitKey = (visit['id'] ??
                                  visit['visit_number'] ??
                                  visitIdx)
                              .toString();
                          return ServiceHistoryVisitCard(
                            key: ValueKey('orders_visit_$visitKey'),
                            visit: visit,
                            onVisitRated: (updated) {
                              if (!mounted) return;
                              setState(() => _serviceHistory[visitIdx] = updated);
                            },
                          );
                        },
                      );
                    },
                  ),
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

  Widget _buildSavedRecoveryDraftCard() {
    final draft = widget.cartState.activeRecoveryDraft;
    if (draft == null) return const SizedBox.shrink();
    final draftId = draft['draft_id']?.toString();
    final isFailed = widget.cartState.isRecoveryDraftPaymentFailed;
    final daysLeft = widget.cartState.recoveryDraftDaysRemaining;
    final payable = widget.cartState.recoveryDraftPayable;
    final items = draft['items'] is List ? (draft['items'] as List) : const [];
    final firstItemName = (items.isNotEmpty && items.first is Map)
        ? ((items.first as Map)['name'] ?? 'Online Store Order').toString()
        : 'Online Store Order';
    final extraCount = items.length > 1 ? ' + ${items.length - 1} more' : '';
    final failReason = draft['last_failure_reason']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isFailed
              ? const [Color(0xFFFFF1F2), Color(0xFFFFFBEB)]
              : const [Color(0xFFEFF6FF), Color(0xFFF0FDF4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isFailed ? const Color(0xFFFECDD3) : const Color(0xFFBFDBFE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isFailed ? const Color(0xFFBE123C) : const Color(0xFF0284C7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isFailed ? 'PAYMENT INCOMPLETE' : 'SAVED ONLINE CART',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${daysLeft > 0 ? "$daysLeft d" : "<24h"} left to resume',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF64748B)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Dismiss saved draft',
                onPressed: () => widget.cartState.dismissOnlineRecoveryDraft(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$firstItemName$extraCount',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    if (isFailed && failReason.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        failReason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF9F1239),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '₹$payable',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                if (widget.onResumeSavedDraft != null) {
                  await widget.onResumeSavedDraft!(draftId: draftId);
                  return;
                }
                final nav = Navigator.of(context);
                final rootContext = Navigator.of(context, rootNavigator: true).context;
                await widget.cartState.resumeActiveOnlineDraft(draftId: draftId);
                nav.pop();
                if (!rootContext.mounted) return;
                showModalBottomSheet(
                  context: rootContext,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => CartBottomSheet(
                    cartState: widget.cartState,
                    initialStep: 1,
                    resumeDraftId: draftId,
                  ),
                );
              },
              icon: const Icon(Icons.replay_circle_filled_rounded, size: 17),
              label: const Text(
                'Resume Order (Pay Online or COD)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
