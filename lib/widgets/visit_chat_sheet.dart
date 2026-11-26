import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/api_service.dart';
import '../utils/display_sanitizer.dart';

Future<void> showCustomerVisitChatSheet(
  BuildContext context, {
  required String visitId,
  required String technicianName,
  String? technicianPhotoUrl,
  double? initialLat,
  double? initialLng,
  String? serviceAddress,
  ValueChanged<BuildContext>? onSheetContextReady,
  VoidCallback? onChatClosedOrRead,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _CustomerVisitChatSheet(
      visitId: visitId,
      technicianName: technicianName,
      technicianPhotoUrl: technicianPhotoUrl,
      initialLat: initialLat,
      initialLng: initialLng,
      serviceAddress: serviceAddress,
      onSheetContextReady: onSheetContextReady,
    ),
  ).whenComplete(() => onChatClosedOrRead?.call());
}

class _CustomerVisitChatSheet extends StatefulWidget {
  final String visitId;
  final String technicianName;
  final String? technicianPhotoUrl;
  final double? initialLat;
  final double? initialLng;
  final String? serviceAddress;
  final ValueChanged<BuildContext>? onSheetContextReady;

  const _CustomerVisitChatSheet({
    required this.visitId,
    required this.technicianName,
    this.technicianPhotoUrl,
    this.initialLat,
    this.initialLng,
    this.serviceAddress,
    this.onSheetContextReady,
  });

  @override
  State<_CustomerVisitChatSheet> createState() =>
      _CustomerVisitChatSheetState();
}

