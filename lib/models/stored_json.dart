import 'dart:convert';

Object? decodeStoredJson(String text) {
  try {
    return _decodeStoredJson(text);
  } on FormatException {
    // Never include persisted private content in migration diagnostics.
    throw const FormatException('Invalid stored JSON');
  }
}

/// Limits nesting before decoding and rejects duplicate keys rather than
/// silently letting the JSON decoder overwrite a previous value.
Object? _decodeStoredJson(String text) {
  final containers = <Set<String>?>[];
  for (var index = 0; index < text.length; index++) {
    final character = text.codeUnitAt(index);
    if (character == 34) {
      final start = index++;
      while (index < text.length && text.codeUnitAt(index) != 34) {
        if (text.codeUnitAt(index) == 92) {
          index++;
        }
        index++;
      }
      if (index == text.length) {
        throw const FormatException('Invalid stored JSON');
      }
      var next = index + 1;
      while (next < text.length && ' \r\n\t'.contains(text[next])) {
        next++;
      }
      if (next < text.length && text[next] == ':') {
        if (containers.isEmpty || containers.last == null) {
          throw const FormatException('Invalid stored JSON');
        }
        final key = jsonDecode(text.substring(start, index + 1)) as String;
        if (!containers.last!.add(key)) {
          throw const FormatException('Invalid stored JSON');
        }
      }
    } else if (character == 123 || character == 91) {
      containers.add(character == 123 ? <String>{} : null);
      if (containers.length > 64) {
        throw const FormatException('Invalid stored JSON');
      }
    } else if (character == 125 || character == 93) {
      if (containers.isEmpty) {
        throw const FormatException('Invalid stored JSON');
      }
      containers.removeLast();
    }
  }
  return jsonDecode(text);
}
