import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../state/cart_state.dart';
import '../theme/app_theme.dart';
import 'auth_sheet.dart';

/// Opens the in-app Zone-Routed Customer <-> Zone Manager Support Chat sheet.
/// Automatically resolves the customer's service zone on the backend (or routes
/// out-of-zone customers directly to ROParts HQ Super Admin), with zero external WhatsApp links.
Future<void> showZoneSupportChatSheet(
  BuildContext context, {
  String? visitId,
  String? orderId,
  String? threadId,
  String? issueType,
  double? lat,
  double? lng,
  List<String>? quickPrompts,
  CartState? cartState,
}) async {
  if (!ApiService.hasAuthToken && cartState != null && !cartState.isLoggedIn) {
    await AuthSheet.show(
      context,
      cartState: cartState,
      onAuthSuccess: () {
        if (context.mounted) {
          unawaited(
            showZoneSupportChatSheet(
              context,
              visitId: visitId,
              orderId: orderId,
              threadId: threadId,
              issueType: issueType,
              lat: lat,
              lng: lng,
              quickPrompts: quickPrompts,
              cartState: cartState,
            ),
          );
        }
      },
    );
    return;
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ZoneSupportChatSheet(
      visitId: visitId,
      orderId: orderId,
      threadId: threadId,
      issueType: issueType,
      lat: lat,
      lng: lng,
      quickPrompts: quickPrompts,
    ),
  );
}

class _ZoneSupportChatSheet extends StatefulWidget {
  final String? visitId;
  final String? orderId;
  final String? threadId;
  final String? issueType;
  final double? lat;
  final double? lng;
  final List<String>? quickPrompts;

  const _ZoneSupportChatSheet({
    this.visitId,
    this.orderId,
    this.threadId,
    this.issueType,
    this.lat,
    this.lng,
    this.quickPrompts,
  });

  @override
  State<_ZoneSupportChatSheet> createState() => _ZoneSupportChatSheetState();
}

class _SupportSessionArchive {
  final String threadId;
  final String status;
  final String? resolvedBy;
  final List<Map<String, dynamic>> messages;

  const _SupportSessionArchive({
    required this.threadId,
    required this.status,
    required this.resolvedBy,
    required this.messages,
  });

  bool get isAutoExpired =>
      (resolvedBy ?? '').toUpperCase() == 'AUTO_SESSION_TIMEOUT';
}

