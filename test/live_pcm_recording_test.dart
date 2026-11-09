import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:dont_forget/services/live_pcm_recording.dart';
import 'package:dont_forget/services/pcm_wave_reader.dart';
import 'package:dont_forget/services/speech_recognition_service.dart';

class PcmRecorder implements AudioRecorder {
  final audio = StreamController<Uint8List>.broadcast(sync: true);
  RecordConfig? config;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    this.config = config;
    return audio.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late PcmRecorder recorder;
  late LivePcmRecording capture;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('live-pcm-');
    recorder = PcmRecorder();
    capture = await LivePcmRecording.start(recorder, '${root.path}/voice.wav');
  });
  tearDown(() async {
    await recorder.audio.close();
    try {
      await capture.finish();
    } catch (_) {}
    await root.delete(recursive: true);
  });
  test(
    'local capture feeds earlier and future PCM without RIFF bytes',
    () async {
      expect(recorder.config?.encoder, AudioEncoder.pcm16bits);
      expect(recorder.config?.sampleRate, 16000);
      expect(recorder.config?.numChannels, 1);
      recorder.audio.add(Uint8List.fromList(List.filled(3200, 7)));
      final token = CancelToken();
      final iterator = StreamIterator(capture.pcm(token));
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, everyElement(7));
      recorder.audio.add(Uint8List.fromList(List.filled(3200, 9)));
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, everyElement(9));
      await recorder.audio.close();
      await capture.finish();
      expect(await iterator.moveNext(), isFalse);
      final info = await PcmWaveInfo.read(capture.file.path);
      expect(info?.bytes, 6400);
      expect(info?.duration, const Duration(milliseconds: 200));
      expect((await capture.file.readAsBytes()).sublist(44), [
        ...List.filled(3200, 7),
        ...List.filled(3200, 9),
      ]);
    },
  );
  test(
    'cancel recognition while waiting for audio leaves local capture usable',
    () async {
      final token = CancelToken();
      final next = capture.pcm(token).first;
      final assertion = expectLater(
        next,
        throwsA(
          isA<SpeechRecognitionException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      token.cancel();
      await assertion;
      recorder.audio.add(Uint8List(16000));
      await recorder.audio.close();
      await capture.finish();
      expect((await PcmWaveInfo.read(capture.file.path))?.bytes, 16000);
    },
  );
  test('discard deletes only its own capture and is repeatable', () async {
    final other = await File('${root.path}/other.wav').writeAsString('keep');
    await recorder.audio.close();
    await capture.discard();
    await capture.discard();
    expect(await capture.file.exists(), isFalse);
    expect(await other.readAsString(), 'keep');
  });
  test('existing target is never overwritten', () async {
    final other = await File('${root.path}/other.wav').writeAsString('keep');
    await expectLater(
      LivePcmRecording.start(recorder, other.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await other.readAsString(), 'keep');
  });
  test('invalid PCM chunk fails safely and can still be cancelled', () async {
    recorder.audio.add(Uint8List(3));
    await recorder.audio.close();
    await expectLater(capture.finish(), throwsA(isA<FileSystemException>()));
    await capture.discard();
    expect(await capture.file.exists(), isFalse);
  });
}
