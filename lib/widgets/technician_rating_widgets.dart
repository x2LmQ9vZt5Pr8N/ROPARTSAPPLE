import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/display_sanitizer.dart';

typedef SubmitVisitRatingCallback = Future<Map<String, dynamic>> Function({
  required int rating,
  required List<String> tags,
  String? reviewText,
});

typedef FetchTechnicianReviewsCallback = Future<Map<String, dynamic>> Function(
  String technicianId,
);

/// Compact, overflow-safe inline rating + completed-jobs display under a technician's name.
class TechnicianRatingBadgeRow extends StatelessWidget {
  final double? rating;
  final int ratingCount;
  final int? completedJobs;
  final VoidCallback? onTap;
  final bool showViewReviewsHint;

  const TechnicianRatingBadgeRow({
    super.key,
    required this.rating,
    this.ratingCount = 0,
    this.completedJobs,
    this.onTap,
    this.showViewReviewsHint = false,
  });

  @override
  Widget build(BuildContext context) {
    final jobsCount = completedJobs ?? 0;
    final hasRating = rating != null && rating! > 0;
    if (!hasRating && jobsCount <= 0 && completedJobs == null) {
      return const SizedBox.shrink();
    }

    final jobsLabel = jobsCount == 1 ? '1 job done' : '$jobsCount jobs done';
    final content = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 2,
      children: [
        if (hasRating)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded, size: 14, color: Color(0xFFD97706)),
              const SizedBox(width: 2),
              Text(
                ratingCount > 0
                    ? '${rating!.toStringAsFixed(1)} ($ratingCount)'
                    : rating!.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF92400E),
                ),
              ),
            ],
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'New',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF475569),
              ),
            ),
          ),
        Text(
          '• $jobsLabel',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF64748B),
          ),
        ),
        if (showViewReviewsHint && onTap != null && hasRating)
          const Text(
            '• Reviews ›',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0284C7),
            ),
          ),
      ],
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: content,
      ),
    );
  }
}

/// Interactive 5-star + quick tags + optional written review card shown after visit completion.
class TechnicianRateCard extends StatefulWidget {
  final String technicianName;
  final String? technicianBadge;
  final int? initialCustomerRating;
  final String? initialCustomerReview;
  final SubmitVisitRatingCallback onSubmit;
  final VoidCallback? onViewReviews;
  final bool compact;

  const TechnicianRateCard({
    super.key,
    required this.technicianName,
    this.technicianBadge,
    this.initialCustomerRating,
    this.initialCustomerReview,
    required this.onSubmit,
    this.onViewReviews,
    this.compact = false,
  });

  @override
  State<TechnicianRateCard> createState() => _TechnicianRateCardState();
}

class _TechnicianRateCardState extends State<TechnicianRateCard> {
  static const List<String> _quickTags = [
    'On Time',
    'Polite & Neat',
    'Thorough Check',
    'Clear TDS Test',
    'Genuine Spares',
  ];

  static const List<String> _ratingLabels = [
    'Tap a star to rate your technician',
    'Needs Improvement',
    'Fair',
    'Good Service',
    'Very Good!',
    'Excellent Experience!',
  ];

  int _selectedStars = 0;
  final Set<String> _selectedTags = <String>{};
  final TextEditingController _reviewCtrl = TextEditingController();
  bool _submitting = false;
  String? _errorMsg;
  int? _submittedRating;
  String? _submittedReview;

  @override
  void initState() {
    super.initState();
    _submittedRating = widget.initialCustomerRating;
    _submittedReview = widget.initialCustomerReview;
  }