class _CustomerVisitChatSheetState extends State<_CustomerVisitChatSheet>
    with WidgetsBindingObserver {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];

  StreamSubscription<Map<String, dynamic>>? _sseSub;
  Timer? _reconnectTimer;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isSseLive = false;
  bool _canSend = true;
  bool _isAppPaused = false;
  bool _silentRollover = false;
  int _sseFailureCount = 0;
  String? _statusNotice;
  int _latestSeq = 0;
  int _peerSeenSeq = 0;
  int _locationCount = 0;
  int _maxLocationPins = 5;

  static const List<int> _reconnectBackoffSec = <int>[5, 12, 25, 45];

  static const List<String> _quickReplies = <String>[
    'What is your ETA?',
    'Call me when you reach',
    'Gate is unlocked',
    'Please wait 2 mins',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSheetContextReady?.call(context);
    });
    _loadInitialAndConnect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sseSub?.cancel();
    _reconnectTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _isAppPaused = true;
      _reconnectTimer?.cancel();
      _sseSub?.cancel();
      _sseSub = null;
      if (mounted && _isSseLive) {
        setState(() => _isSseLive = false);
      } else {
        _isSseLive = false;
      }
    } else if (state == AppLifecycleState.resumed && _isAppPaused) {
      _isAppPaused = false;
      if (mounted && _canSend) {
        _openSseStream();
      }
    }
  }

  Future<void> _loadInitialAndConnect() async {
    await _fetchMessages(afterSeq: 0);
    if (!mounted || _isAppPaused || !_canSend) return;
    _openSseStream();
  }

  Future<void> _fetchMessages({required int afterSeq}) async {
    final res = await ApiService().getVisitChatMessages(
      widget.visitId,
      afterSeq: afterSeq,
    );
    if (!mounted) return;

    if (res['success'] == true) {
      final list = (res['messages'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _isLoading = false;
        _canSend = res['can_send'] == true;
        final peerSeen = (res['peer_seen_seq'] as num?)?.toInt() ?? 0;
        if (peerSeen > _peerSeenSeq) _peerSeenSeq = peerSeen;
        _locationCount = (res['location_count'] as num?)?.toInt() ?? _locationCount;
        _maxLocationPins =
            (res['max_location_pins'] as num?)?.toInt() ?? _maxLocationPins;
        if (list.isNotEmpty) {
          _mergeMessages(list);
        }
        final visitStatus = (res['visit_status'] ?? '').toString().toUpperCase();
        _statusNotice = _canSend
            ? null
            : (visitStatus == 'IN_PROGRESS'
                ? 'Arrival OTP verified. Visit chat session has ended.'
                : 'Visit finished or closed. Chat is read-only (retained for review).');
      });
    } else {
      final sc = res['statusCode'];
      setState(() {
        _isLoading = false;
        if (sc == 403 || sc == 404 || sc == 410) {
          _canSend = false;
        }
        _statusNotice = (res['message'] ?? 'Unable to load chat').toString();
      });
    }
  }

  void _mergeMessages(List<Map<String, dynamic>> incoming) {
    final existingIds = _messages.map((m) => m['id']?.toString() ?? '').toSet();
    bool added = false;
    for (final m in incoming) {
      final id = m['id']?.toString() ?? '';
      if (id.isNotEmpty && existingIds.contains(id)) continue;
      if (id.isNotEmpty) existingIds.add(id);
      _messages.add(m);
      final seq = (m['seq'] as num?)?.toInt() ?? 0;
      if (seq > _latestSeq) _latestSeq = seq;
      added = true;
    }
    if (added) {
      _messages.sort((a, b) =>
          ((a['seq'] as num?)?.toInt() ?? 0).compareTo((b['seq'] as num?)?.toInt() ?? 0));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _openSseStream() {
    if (!mounted || _isAppPaused || !_canSend) return;
    _sseSub?.cancel();
    _reconnectTimer?.cancel();
    _silentRollover = false;

    _sseSub = ApiService().watchVisitChatEvents(widget.visitId).listen(
      (ev) {
        if (!mounted) return;
        final evName = (ev['_event'] ?? '').toString().toLowerCase();
        if (evName == 'ready') {
          final remoteSeq = (ev['latest_seq'] as num?)?.toInt() ?? 0;
          final peerSeen = (ev['peer_seen_seq'] as num?)?.toInt() ?? 0;
          _sseFailureCount = 0;
          _silentRollover = false;
          setState(() {
            _isSseLive = true;
            _canSend = ev['can_send'] == true;
            if (peerSeen > _peerSeenSeq) _peerSeenSeq = peerSeen;
          });
          if (!_canSend) {
            _sseSub?.cancel();
            return;
          }
          if (remoteSeq > _latestSeq) {
            unawaited(_fetchMessages(afterSeq: _latestSeq));
          }
          return;
        }
        if (evName == 'seen') {
          if ((ev['role'] ?? '').toString().toUpperCase() == 'TECHNICIAN') {
            final seenSeq = (ev['seen_seq'] as num?)?.toInt() ?? 0;
            if (seenSeq > _peerSeenSeq) {
              setState(() => _peerSeenSeq = seenSeq);
            }
          }
          return;
        }
        if (evName == 'timeout') {
          _silentRollover = true;
          return;
        }
        if (evName == 'chat_closed') {
          _reconnectTimer?.cancel();
          final rawReason = (ev['reason'] ?? 'CLOSED').toString().toUpperCase();
          final endedOnOtp = rawReason == 'OTP_VERIFIED' || rawReason == 'IN_PROGRESS';
          setState(() {
            _isSseLive = false;
            _canSend = false;
            _statusNotice = endedOnOtp
                ? 'Arrival OTP verified • Visit chat session ended.'
                : 'Visit updated/closed (${ev['reason'] ?? 'CLOSED'}). Chat is now read-only.';
          });
          if (endedOnOtp) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) Navigator.of(context).maybePop();
            });
          }
          return;
        }
        if (evName == 'message' || ev.containsKey('seq')) {
          setState(() {
            _mergeMessages([ev]);
            if (ev['type'] == 'location') {
              _locationCount += 1;
            }
          });
          if ((ev['sender_role'] ?? '').toString().toUpperCase() == 'TECHNICIAN') {
            final seq = (ev['seq'] as num?)?.toInt() ?? 0;
            if (seq > 0) unawaited(ApiService().markVisitChatSeen(widget.visitId, seq));
          }
        }
      },
      onError: (_) {
        _silentRollover = false;
        _scheduleReconnect(hadError: true);
      },
      onDone: () => _scheduleReconnect(hadError: !_silentRollover),
    );
  }

  void _scheduleReconnect({required bool hadError}) {
    if (!mounted || !_canSend || _isAppPaused) {
      if (mounted && _isSseLive) setState(() => _isSseLive = false);
      return;
    }

    _reconnectTimer?.cancel();
    if (_silentRollover && !hadError) {
      _silentRollover = false;
      _reconnectTimer = Timer(const Duration(milliseconds: 400), () {
        if (mounted && _canSend && !_isAppPaused) _openSseStream();
      });
      return;
    }

    _sseFailureCount += 1;
    if (_isSseLive) {
      setState(() => _isSseLive = false);
    }
    final delaySec = _reconnectBackoffSec[
        math.min(_sseFailureCount - 1, _reconnectBackoffSec.length - 1)];

    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      if (!mounted || !_canSend || _isAppPaused) return;
      if (_sseFailureCount >= 2) {
        await _fetchMessages(afterSeq: _latestSeq);
        if (!mounted || !_canSend || _isAppPaused) return;
      }
      _openSseStream();
    });
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  String _nextClientMsgId() {
    final rng = math.Random().nextInt(99999);
    return 'c_${DateTime.now().microsecondsSinceEpoch}_$rng';
  }

  Future<void> _sendText([String? preset]) async {
    final clean = (preset ?? _textCtrl.text).trim();
    if (clean.isEmpty || _isSending || !_canSend) return;

    setState(() => _isSending = true);
    if (preset == null) _textCtrl.clear();

    final res = await ApiService().sendVisitChatMessage(
      visitId: widget.visitId,
      payload: {
        'type': 'text',
        'text': clean,
        'client_msg_id': _nextClientMsgId(),
      },
    );
    if (!mounted) return;

    setState(() => _isSending = false);
    if (res['success'] == true && res['message'] is Map) {
      setState(() => _mergeMessages([Map<String, dynamic>.from(res['message'] as Map)]));
    } else {
      final errCode = (res['error'] ?? '').toString();
      if (errCode == 'CHAT_CLOSED' || res['statusCode'] == 410) {
        setState(() {
          _canSend = false;
          _statusNotice = 'Visit closed. Chat is read-only.';
        });
      }
      _showToast((res['message'] ?? 'Could not send message').toString());
    }
  }

  Future<void> _openShareLocationPicker() async {
    if (!_canSend || _isSending) return;
    if (_locationCount >= _maxLocationPins) {
      _showToast('Maximum $_maxLocationPins location pins can be shared per visit.');
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationPinPickerModal(
        fallbackLat: widget.initialLat ?? 12.9279,
        fallbackLng: widget.initialLng ?? 77.6740,
        addressHint: widget.serviceAddress,
      ),
    );

    if (result == null || !mounted) return;
    setState(() => _isSending = true);
    final res = await ApiService().sendVisitChatMessage(
      visitId: widget.visitId,
      payload: {
        'type': 'location',
        'lat': result['lat'],
        'lng': result['lng'],
        'note': result['note'] ?? '',
        'client_msg_id': _nextClientMsgId(),
      },
    );
    if (!mounted) return;

    setState(() => _isSending = false);
    if (res['success'] == true && res['message'] is Map) {
      setState(() {
        _locationCount += 1;
        _mergeMessages([Map<String, dynamic>.from(res['message'] as Map)]);
      });
    } else {
      _showToast((res['message'] ?? 'Could not share location pin').toString());
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final techDisplay = DisplaySanitizer.technicianName(
      widget.technicianName,
      fallback: 'Assigned Technician',
    );
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final height = MediaQuery.sizeOf(context).height * 0.78;

    return Container(
      height: height + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Color(0xFFEFEAE2),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle + Apple-style Glass Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Column(
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 19,
                      backgroundColor: const Color(0xFFE0F2FE),
                      backgroundImage: (widget.technicianPhotoUrl != null &&
                              widget.technicianPhotoUrl!.isNotEmpty)
                          ? NetworkImage(widget.technicianPhotoUrl!)
                          : null,
                      child: (widget.technicianPhotoUrl == null ||
                              widget.technicianPhotoUrl!.isEmpty)
                          ? Text(
                              techDisplay[0].toUpperCase(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0284C7),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  techDisplay,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: !_canSend
                                      ? const Color(0xFFF1F5F9)
                                      : (_isSseLive
                                          ? const Color(0xFFDCFCE7)
                                          : const Color(0xFFFEF3C7)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  !_canSend
                                      ? 'Closed'
                                      : (_isSseLive ? 'Live' : 'Syncing'),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: !_canSend
                                        ? const Color(0xFF475569)
                                        : (_isSseLive
                                            ? const Color(0xFF15803D)
                                            : const Color(0xFFB45309)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Text(
                            'Private visit chat • Numbers stay protected',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, color: Color(0xFF475569)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_statusNotice != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: const Color(0xFFFFFBEB),
              child: Text(
                _statusNotice!,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF92400E),
                ),
              ),
            ),

          // Messages timeline
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.2))
                : _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const Icon(
                                  Icons.mark_chat_unread_outlined,
                                  size: 30,
                                  color: Color(0xFF0F766E),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Coordinate arrival with $techDisplay',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Send quick instructions or tap the Location Pin button to help your technician find your exact doorstep.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                        itemCount: _messages.length,
                        itemBuilder: (_, idx) => _buildBubble(_messages[idx]),
                      ),
          ),

          // Quick reply pills & Composer
          if (_canSend)
            Container(
              color: Colors.white,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 32,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _quickReplies.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (_, idx) {
                        final label = _quickReplies[idx];
                        return ActionChip(
                          label: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F766E),
                            ),
                          ),
                          backgroundColor: const Color(0xFFF0FDFA),
                          side: const BorderSide(color: Color(0xFF99F6E4)),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          onPressed: _isSending ? null : () => _sendText(label),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Tooltip(
                        message: 'Share Doorstep Location Pin',
                        child: InkWell(
                          onTap: _isSending ? null : _openShareLocationPicker,
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFFA7F3D0)),
                            ),
                            child: const Icon(
                              Icons.add_location_alt_rounded,
                              color: Color(0xFF0F766E),
                              size: 21,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _textCtrl,
                          maxLength: 300,
                          maxLines: 3,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendText(),
                          decoration: InputDecoration(
                            counterText: '',
                            hintText: 'Message $techDisplay...',
                            hintStyle: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF94A3B8),
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF8FAFC),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: Color(0xFF0F766E)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 42,
                        height: 42,
                        child: ElevatedButton(
                          onPressed: _isSending ? null : () => _sendText(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F172A),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _isSending
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 18),
                        ),
                      ),
                    ],
                  ),
                ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBubble(Map<String, dynamic> msg) {
    final isMine =
        (msg['sender_role'] ?? '').toString().toUpperCase() == 'CUSTOMER';
    final msgType = (msg['type'] ?? 'text').toString().toLowerCase();
    final timeStr = _formatIstTime(msg['created_at']?.toString());
    final seq = (msg['seq'] as num?)?.toInt() ?? 0;
    final isSeen = isMine && seq > 0 && seq <= _peerSeenSeq;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMine ? const Color(0xFFD9FDD3) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMine ? 14 : 4),
            bottomRight: Radius.circular(isMine ? 4 : 14),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (msgType == 'location') ...[
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.location_on_rounded,
                    size: 16,
                    color: Color(0xFF0F766E),
                  ),
                  SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      'Doorstep Location Pin',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111B21),
                      ),
                    ),
                  ),
                ],
              ),
              if ((msg['note'] ?? '').toString().trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  msg['note'].toString().trim(),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF3B4A54),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '${(msg['lat'] as num?)?.toStringAsFixed(5) ?? ''}, ${(msg['lng'] as num?)?.toStringAsFixed(5) ?? ''}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: Color(0xFF667781),
                ),
              ),
            ] else
              Text(
                (msg['text'] ?? '').toString(),
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.32,
                  color: Color(0xFF111B21),
                ),
              ),
            if (timeStr.isNotEmpty || isMine) ...[
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (timeStr.isNotEmpty)
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: Color(0xFF667781),
                      ),
                    ),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.done_all_rounded,
                      size: 14,
                      color: isSeen
                          ? const Color(0xFF0284C7)
                          : const Color(0xFF8696A0),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatIstTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final hh = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hh:$mm $suffix';
  }
}

