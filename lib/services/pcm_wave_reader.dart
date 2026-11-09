import 'dart:io';
import 'dart:typed_data';

/// Bounded RIFF parser for finalized PCM WAV recordings. Does not load audio.
class PcmWaveInfo {
  const PcmWaveInfo(this.offset, this.bytes, this.sampleRate, this.channels);
  final int offset, bytes, sampleRate, channels;
  int get bytesPerSecond => sampleRate * channels * 2;
  Duration get duration => Duration(
    microseconds: bytes * Duration.microsecondsPerSecond ~/ bytesPerSecond,
  );

  static Future<PcmWaveInfo?> read(String path) async {
    final file = await File(path).open();
    try {
      final length = await file.length();
      final header = await file.read(12);
      if (header.length != 12 ||
          String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
        return null;
      }
      final end = ByteData.sublistView(header).getUint32(4, Endian.little) + 8;
      if (end != length) return null;
      int? rate, channels, dataOffset, dataBytes;
      var offset = 12;
      var chunks = 0;
      while (offset + 8 <= end && chunks++ < 128) {
        await file.setPosition(offset);
        final chunk = await file.read(8);
        if (chunk.length != 8) return null;
        final type = String.fromCharCodes(chunk.sublist(0, 4));
        final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
        final body = offset + 8;
        if (body + size > end) return null;
        if (type == 'fmt ') {
          if (rate != null || size < 16) return null;
          final fmt = await file.read(size >= 40 ? 40 : 16);
          if (fmt.length < 16) return null;
          final fields = ByteData.sublistView(fmt);
          channels = fields.getUint16(2, Endian.little);
          rate = fields.getUint32(4, Endian.little);
          final tag = fields.getUint16(0, Endian.little);
          final extensiblePcm =
              tag == 0xfffe &&
              size >= 40 &&
              fmt.length >= 40 &&
              fields.getUint16(16, Endian.little) >= 22 &&
              fields.getUint16(18, Endian.little) == 16 &&
              fmt.sublist(24, 40).join(',') ==
                  '1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113';
          if ((tag != 1 && !extensiblePcm) ||
              !const [1, 2].contains(channels) ||
              rate < 8000 ||
              rate > 192000 ||
              fields.getUint16(14, Endian.little) != 16 ||
              fields.getUint16(12, Endian.little) != channels * 2 ||
              fields.getUint32(8, Endian.little) != rate * channels * 2) {
            return null;
          }
        } else if (type == 'data') {
          if (dataOffset != null) return null;
          dataOffset = body;
          dataBytes = size;
        }
        offset = body + size + (size.isOdd ? 1 : 0);
      }
      if (offset != end ||
          rate == null ||
          channels == null ||
          dataOffset == null ||
          dataBytes == null ||
          dataBytes <= 0 ||
          dataBytes % (channels * 2) != 0) {
        return null;
      }
      return PcmWaveInfo(dataOffset, dataBytes, rate, channels);
    } finally {
      await file.close();
    }
  }
}
