// Rune-safe and UTF-16-safe text truncation helpers that never split
// surrogate pairs.

/// Truncates [text] to at most [maxRunes] Unicode scalar values, appending
/// [suffix] only when truncation occurs.
String truncateRunes(String text, int maxRunes, {String suffix = ''}) {
  if (maxRunes <= 0) {
    return text.isEmpty ? '' : suffix;
  }
  if (text.length <= maxRunes) {
    return text;
  }
  final runes = text.runes;
  if (runes.length <= maxRunes) {
    return text;
  }
  final prefix = String.fromCharCodes(runes.take(maxRunes));
  return suffix.isEmpty ? prefix : '$prefix$suffix';
}

/// Truncates [text] to at most [maxCodeUnits] UTF-16 code units without
/// leaving an unpaired leading surrogate at the end of the result.
String truncateUtf16Safe(String text, int maxCodeUnits, {String suffix = ''}) {
  if (maxCodeUnits <= 0) {
    return text.isEmpty ? '' : suffix;
  }
  if (text.length <= maxCodeUnits) {
    return text;
  }
  var end = maxCodeUnits;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    end -= 1;
  }
  final prefix = text.substring(0, end);
  return suffix.isEmpty ? prefix : '$prefix$suffix';
}
