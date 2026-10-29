import 'dart:typed_data';
import 'package:dont_forget/services/recording_duration_reader.dart';

/// Constructs a single synthetic ADTS frame with valid headers.
Uint8List adtsFrame({
  int sampleRate = 44100,
  int channelCount = 2,
  int payloadLength = 200,
  int numBlocks = 1,
  bool protectionAbsent = true,
}) {
  final srIndex = RecordingDurationReader.adtsSampleRates.indexOf(sampleRate);
  if (srIndex == -1) {
    throw ArgumentError('Unsupported sample rate: $sampleRate');
  }

  final headerLength = protectionAbsent ? 7 : 9;
  final frameLength = headerLength + payloadLength;

  const b0 = 0xff;
  final b1 = 0xf0 | (1 << 3) | (protectionAbsent ? 1 : 0);
  final b2 = (1 << 6) | ((srIndex & 0x0f) << 2) | ((channelCount >> 2) & 0x01);
  final b3 = ((channelCount & 0x03) << 6) | ((frameLength >> 11) & 0x03);
  final b4 = (frameLength >> 3) & 0xff;
  final b5 = ((frameLength & 0x07) << 5) | 0x1f;
  final b6 = 0xfc | ((numBlocks - 1) & 0x03);

  final bytes = Uint8List(frameLength);
  bytes[0] = b0;
  bytes[1] = b1;
  bytes[2] = b2;
  bytes[3] = b3;
  bytes[4] = b4;
  bytes[5] = b5;
  bytes[6] = b6;
  if (!protectionAbsent) {
    bytes[7] = 0x00;
    bytes[8] = 0x00;
  }
  return bytes;
}

/// Constructs a stream of synthetic ADTS frames.
Uint8List adtsStream({
  int frameCount = 1,
  int sampleRate = 44100,
  int channelCount = 2,
  int payloadLength = 200,
  int numBlocks = 1,
  bool protectionAbsent = true,
}) {
  final builder = BytesBuilder();
  for (var i = 0; i < frameCount; i++) {
    builder.add(
      adtsFrame(
        sampleRate: sampleRate,
        channelCount: channelCount,
        payloadLength: payloadLength,
        numBlocks: numBlocks,
        protectionAbsent: protectionAbsent,
      ),
    );
  }
  return builder.takeBytes();
}
