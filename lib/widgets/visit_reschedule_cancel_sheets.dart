const List<String> _kMonthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _kWeekdaysShort = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

DateTime currentIstNow() => DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));

String formatIstDateStr(DateTime istDate) {
  final y = istDate.year.toString().padLeft(4, '0');
  final m = istDate.month.toString().padLeft(2, '0');
  final d = istDate.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String formatFriendlyIstDateLabel(String? isoDate) {
  final clean = isoDate?.trim() ?? '';
  if (clean.isEmpty) return 'Today';
  final now = currentIstNow();
  final today = formatIstDateStr(now);
  final tomorrow = formatIstDateStr(now.add(const Duration(days: 1)));
  if (clean == today) return 'Today ($clean)';
  if (clean == tomorrow) return 'Tomorrow ($clean)';
  final parsed = DateTime.tryParse(clean);
  if (parsed == null) return clean;
  final wd = _kWeekdaysShort[parsed.weekday - 1];
  final mon = _kMonthsShort[parsed.month - 1];
  return '$wd, ${parsed.day} $mon';
}

/// Formats the confirmed slot label without duplicating "Today," / "Tomorrow," when date is shown.
String formatConfirmedSlotSummary(String? isoDate, String? rawSlot) {
  final dateLabel = formatFriendlyIstDateLabel(isoDate);
  final cleanedSlot = (rawSlot ?? '')
      .trim()
      .replaceFirst(RegExp(r'^(Today|Tomorrow),\s*', caseSensitive: false), '');
  if (cleanedSlot.isEmpty) return dateLabel;
  return '$dateLabel • $cleanedSlot';
}
