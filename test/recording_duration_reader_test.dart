import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/services/recording_duration_reader.dart';
import 'support/adts_metadata_fixture.dart';
import 'support/m4a_metadata_fixture.dart';

void main() {
  const reader = RecordingDurationReader();
  late Directory directory;
  late File capture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capture-metadata-');
    capture = File('${directory.path}/capture.m4a');
  });
  tearDown(() => directory.delete(recursive: true));

  group('MP4 / M4A metadata parsing', () {
    test('reads v0, v1, extended and to-end movie metadata', () async {
      for (final bytes in [
        m4aMetadata(ticks: 44101, scale: 44100),
        m4aMetadata(ticks: 44101, scale: 44100, version: 1),
        m4aMetadata(ticks: 44101, scale: 44100, extended: true),
        m4aMetadata(ticks: 44101, scale: 44100, movieToEnd: true),
      ]) {
        await capture.writeAsBytes(bytes);
        expect(
          await reader.read(capture.path),
          const Duration(microseconds: 1000022),
        );
      }
    });

    test('distinguishes short native capture from a usable duration', () async {
      for (final millis in [0, 22, 249, 250, 5000]) {
        await capture.writeAsBytes(m4aMetadata(ticks: millis));
        final duration = await reader.read(capture.path);
        expect(duration, Duration(milliseconds: millis));
        expect(duration! < RecordingDurationReader.minimumCapture, millis < 250);
      }
    });

    test('skips a large audio body before movie metadata', () async {
      const size = 64 * 1024 * 1024;
      final file = await capture.open(mode: FileMode.write);
      final header = ByteData(8)..setUint32(0, size);
      header.buffer.asUint8List().setRange(4, 8, 'mdat'.codeUnits);
      await file.writeFrom(header.buffer.asUint8List());
      await file.setPosition(size);
      await file.writeFrom(m4aMetadata());
      await file.close();
      expect(await reader.read(capture.path), const Duration(seconds: 2));
    });

    test(
      'unknown, missing, truncated and malformed metadata stays unknown',
      () async {
        expect(await reader.read(capture.path), isNull);
        final invalidSize = m4aMetadata();
        ByteData.sublistView(invalidSize).setUint32(0, invalidSize.length + 1);
        for (final bytes in [
          <int>[],
          [1, 5, 1, 2],
          m4aMetadata().sublist(0, 17),
          invalidSize,
          metadataAtom('moov', [0, 0, 0, 4, ...'mvhd'.codeUnits]),
          m4aMetadata(scale: 0),
          m4aMetadata(version: 2),
          m4aMetadata(ticks: 0xffffffff),
          m4aMetadata(ticks: -1, version: 1),
          metadataAtom('moov', metadataAtom('mvhd', [1, ...List.filled(19, 0)])),
        ]) {
          await capture.writeAsBytes(bytes);
          expect(await reader.read(capture.path), isNull);
        }
      },
    );

    test('bounds atom work instead of scanning arbitrary payloads', () async {
      final bytes = BytesBuilder();
      for (var i = 0; i < 256; i++) {
        bytes.add(metadataAtom('free', []));
      }
      bytes.add(m4aMetadata());
      await capture.writeAsBytes(bytes.takeBytes());
      expect(await reader.read(capture.path), isNull);
    });
  });

  group('ADTS AAC stream metadata parsing', () {
    test('reads valid single and multi-frame ADTS streams across sample rates', () async {
      // 1 frame at 44.1kHz = 1024 / 44100 s ~ 23219 us
      final aacFile = File('${directory.path}/capture.aac');
      await aacFile.writeAsBytes(adtsStream(frameCount: 1, sampleRate: 44100));
      final d1 = await reader.read(aacFile.path);
      expect(d1, const Duration(microseconds: 23219));

      // 1 frame at 48kHz = 1024 / 48000 s ~ 21333 us
      await aacFile.writeAsBytes(adtsStream(frameCount: 1, sampleRate: 48000));
      final d2 = await reader.read(aacFile.path);
      expect(d2, const Duration(microseconds: 21333));

      // With CRC (protection absent = false)
      await aacFile.writeAsBytes(
        adtsStream(frameCount: 1, sampleRate: 44100, protectionAbsent: false),
      );
      final d3 = await reader.read(aacFile.path);
      expect(d3, const Duration(microseconds: 23219));
    });

    test('distinguishes short ADTS capture (< 250ms) from usable capture', () async {
      final aacFile = File('${directory.path}/audio.aac');

      // 1 frame ~ 23ms < 250ms
      await aacFile.writeAsBytes(adtsStream(frameCount: 1, sampleRate: 44100));
      var d = await reader.read(aacFile.path);
      expect(d! < RecordingDurationReader.minimumCapture, isTrue);

      // 5 frames ~ 116ms < 250ms
      await aacFile.writeAsBytes(adtsStream(frameCount: 5, sampleRate: 44100));
      d = await reader.read(aacFile.path);
      expect(d! < RecordingDurationReader.minimumCapture, isTrue);

      // 10 frames ~ 232ms < 250ms (boundary reject)
      await aacFile.writeAsBytes(adtsStream(frameCount: 10, sampleRate: 44100));
      d = await reader.read(aacFile.path);
      expect(d! < RecordingDurationReader.minimumCapture, isTrue);

      // 11 frames ~ 255ms >= 250ms (boundary accept)
      await aacFile.writeAsBytes(adtsStream(frameCount: 11, sampleRate: 44100));
      d = await reader.read(aacFile.path);
      expect(d! >= RecordingDurationReader.minimumCapture, isTrue);

      // 130 frames ~ 3.018s (typical 3-second recording)
      await aacFile.writeAsBytes(adtsStream(frameCount: 130, sampleRate: 44100));
      d = await reader.read(aacFile.path);
      expect(d! >= RecordingDurationReader.minimumCapture, isTrue);
      expect(d.inMilliseconds, inInclusiveRange(3015, 3025));
    });

    test('malformed, truncated and invalid ADTS streams return null safely', () async {
      final aacFile = File('${directory.path}/corrupt.aac');

      // Empty file
      await aacFile.writeAsBytes([]);
      expect(await reader.read(aacFile.path), isNull);

      // Truncated header (< 7 bytes)
      await aacFile.writeAsBytes([0xff, 0xf1, 0x50]);
      expect(await reader.read(aacFile.path), isNull);

      // Bad syncword
      final badSync = adtsFrame();
      badSync[0] = 0xfe;
      await aacFile.writeAsBytes(badSync);
      expect(await reader.read(aacFile.path), isNull);

      // Bad layer (must be 00)
      final badLayer = adtsFrame();
      badLayer[1] = badLayer[1] | 0x02;
      await aacFile.writeAsBytes(badLayer);
      expect(await reader.read(aacFile.path), isNull);

      // Invalid sample rate index (index 15)
      final badSr = adtsFrame();
      badSr[2] = (badSr[2] & ~0x3c) | (15 << 2);
      await aacFile.writeAsBytes(badSr);
      expect(await reader.read(aacFile.path), isNull);

      // Frame length smaller than header (frameLength = 5)
      final badLen = adtsFrame();
      badLen[3] = (badLen[3] & ~0x03);
      badLen[4] = 0;
      badLen[5] = (badLen[5] & ~0xe0) | (5 << 5);
      await aacFile.writeAsBytes(badLen);
      expect(await reader.read(aacFile.path), isNull);
    });

    test('partial stream with valid prefix returns duration of valid frames', () async {
      final aacFile = File('${directory.path}/partial.aac');
      final valid5Frames = adtsStream(frameCount: 5, sampleRate: 44100);
      // Append incomplete/corrupted trailing bytes
      final combined = [...valid5Frames, 0xff, 0xf1, 0x50];
      await aacFile.writeAsBytes(combined);

      final d = await reader.read(aacFile.path);
      expect(d, isNotNull);
      // Duration of the 5 valid frames: 5 * 1024 / 44100 ~ 116099 us
      expect(d!.inMicroseconds, 116099);
    });

    test('historical .m4a extension with ADTS content is parsed correctly', () async {
      // Test backward compatibility: Windows previously wrote ADTS to .m4a files
      final historicalFile = File('${directory.path}/legacy_recording.m4a');
      await historicalFile.writeAsBytes(adtsStream(frameCount: 130, sampleRate: 44100));

      final duration = await reader.read(historicalFile.path);
      expect(duration, isNotNull);
      expect(duration!.inMilliseconds, inInclusiveRange(3015, 3025));
    });
  });

  group('Platform recording extension mapping', () {
    test('maps Windows to .aac and other platforms to .m4a', () {
      expect(
        HomeController.recordingExtensionForPlatform(TargetPlatform.windows),
        'aac',
      );
      expect(
        HomeController.recordingExtensionForPlatform(TargetPlatform.iOS),
        'm4a',
      );
      expect(
        HomeController.recordingExtensionForPlatform(TargetPlatform.android),
        'm4a',
      );
      expect(
        HomeController.recordingExtensionForPlatform(TargetPlatform.macOS),
        'm4a',
      );
      expect(
        HomeController.recordingExtensionForPlatform(TargetPlatform.linux),
        'm4a',
      );
    });
  });
}
