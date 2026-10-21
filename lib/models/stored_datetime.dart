/// The persisted timestamp grammar shared by model decoding and backup
/// validation. Invalid calendar fields must not silently overflow in Dart.
final _storedIsoDate = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:[Zz]|[+-](\d{2}):?(\d{2}))?$',
);

DateTime? tryParseStoredDateTime(Object? value) {
  if (value is! String) return null;
  final match = _storedIsoDate.firstMatch(value);
  if (match == null) return null;
  int part(int index) => int.parse(match.group(index)!);
  final year = part(1), month = part(2), day = part(3);
  if (year < 1 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      part(4) > 23 ||
      part(5) > 59 ||
      part(6) > 59 ||
      (match.group(7) != null && (part(7) > 23 || part(8) > 59))) {
    return null;
  }
  // Keep the historical t/z and nanosecond input forms. Dart truncates
  // fractional precision beyond microseconds consistently for every consumer.
  return DateTime.tryParse(value.replaceAll('t', 'T').replaceAll('z', 'Z'));
}

DateTime parseStoredDateTime(Object? value) {
  final parsed = tryParseStoredDateTime(value);
  if (parsed == null) throw const FormatException('Invalid stored date');
  return parsed;
}
