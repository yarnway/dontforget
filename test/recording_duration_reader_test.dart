import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/recording_duration_reader.dart';
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
}
