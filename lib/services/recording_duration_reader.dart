import 'dart:io';
import 'dart:typed_data';

/// Reads finalized capture metadata (M4A/MP4 or ADTS AAC) without decoding or loading
/// full audio data. Unknown formats return null and keep the existing import behavior.
/// This is a short-capture guard, not a claim that the microphone recorded audible sound.
class RecordingDurationReader {
  const RecordingDurationReader();

  static const minimumCapture = Duration(milliseconds: 250);

  static const List<int> adtsSampleRates = <int>[
    96000, 88200, 64000, 48000, 44100, 32000,
    24000, 22050, 16000, 12000, 11025, 8000, 7350,
  ];

  Future<Duration?> read(String path) async {
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      final length = await file.length();
      if (length < 7) return null;

      // Check first two bytes for ADTS syncword (0xFFF) and layer == 00
      await file.setPosition(0);
      final initial = await file.read(2);
      if (initial.length == 2 &&
          initial[0] == 0xff &&
          (initial[1] & 0xf6) == 0xf0) {
        return await _readAdts(file, length);
      }

      var remainingAtoms = 256;
      var offset = 0;
      while (offset < length && remainingAtoms-- > 0) {
        final atom = await _atom(file, offset, length);
        if (atom == null) return null;
        if (atom.type == 'moov') {
          var childOffset = atom.body;
          while (childOffset < atom.end && remainingAtoms-- > 0) {
            final child = await _atom(file, childOffset, atom.end);
            if (child == null) return null;
            if (child.type == 'mvhd') {
              return await _movieDuration(file, child);
            }
            childOffset = child.end;
          }
        }
        offset = atom.end;
      }
      return null;
    } on FileSystemException {
      return null;
    } finally {
      await file?.close();
    }
  }

  Future<Duration?> _readAdts(RandomAccessFile file, int fileLength) async {
    var offset = 0;
    var totalSamples = 0;
    var sampleRate = 0;
    var validFrames = 0;
    const maxFramesToScan = 2000;

    while (offset + 7 <= fileLength && validFrames < maxFramesToScan) {
      await file.setPosition(offset);
      final header = await file.read(7);
      if (header.length < 7) break;

      // Verify syncword (0xFFF) and layer == 00
      if (header[0] != 0xff || (header[1] & 0xf6) != 0xf0) {
        if (validFrames == 0) return null;
        break;
      }

      final protectionAbsent = header[1] & 0x01;
      final headerSize = protectionAbsent == 1 ? 7 : 9;

      final srIndex = (header[2] & 0x3c) >> 2;
      if (srIndex >= adtsSampleRates.length) {
        if (validFrames == 0) return null;
        break;
      }

      final currentRate = adtsSampleRates[srIndex];
      if (sampleRate == 0) {
        sampleRate = currentRate;
      }

      final frameLength =
          ((header[3] & 0x03) << 11) |
          (header[4] << 3) |
          ((header[5] & 0xe0) >> 5);
      if (frameLength < headerSize) {
        if (validFrames == 0) return null;
        break;
      }

      final rawBlocks = (header[6] & 0x03) + 1;
      totalSamples += 1024 * rawBlocks;
      validFrames++;
      offset += frameLength;
    }

    if (validFrames == 0 || sampleRate <= 0) return null;

    if (offset >= fileLength || validFrames < maxFramesToScan) {
      final microseconds =
          (totalSamples * Duration.microsecondsPerSecond) ~/ sampleRate;
      return Duration(microseconds: microseconds);
    }

    final avgFrameLength = offset / validFrames;
    if (avgFrameLength <= 0) return null;
    final estimatedTotalFrames = fileLength / avgFrameLength;
    final estimatedSamples = (estimatedTotalFrames * 1024).round();
    final microseconds =
        (estimatedSamples * Duration.microsecondsPerSecond) ~/ sampleRate;
    return Duration(microseconds: microseconds);
  }

  Future<_Atom?> _atom(RandomAccessFile file, int offset, int end) async {
    if (end - offset < 8) return null;
    await file.setPosition(offset);
    final header = await file.read(8);
    if (header.length != 8) return null;
    var size = ByteData.sublistView(header).getUint32(0);
    var headerSize = 8;
    if (size == 1) {
      if (end - offset < 16) return null;
      final extended = await file.read(8);
      if (extended.length != 8) return null;
      size = ByteData.sublistView(extended).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < headerSize || size > end - offset) return null;
    return _Atom(
      String.fromCharCodes(header.sublist(4, 8)),
      offset + headerSize,
      offset + size,
    );
  }

  Future<Duration?> _movieDuration(RandomAccessFile file, _Atom atom) async {
    if (atom.end - atom.body < 20) return null;
    await file.setPosition(atom.body);
    final bytes = await file.read(atom.end - atom.body < 32 ? 20 : 32);
    if (bytes.length < 20) return null;
    final data = ByteData.sublistView(bytes);
    final version = data.getUint8(0);
    if (version != 0 && version != 1) return null;
    if (version == 1 && bytes.length < 32) return null;
    final scale = data.getUint32(version == 0 ? 12 : 20);
    final ticks = version == 0 ? data.getUint32(16) : data.getUint64(24);
    if (scale == 0 || ticks < 0 || ticks == 0xffffffff) return null;
    // Avoid integer overflow for corrupt or unspecified 64-bit durations.
    final seconds = ticks ~/ scale;
    if (seconds > 31536000) return null;
    return Duration(
      microseconds:
          seconds * Duration.microsecondsPerSecond +
          (ticks % scale) * Duration.microsecondsPerSecond ~/ scale,
    );
  }
}

class _Atom {
  const _Atom(this.type, this.body, this.end);
  final String type;
  final int body;
  final int end;
}
