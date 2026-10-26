import 'dart:typed_data';

// Container metadata only, not encoded microphone audio or playback evidence.
Uint8List m4aMetadata({
  int ticks = 2000,
  int scale = 1000,
  int version = 0,
  bool extended = false,
  bool movieToEnd = false,
}) {
  final body = ByteData(version == 1 ? 32 : 20);
  body.setUint8(0, version);
  body.setUint32(version == 1 ? 20 : 12, scale);
  if (version == 1) {
    body.setUint64(24, ticks);
  } else {
    body.setUint32(16, ticks);
  }
  final movie = metadataAtom('mvhd', body.buffer.asUint8List());
  return metadataAtom('moov', movie, extended: extended, toEnd: movieToEnd);
}

Uint8List metadataAtom(
  String type,
  List<int> body, {
  bool extended = false,
  bool toEnd = false,
}) {
  final size = (extended ? 16 : 8) + body.length;
  final bytes = Uint8List(size);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, toEnd ? 0 : (extended ? 1 : size));
  bytes.setRange(4, 8, type.codeUnits);
  if (extended) data.setUint64(8, size);
  bytes.setRange(extended ? 16 : 8, size, body);
  return bytes;
}