class _LocationPinPickerModal extends StatefulWidget {
  final double fallbackLat;
  final double fallbackLng;
  final String? addressHint;

  const _LocationPinPickerModal({
    required this.fallbackLat,
    required this.fallbackLng,
    this.addressHint,
  });

  @override
  State<_LocationPinPickerModal> createState() => _LocationPinPickerModalState();
}

class _LocationPinPickerModalState extends State<_LocationPinPickerModal> {
  final MapController _mapCtrl = MapController();
  final TextEditingController _noteCtrl = TextEditingController();
  late ll.LatLng _pin;
  bool _fetchingGps = false;

  @override
  void initState() {
    super.initState();
    _pin = ll.LatLng(widget.fallbackLat, widget.fallbackLng);
    unawaited(_useCurrentGps(silent: true));
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _useCurrentGps({bool silent = false}) async {
    if (_fetchingGps) return;
    setState(() => _fetchingGps = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Turn on GPS or tap on the map to place pin.')),
          );
        }
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && !silent) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return;
      }
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      );
      if (mounted && (pos.latitude.abs() > 0.001 || pos.longitude.abs() > 0.001)) {
        final next = ll.LatLng(pos.latitude, pos.longitude);
        setState(() => _pin = next);
        _mapCtrl.move(next, 16.5);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _fetchingGps = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final sysBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomInset + sysBottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.location_pin, color: Color(0xFF0F766E)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Share Exact Doorstep Pin',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _fetchingGps ? null : () => _useCurrentGps(silent: false),
                icon: _fetchingGps
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location_rounded, size: 16),
                label: const Text('My GPS', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Tap anywhere on the map to fine-tune where the technician should arrive.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 220,
              child: FlutterMap(
                mapController: _mapCtrl,
                options: MapOptions(
                  initialCenter: _pin,
                  initialZoom: 16,
                  onTap: (_, tapped) => setState(() => _pin = tapped),
                ),
                children: [
                  TileLayer(
                    urlTemplate: ApiService.cartoTileUrl,
                    userAgentPackageName: 'in.roparts.roparts',
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _pin,
                        width: 44,
                        height: 44,
                        child: const Icon(
                          Icons.location_pin,
                          size: 40,
                          color: Color(0xFF0F766E),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _noteCtrl,
            maxLength: 80,
            decoration: InputDecoration(
              counterText: '',
              hintText: 'Landmark note (e.g. Near blue gate, 2nd floor)',
              hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context, <String, dynamic>{
                  'lat': _pin.latitude,
                  'lng': _pin.longitude,
                  'note': _noteCtrl.text.trim(),
                });
              },
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text(
                'Send Doorstep Location Pin',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