class _ZoneSupportChatSheetState extends State<_ZoneSupportChatSheet>
    with WidgetsBindingObserver {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<_SupportSessionArchive> _historySegments = <_SupportSessionArchive>[];
  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];

  StreamSubscription<Map<String, dynamic>>? _sseSub;
  Timer? _reconnectTimer;

  String? _threadId;
  String? _resolvedBy;
  String _zoneName = 'Assigning Zone Desk...';
  String _status = 'OPEN';
  bool _isOutOfZone = false;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isStartingNewSession = false;
  bool _isSseLive = false;
  bool _isAppPaused = false;
  bool _silentRollover = false;
  bool _showSessionStartedNotice = false;
  int _sseFailureCount = 0;
  int _latestSeq = 0;
  int _peerSeenSeq = 0;
  String? _errorNotice;

  static const List<int> _reconnectBackoffSec = <int>[4, 10, 20, 40];

  static const List<String> _defaultPrompts = <String>[
    'Request Reschedule / Change Visit Slot',
    'Machine diagnostics / service question',
    'Spares billing / pricing query',
    'Upgrade to Complete Service (₹149)',
    'Urgent: Please arrange a Zone Manager call',
  ];

  List<String> get _prompts => widget.quickPrompts ?? _defaultPrompts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initThreadAndMessages();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _sseSub?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isAppPaused = true;
      _reconnectTimer?.cancel();
      _sseSub?.cancel();
      if (mounted && _isSseLive) setState(() => _isSseLive = false);
    } else if (state == AppLifecycleState.resumed) {
      _isAppPaused = false;
      if (_threadId != null && _status != 'RESOLVED' && mounted) {
        unawaited(_fetchMessages(afterSeq: _latestSeq));
        _openSseStream();
      }
    }
  }

  List<_SupportSessionArchive> _parsePreviousSessions(dynamic rawPrev) {
    if (rawPrev is! List) return const [];
    final out = <_SupportSessionArchive>[];
    for (final entry in rawPrev) {
      if (entry is! Map) continue;
      final tMap = entry['thread'] is Map
          ? Map<String, dynamic>.from(entry['thread'] as Map)
          : <String, dynamic>{};
      final rawMsgs = entry['messages'] is List ? entry['messages'] as List : const [];
      final msgs = rawMsgs
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      if (msgs.isEmpty) continue;
      out.add(_SupportSessionArchive(
        threadId: tMap['thread_id']?.toString() ?? '',
        status: tMap['status']?.toString().toUpperCase() ?? 'RESOLVED',
        resolvedBy: tMap['resolved_by']?.toString(),
        messages: msgs,
      ));
    }
    return out;
  }

  Future<void> _initThreadAndMessages({bool forceNew = false}) async {
    setState(() {
      _isLoading = true;
      _errorNotice = null;
    });

    if (widget.threadId != null && widget.threadId!.trim().isNotEmpty && !forceNew) {
      _threadId = widget.threadId!.trim();
    } else {
      final res = await ApiService().openOrCreateSupportThread(
        visitId: widget.visitId,
        orderId: widget.orderId,
        issueType: widget.issueType,
        lat: widget.lat,
        lng: widget.lng,
        forceNew: forceNew,
      );
      if (!mounted) return;
      if (res['success'] != true || res['thread'] is! Map) {
        setState(() {
          _isLoading = false;
          _errorNotice = res['message']?.toString() ?? 'Unable to connect to Zone Support Desk.';
        });
        return;
      }
      final t = Map<String, dynamic>.from(res['thread'] as Map);
      final parsedPrev = _parsePreviousSessions(res['previous_sessions']);
      setState(() {
        _applyThreadMeta(t);
        if (!forceNew) {
          _historySegments
            ..clear()
            ..addAll(parsedPrev);
        }
        _showSessionStartedNotice = parsedPrev.isNotEmpty || _historySegments.isNotEmpty;
        if (forceNew) {
          _messages.clear();
          _latestSeq = 0;
          _peerSeenSeq = 0;
        }
      });
    }

    await _fetchMessages();
    if (!mounted) return;

    // If opened via old notification threadId that is already resolved/expired,
    // keep its messages as history and auto-open a fresh session right below.
    if (widget.threadId != null &&
        widget.threadId!.trim().isNotEmpty &&
        !forceNew &&
        _status == 'RESOLVED') {
      await _continueToNewSession(preserveCurrent: true);
      if (!mounted) return;
      setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = false);
    if (_status != 'RESOLVED') {
      _openSseStream();
    }
  }

  void _applyThreadMeta(Map<String, dynamic> t) {
    _threadId = t['thread_id']?.toString() ?? _threadId;
    _isOutOfZone = t['is_out_of_zone'] == true || t['zone_id'] == null;
    final rawZone = t['zone_name']?.toString().trim() ?? '';
    _zoneName = _isOutOfZone
        ? 'ROParts HQ Support'
        : (rawZone.isNotEmpty ? '$rawZone Zone Desk' : 'Zone Manager Desk');
    _status = t['status']?.toString().toUpperCase() ?? 'OPEN';
    _resolvedBy = t['resolved_by']?.toString();
  }

  Future<bool> _continueToNewSession({
    bool preserveCurrent = true,
  }) async {
    if (_isStartingNewSession || !mounted) return false;
    setState(() {
      _isStartingNewSession = true;
      _errorNotice = null;
    });

    _reconnectTimer?.cancel();
    _sseSub?.cancel();

    final oldTid = _threadId ?? '';
    final oldMsgs = List<Map<String, dynamic>>.from(_messages);
    final oldResolvedBy = _resolvedBy;

    final res = await ApiService().openOrCreateSupportThread(
      visitId: widget.visitId,
      orderId: widget.orderId,
      issueType: widget.issueType,
      lat: widget.lat,
      lng: widget.lng,
      forceNew: true,
    );
    if (!mounted) return false;

    if (res['success'] != true || res['thread'] is! Map) {
      setState(() => _isStartingNewSession = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message']?.toString() ?? 'Could not start a new session'),
          backgroundColor: const Color(0xFFDC2626),
        ),
      );
      return false;
    }

    final newThread = Map<String, dynamic>.from(res['thread'] as Map);
    setState(() {
      if (preserveCurrent && oldTid.isNotEmpty && oldMsgs.isNotEmpty) {
        final alreadyArchived = _historySegments.any((h) => h.threadId == oldTid);
        if (!alreadyArchived) {
          _historySegments.add(_SupportSessionArchive(
            threadId: oldTid,
            status: 'RESOLVED',
            resolvedBy: oldResolvedBy,
            messages: oldMsgs,
          ));
        }
      }
      _messages.clear();
      _latestSeq = 0;
      _peerSeenSeq = 0;
      _applyThreadMeta(newThread);
      _showSessionStartedNotice = _historySegments.isNotEmpty;
      _isStartingNewSession = false;
      _isSseLive = false;
    });

    _openSseStream();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    return true;
  }

  Future<void> _fetchMessages({int afterSeq = 0}) async {
    final tid = _threadId;
    if (tid == null || tid.isEmpty) return;

    final res = await ApiService().getSupportMessages(tid, afterSeq: afterSeq);
    if (!mounted) return;
    if (res['success'] == true) {
      final rawList = (res['messages'] as List?) ?? const [];
      final incoming = rawList
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final threadMap = res['thread'] is Map
          ? Map<String, dynamic>.from(res['thread'] as Map)
          : null;
      final remotePeerSeen = (res['peer_seen_seq'] as num?)?.toInt() ?? 0;
      final parsedPrev = afterSeq == 0
          ? _parsePreviousSessions(res['previous_sessions'])
          : const <_SupportSessionArchive>[];

      setState(() {
        if (threadMap != null) _applyThreadMeta(threadMap);
        if (afterSeq == 0 && parsedPrev.isNotEmpty) {
          _historySegments
            ..clear()
            ..addAll(parsedPrev);
          _showSessionStartedNotice = true;
        }
        if (remotePeerSeen > _peerSeenSeq) _peerSeenSeq = remotePeerSeen;
        if (afterSeq == 0) _messages.clear();
        _mergeMessages(incoming);
      });

      if (_latestSeq > 0) {
        unawaited(ApiService().markSupportSeen(tid, _latestSeq));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (afterSeq == 0 && _messages.isEmpty) {
      setState(() {
        _errorNotice = res['message']?.toString() ?? 'Could not load support history.';
      });
    }
  }

  void _mergeMessages(List<Map<String, dynamic>> incoming) {
    for (final m in incoming) {
      final seq = (m['seq'] as num?)?.toInt() ?? 0;
      if (seq > _latestSeq) _latestSeq = seq;
      final cid = m['client_msg_id']?.toString() ?? '';
      final dup = _messages.any((e) =>
          (seq > 0 && (e['seq'] as num?)?.toInt() == seq) ||
          (cid.isNotEmpty && e['client_msg_id']?.toString() == cid));
      if (!dup) {
        _messages.add(m);
      }
    }
    _messages.sort((a, b) =>
        ((a['seq'] as num?)?.toInt() ?? 0).compareTo((b['seq'] as num?)?.toInt() ?? 0));
  }

  void _openSseStream() {
    final tid = _threadId;
    if (tid == null || tid.isEmpty || !mounted || _isAppPaused || _status == 'RESOLVED') return;
    _sseSub?.cancel();
    _silentRollover = false;

    _sseSub = ApiService().watchSupportChatEvents(tid).listen(
      (ev) {
        if (!mounted) return;
        final evName = (ev['_event'] ?? '').toString().toLowerCase();
        if (evName == 'ready') {
          final remoteSeq = (ev['latest_seq'] as num?)?.toInt() ?? 0;
          final peerSeen = (ev['peer_seen_seq'] as num?)?.toInt() ?? 0;
          final readyStatus = ev['status']?.toString().toUpperCase();
          _sseFailureCount = 0;
          _silentRollover = false;
          setState(() {
            _isSseLive = readyStatus != 'RESOLVED';
            if (peerSeen > _peerSeenSeq) _peerSeenSeq = peerSeen;
            if (readyStatus != null && readyStatus.isNotEmpty) _status = readyStatus;
          });
          if (_status == 'RESOLVED') {
            _sseSub?.cancel();
            return;
          }
          if (remoteSeq > _latestSeq) {
            unawaited(_fetchMessages(afterSeq: _latestSeq));
          }
          return;
        }
        if (evName == 'seen') {
          final role = (ev['role'] ?? '').toString().toUpperCase();
          if (role == 'ZONE_MANAGER' || role == 'SUPER_ADMIN') {
            final seenSeq = (ev['seen_seq'] as num?)?.toInt() ?? 0;
            if (seenSeq > _peerSeenSeq) {
              setState(() => _peerSeenSeq = seenSeq);
            }
          }
          return;
        }
        if (evName == 'thread_updated') {
          final nextStatus = ev['status']?.toString().toUpperCase();
          if (nextStatus != null && nextStatus.isNotEmpty) {
            setState(() {
              _status = nextStatus;
              if (ev['resolved_by'] != null) {
                _resolvedBy = ev['resolved_by'].toString();
              }
              if (nextStatus == 'RESOLVED') {
                _isSseLive = false;
              }
            });
            if (nextStatus == 'RESOLVED') {
              _reconnectTimer?.cancel();
              _sseSub?.cancel();
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
            }
          }
          return;
        }
        if (evName == 'timeout') {
          _silentRollover = true;
          return;
        }
        if (evName == 'message' || ev.containsKey('seq')) {
          setState(() {
            _mergeMessages([ev]);
            if (ev['status'] != null) {
              _status = ev['status'].toString().toUpperCase();
            }
          });
          final role = (ev['sender_role'] ?? '').toString().toUpperCase();
          if (role != 'CUSTOMER') {
            final seq = (ev['seq'] as num?)?.toInt() ?? 0;
            if (seq > 0) unawaited(ApiService().markSupportSeen(tid, seq));
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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
    if (!mounted || _isAppPaused || _threadId == null || _status == 'RESOLVED') {
      if (mounted && _isSseLive) setState(() => _isSseLive = false);
      return;
    }
    _reconnectTimer?.cancel();
    if (_silentRollover && !hadError) {
      _silentRollover = false;
      _reconnectTimer = Timer(const Duration(milliseconds: 400), () {
        if (mounted && !_isAppPaused && _status != 'RESOLVED') _openSseStream();
      });
      return;
    }

    _sseFailureCount += 1;
    if (_isSseLive) setState(() => _isSseLive = false);
    final delaySec = _reconnectBackoffSec[
        math.min(_sseFailureCount - 1, _reconnectBackoffSec.length - 1)];
    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      if (!mounted || _isAppPaused || _status == 'RESOLVED') return;
      if (_sseFailureCount >= 2) {
        await _fetchMessages(afterSeq: _latestSeq);
        if (!mounted || _isAppPaused || _status == 'RESOLVED') return;
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

  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _textCtrl.text).trim();
    if (text.isEmpty || _isSending || _isStartingNewSession) return;

    // If current thread was already resolved or expired, seamlessly archive it and open a fresh session first.
    if (_status == 'RESOLVED' || _threadId == null || _threadId!.isEmpty) {
      final started = await _continueToNewSession(preserveCurrent: true);
      if (!started || !mounted) return;
    }

    final tid = _threadId;
    if (tid == null || tid.isEmpty) return;

    setState(() => _isSending = true);
    if (preset == null) _textCtrl.clear();

    final clientMsgId =
        'sup_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(9999)}';
    var res = await ApiService().sendSupportMessage(
      threadId: tid,
      text: text,
      clientMsgId: clientMsgId,
    );

    if (!mounted) return;

    // Fallback: if backend reports 409 THREAD_SESSION_ENDED due to a race, auto-start new session and retry once.
    if (res['success'] != true &&
        (res['error']?.toString() == 'THREAD_SESSION_ENDED' || res['statusCode'] == 409)) {
      setState(() => _isSending = false);
      final started = await _continueToNewSession(preserveCurrent: true);
      if (!started || !mounted || _threadId == null) {
        if (preset == null && _textCtrl.text.isEmpty) _textCtrl.text = text;
        return;
      }
      setState(() => _isSending = true);
      res = await ApiService().sendSupportMessage(
        threadId: _threadId!,
        text: text,
        clientMsgId: clientMsgId,
      );
      if (!mounted) return;
    }

    setState(() => _isSending = false);

    if (res['success'] == true && res['message'] is Map) {
      final msg = Map<String, dynamic>.from(res['message'] as Map);
      setState(() {
        _status = res['thread']?['status']?.toString().toUpperCase() ?? 'OPEN';
        _mergeMessages([msg]);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else {
      if (preset == null && _textCtrl.text.isEmpty) _textCtrl.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message']?.toString() ?? 'Could not send message'),
          backgroundColor: const Color(0xFFDC2626),
        ),
      );
    }
  }

  String _formatTime(dynamic rawIso) {
    final raw = rawIso?.toString() ?? '';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '';
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $ampm';
  }

  Widget _buildSessionBreakDivider({
    required bool isExpired,
    required bool resumedNewSession,
    String? previousThreadId,
    String? newThreadId,
  }) {
    final title = resumedNewSession
        ? (isExpired
            ? 'Session expired • New session has been started'
            : 'Session ended • New session has been started')
        : (isExpired
            ? 'Session expired due to inactivity'
            : 'Session ended • Ticket marked resolved');
    final subtitle = resumedNewSession && newThreadId != null && newThreadId.isNotEmpty
        ? 'Continuing seamlessly in $newThreadId'
        : (previousThreadId != null && previousThreadId.isNotEmpty
            ? 'Ticket $previousThreadId closed'
            : 'Tap Continue to New Chat below to resume');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: const Color(0xFFCBD5E1)),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            decoration: BoxDecoration(
              color: isExpired
                  ? const Color(0xFFFFFBEB)
                  : const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isExpired
                    ? const Color(0xFFFCD34D)
                    : const Color(0xFF86EFAC),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isExpired
                          ? Icons.schedule_rounded
                          : (resumedNewSession
                              ? Icons.mark_chat_read_rounded
                              : Icons.check_circle_rounded),
                      size: 13,
                      color: isExpired
                          ? const Color(0xFFB45309)
                          : const Color(0xFF15803D),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: isExpired
                              ? const Color(0xFF92400E)
                              : const Color(0xFF166534),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(height: 1, color: const Color(0xFFCBD5E1)),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg, {bool isArchived = false}) {
    final role = (msg['sender_role'] ?? '').toString().toUpperCase();
    final isMe = role == 'CUSTOMER';
    final seq = (msg['seq'] as num?)?.toInt() ?? 0;
    final isSeen = !isArchived && isMe && seq > 0 && _peerSeenSeq >= seq;
    final senderLabel = isMe
        ? 'You'
        : (role == 'SUPER_ADMIN' ? 'ROParts HQ Support' : 'Zone Manager');

    return Opacity(
      opacity: isArchived ? 0.84 : 1.0,
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: isMe
                ? (isArchived ? const Color(0xFFEFF6FF) : AppTheme.primaryLight)
                : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isMe ? 14 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 14),
            ),
            border: Border.all(
              color: isMe ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A0F172A),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(
                senderLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: isMe
                      ? AppTheme.appleBlue
                      : (role == 'SUPER_ADMIN'
                          ? const Color(0xFF0284C7)
                          : const Color(0xFF16A34A)),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                msg['text']?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.textPrimary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(msg['created_at']),
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe ? const Color(0xFF475569) : const Color(0xFF64748B),
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      (isArchived || isSeen) ? Icons.done_all_rounded : Icons.done_rounded,
                      size: 13,
                      color: (isArchived || isSeen)
                          ? AppTheme.appleBlue
                          : const Color(0xFF64748B),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTimelineEntries() {
    final entries = <Widget>[];
    for (int i = 0; i < _historySegments.length; i++) {
      final seg = _historySegments[i];
      for (final m in seg.messages) {
        entries.add(_buildMessageBubble(m, isArchived: true));
      }
      final isLastArchive = i == _historySegments.length - 1;
      final nextTid = isLastArchive ? _threadId : _historySegments[i + 1].threadId;
      entries.add(_buildSessionBreakDivider(
        isExpired: seg.isAutoExpired,
        resumedNewSession: _showSessionStartedNotice || !isLastArchive || _status != 'RESOLVED',
        previousThreadId: seg.threadId,
        newThreadId: nextTid,
      ));
    }

    if (_historySegments.isNotEmpty &&
        _messages.isEmpty &&
        _status != 'RESOLVED') {
      entries.add(
        Container(
          margin: const EdgeInsets.only(top: 4, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.support_agent_rounded,
                size: 18,
                color: AppTheme.appleBlue,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tap a quick topic below or send a message to resume with $_zoneName.',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    for (final m in _messages) {
      entries.add(_buildMessageBubble(m, isArchived: false));
    }

    if (_status == 'RESOLVED') {
      entries.add(_buildSessionBreakDivider(
        isExpired: (_resolvedBy ?? '').toUpperCase() == 'AUTO_SESSION_TIMEOUT',
        resumedNewSession: false,
        previousThreadId: _threadId,
      ));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final sysNavBottom = MediaQuery.viewPaddingOf(context).bottom;
    // Push composer above Android 3-button nav bar without leaving a gap when keyboard opens.
    final navClearance = math.max(0.0, sysNavBottom - bottomInset);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = math.max(
      320.0,
      screenHeight - MediaQuery.viewPaddingOf(context).top - 12,
    );
    final height = math.min(
      screenHeight * 0.80 + bottomInset + navClearance,
      maxHeight,
    );
    final timelineWidgets = _buildTimelineEntries();
    final isCurrentResolved = _status == 'RESOLVED';
    final isCurrentExpired =
        (_resolvedBy ?? '').toUpperCase() == 'AUTO_SESSION_TIMEOUT';

    return Container(
      height: height,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: AppTheme.cardSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Top Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 12),
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
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _isOutOfZone
                            ? const Color(0xFFE0F2FE)
                            : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.support_agent_rounded,
                        color: _isOutOfZone
                            ? const Color(0xFF0284C7)
                            : const Color(0xFF16A34A),
                        size: 22,
                      ),
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
                                  _zoneName,
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
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isCurrentResolved
                                      ? (isCurrentExpired
                                          ? const Color(0xFFFEF3C7)
                                          : const Color(0xFFE2E8F0))
                                      : (_isSseLive
                                          ? const Color(0xFFDCFCE7)
                                          : const Color(0xFFFEF3C7)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  isCurrentResolved
                                      ? (isCurrentExpired ? 'Expired' : 'Resolved')
                                      : (_isSseLive ? 'Live' : 'Syncing'),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: isCurrentResolved
                                        ? (isCurrentExpired
                                            ? const Color(0xFFB45309)
                                            : const Color(0xFF475569))
                                        : (_isSseLive
                                            ? const Color(0xFF15803D)
                                            : const Color(0xFFB45309)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (_threadId != null && _threadId!.isNotEmpty) _threadId!,
                              if (widget.visitId != null && widget.visitId!.isNotEmpty)
                                'Visit ${widget.visitId}',
                              if (widget.orderId != null && widget.orderId!.isNotEmpty)
                                'Order ${widget.orderId}',
                              _isOutOfZone ? 'Direct HQ Desk' : 'Zone Manager',
                            ].join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Color(0xFF475569)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (isCurrentResolved)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: isCurrentExpired
                    ? const Color(0xFFFFFBEB)
                    : const Color(0xFFECFDF5),
                border: const Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  Icon(
                    isCurrentExpired
                        ? Icons.schedule_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: isCurrentExpired
                        ? const Color(0xFFB45309)
                        : const Color(0xFF15803D),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isCurrentExpired
                          ? 'Session expired due to inactivity. Continue to start a new chat.'
                          : 'Session ended (Ticket resolved). Tap Continue to resume in a new chat.',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isCurrentExpired
                            ? const Color(0xFF92400E)
                            : const Color(0xFF166534),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isStartingNewSession
                        ? null
                        : () => _continueToNewSession(preserveCurrent: true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.appleBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      _isStartingNewSession ? 'Starting...' : 'Continue to New Chat',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            )
          else if (_showSessionStartedNotice)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: const Color(0xFFEFF6FF),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, size: 14, color: AppTheme.appleBlue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'New chat session started (${_threadId ?? 'Active'}) — send a message below to resume.',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1E40AF),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Message List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorNotice != null && timelineWidgets.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.wifi_off_rounded, size: 32, color: Color(0xFF94A3B8)),
                              const SizedBox(height: 10),
                              Text(
                                _errorNotice!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: () => _initThreadAndMessages(),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : timelineWidgets.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  size: 38,
                                  color: const Color(0xFF0284C7).withValues(alpha: 0.65),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Connected to $_zoneName',
                                  style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Tap a quick escalation topic below or write your message directly to your Zone Manager.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF64748B),
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            children: timelineWidgets,
                          ),
          ),

          // Quick Topic Chips
          if (_messages.length < 3)
            Container(
              height: 46,
              color: Colors.white,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: _prompts.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, idx) {
                  final prompt = _prompts[idx];
                  return ActionChip(
                    label: Text(
                      prompt,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0369A1),
                      ),
                    ),
                    backgroundColor: AppTheme.primarySurface,
                    side: const BorderSide(color: Color(0xFFBAE6FD)),
                    onPressed: (_isSending || _isStartingNewSession)
                        ? null
                        : () => _sendMessage(prompt),
                  );
                },
              ),
            ),

          // Input Bar
          Container(
            key: const ValueKey('zone_support_input_bar'),
            padding: EdgeInsets.fromLTRB(12, 8, 12, 14 + navClearance),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    maxLength: 500,
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: isCurrentResolved
                          ? 'Type to start a new chat & resume...'
                          : (_isOutOfZone
                              ? 'Write to ROParts HQ Support...'
                              : 'Write to Zone Manager...'),
                      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                      filled: true,
                      fillColor: AppTheme.cardSurface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: AppTheme.appleBlue, width: 1.4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: (_isSending || _isStartingNewSession)
                        ? AppTheme.appleBlue.withValues(alpha: 0.6)
                        : AppTheme.appleBlue,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: (_isSending || _isStartingNewSession)
                        ? null
                        : () => _sendMessage(),
                    icon: (_isSending || _isStartingNewSession)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, color: Colors.white, size: 19),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