  @override
  void didUpdateWidget(covariant TechnicianRateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCustomerRating != null &&
        widget.initialCustomerRating != _submittedRating) {
      _submittedRating = widget.initialCustomerRating;
    }
    if (widget.initialCustomerReview != null &&
        widget.initialCustomerReview != _submittedReview) {
      _submittedReview = widget.initialCustomerReview;
    }
  }

  @override
  void dispose() {
    _reviewCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (_submitting) return;
    if (_selectedStars < 1 || _selectedStars > 5) {
      setState(() => _errorMsg = 'Please tap 1 to 5 stars before submitting.');
      return;
    }
    setState(() {
      _submitting = true;
      _errorMsg = null;
    });
    final reviewText = _reviewCtrl.text.trim();
    final res = await widget.onSubmit(
      rating: _selectedStars,
      tags: _selectedTags.toList(),
      reviewText: reviewText.isEmpty ? null : reviewText,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      setState(() {
        _submitting = false;
        _submittedRating = (res['customer_rating'] is int)
            ? res['customer_rating'] as int
            : _selectedStars;
        if (reviewText.isNotEmpty) {
          _submittedReview = reviewText;
        }
      });
    } else {
      setState(() {
        _submitting = false;
        _errorMsg = (res['message'] ?? res['error'] ?? 'Could not submit rating. Please retry.').toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_submittedRating != null) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(widget.compact ? 10 : 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF16A34A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Thank you! You rated $_submittedRating/5 ★',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF15803D),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    5,
                    (i) => Icon(
                      i < _submittedRating! ? Icons.star_rounded : Icons.star_outline_rounded,
                      size: 14,
                      color: i < _submittedRating! ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1),
                    ),
                  ),
                ),
              ],
            ),
            if (_submittedReview != null && _submittedReview!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '"${_submittedReview!.trim()}"',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF334155),
                ),
              ),
            ],
            if (widget.onViewReviews != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: widget.onViewReviews,
                child: const Text(
                  'See all customer reviews →',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0284C7),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final displayTech = DisplaySanitizer.technicianName(
      widget.technicianName,
      fallback: 'your technician',
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(widget.compact ? 11 : 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rate & Review $displayTech',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _ratingLabels[_selectedStars.clamp(0, 5)],
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: _selectedStars > 0 ? const Color(0xFFB45309) : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(5, (index) {
              final starValue = index + 1;
              final active = starValue <= _selectedStars;
              return IconButton(
                key: ValueKey('rate_star_$starValue'),
                onPressed: _submitting
                    ? null
                    : () => setState(() {
                          _selectedStars = starValue;
                          _errorMsg = null;
                        }),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  active ? Icons.star_rounded : Icons.star_border_rounded,
                  size: widget.compact ? 28 : 32,
                  color: active ? const Color(0xFFF59E0B) : const Color(0xFF94A3B8),
                ),
              );
            }),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _quickTags.map((tag) {
              final selected = _selectedTags.contains(tag);
              return FilterChip(
                label: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected ? const Color(0xFF92400E) : const Color(0xFF475569),
                  ),
                ),
                selected: selected,
                selectedColor: const Color(0xFFFEF3C7),
                backgroundColor: Colors.white,
                side: BorderSide(
                  color: selected ? const Color(0xFFF59E0B) : const Color(0xFFE2E8F0),
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: _submitting
                    ? null
                    : (val) => setState(() {
                          if (val) {
                            _selectedTags.add(tag);
                          } else {
                            _selectedTags.remove(tag);
                          }
                        }),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reviewCtrl,
            enabled: !_submitting,
            minLines: 2,
            maxLines: 3,
            maxLength: 400,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F172A)),
            decoration: InputDecoration(
              hintText: 'Write an optional review about the doorstep service...',
              hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              counterStyle: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
          ),
          if (_errorMsg != null) ...[
            const SizedBox(height: 4),
            Text(
              _errorMsg!,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB91C1C),
              ),
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submitting ? null : _handleSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'Submit Rating & Review',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a bottom sheet listing real verified customer reviews stored in DynamoDB + SQL summary.
Future<void> showTechnicianReviewsSheet(
  BuildContext context, {
  String? technicianId,
  String? visitId,
  required String technicianName,
  double? initialAvg,
  int initialCount = 0,
  int? initialJobs,
  FetchTechnicianReviewsCallback? loader,
}) {
  final safeName = DisplaySanitizer.technicianName(technicianName);
  final cleanVisitId = visitId?.trim() ?? '';
  final cleanTechId = technicianId?.trim() ?? '';
  final Future<Map<String, dynamic>> future = loader != null
      ? loader(cleanTechId.isNotEmpty ? cleanTechId : cleanVisitId)
      : (cleanVisitId.isNotEmpty
          ? ApiService().getVisitReviews(cleanVisitId)
          : ApiService().getTechnicianReviews(cleanTechId));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFC),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: FutureBuilder<Map<String, dynamic>>(
          future: future,
          builder: (ctx, snap) {
            final data = snap.data;
            final avg = data?['rating_avg'] != null
                ? double.tryParse('${data!['rating_avg']}')
                : initialAvg;
            final count = int.tryParse('${data?['rating_count'] ?? initialCount}') ?? initialCount;
            final jobs = int.tryParse('${data?['completed_jobs_count'] ?? initialJobs ?? 0}') ?? (initialJobs ?? 0);
            final reviewsRaw = (data?['reviews'] is List) ? data!['reviews'] as List : const [];

            return Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              safeName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 4),
                            TechnicianRatingBadgeRow(
                              rating: avg,
                              ratingCount: count,
                              completedJobs: jobs,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
                Expanded(
                  child: snap.connectionState == ConnectionState.waiting
                      ? const Center(child: CircularProgressIndicator())
                      : reviewsRaw.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'No customer reviews written yet. Completed visits appear here once customers leave feedback.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollCtrl,
                              padding: const EdgeInsets.all(16),
                              itemCount: reviewsRaw.length,
                              itemBuilder: (_, idx) {
                                final item = Map<String, dynamic>.from(reviewsRaw[idx] as Map);
                                final stars = int.tryParse('${item['rating'] ?? 5}') ?? 5;
                                final author = (item['author_name'] ?? 'Verified Customer').toString();
                                final text = (item['review_text'] ?? '').toString().trim();
                                final tags = (item['tags'] is List)
                                    ? (item['tags'] as List).map((e) => e.toString()).toList()
                                    : const <String>[];
                                final datePart = (item['created_at'] ?? '').toString().split('T').first;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              author,
                                              style: const TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0F172A),
                                              ),
                                            ),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: List.generate(
                                              5,
                                              (i) => Icon(
                                                i < stars ? Icons.star_rounded : Icons.star_outline_rounded,
                                                size: 14,
                                                color: i < stars ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (datePart.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          datePart,
                                          style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
                                        ),
                                      ],
                                      if (tags.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 5,
                                          runSpacing: 4,
                                          children: tags
                                              .map((t) => Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFFFEF3C7),
                                                      borderRadius: BorderRadius.circular(6),
                                                    ),
                                                    child: Text(
                                                      t,
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        fontWeight: FontWeight.w700,
                                                        color: Color(0xFF92400E),
                                                      ),
                                                    ),
                                                  ))
                                              .toList(),
                                        ),
                                      ],
                                      if (text.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          text,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF334155),
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
