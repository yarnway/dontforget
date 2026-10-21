import 'package:intl/intl.dart';

/// Render an instant in the device timezone without changing its stored value.
String formatLocalDateTime(
  DateTime value, {
  String pattern = 'yyyy-MM-dd HH:mm',
}) => DateFormat(pattern).format(value.toLocal());
