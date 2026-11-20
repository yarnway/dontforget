/// Human-readable IEC binary byte size formatting shared across content,
/// backup, and attachment views.
String formatByteSize(int bytes, {int fractionDigits = 2}) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(fractionDigits)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(fractionDigits)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(fractionDigits)} GiB';
}
