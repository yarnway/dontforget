import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:record/record.dart';
import 'speech_recognition_exception.dart';

/// Local PCM capture. No network is started here. A later explicit upward
/// gesture may read the same file while recording continues, without a RAM copy.
class LivePcmRecording {
  LivePcmRecording._(this.file, this._output);
  final File file;
  final RandomAccessFile _output;
  StreamSubscription<Uint8List>? _subscription;
  Future<void> _writes = Future.value();
  Completer<void> _changed = Completer<void>();
  int _written = 0, _queued = 0;
  bool _ended = false, _closed = false;
  Object? _failure;
  Future<String>? _finishing;
  final _readers = <Completer<void>>{};

  static Future<LivePcmRecording> start(
    AudioRecorder recorder,
    String path,
  ) async {
    final file = File(path);
    if (await file.exists()) {
      throw const FileSystemException('Capture path occupied');
    }
    final output = await file.open(mode: FileMode.write);
    final capture = LivePcmRecording._(file, output);
    try {
      await output.writeFrom(_header(0));
      final audio = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      capture._subscription = audio.listen(
        capture._add,
        onError: (Object _) {
          capture._failure = const FileSystemException('Capture stream failed');
          capture._notify();
        },
        onDone: capture._notify,
      );
      return capture;
    } catch (_) {
      await output.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  void _notify() {
    final old = _changed;
    _changed = Completer<void>();
    if (!old.isCompleted) old.complete();
  }

  void _add(Uint8List value) {
    if (_closed || _failure != null || value.isEmpty) return;
    if (value.length.isOdd || _queued + value.length > 1024 * 1024) {
      _failure = const FileSystemException('Capture buffer overflow');
      _notify();
      return;
    }
    final bytes = Uint8List.fromList(value);
    _queued += bytes.length;
    _writes = _writes.then((_) async {
      if (_failure != null) return;
      try {
        await _output.writeFrom(bytes);
        _written += bytes.length;
      } catch (_) {
        _failure = const FileSystemException('Capture write failed');
      } finally {
        _queued -= bytes.length;
        _notify();
      }
    });
  }

  Stream<List<int>> pcm(CancelToken cancellation) async* {
    if (cancellation.isCancelled) {
      throw const SpeechRecognitionException('cancelled');
    }
    final closed = Completer<void>();
    _readers.add(closed);
    RandomAccessFile? input;
    var offset = 0;
    try {
      input = await file.open();
      await input.setPosition(44);
      while (true) {
        if (cancellation.isCancelled) {
          throw const SpeechRecognitionException('cancelled');
        }
        if (_failure != null) throw const SpeechRecognitionException('file');
        if (offset < _written) {
          final chunk = await input.read(min(6400, _written - offset));
          if (chunk.isEmpty) throw const SpeechRecognitionException('file');
          offset += chunk.length;
          yield chunk;
        } else if (_ended) {
          break;
        } else {
          final changed = _changed.future;
          if (offset >= _written && !_ended) {
            await Future.any([changed, cancellation.whenCancel.then((_) {})]);
          }
        }
      }
    } finally {
      try {
        await input?.close();
      } finally {
        _readers.remove(closed);
        closed.complete();
      }
    }
  }

  /// The native recorder must have stopped first, so no more chunks can arrive.
  Future<String> finish() => _finishing ??= _finish();
  Future<String> _finish() async {
    await _subscription?.cancel();
    await _writes;
    _ended = true;
    _notify();
    try {
      if (_failure != null) throw _failure!;
      await _output.setPosition(0);
      await _output.writeFrom(_header(_written));
      await _output.flush();
      return file.path;
    } finally {
      _closed = true;
      await _output.close();
    }
  }

  Future<void> discard() async {
    try {
      await finish();
    } catch (_) {
      /* Keep cancellation independent of I/O. */
    }
    await Future.wait(
      _readers.map((reader) => reader.future).toList(),
    ).timeout(const Duration(seconds: 5));
    if (await file.exists()) await file.delete();
  }

  static Uint8List _header(int bytes) {
    if (bytes > 0xffffffff - 36) {
      throw const FileSystemException('Capture too large');
    }
    final header = Uint8List(44), data = ByteData(44);
    header.setRange(0, 4, 'RIFF'.codeUnits);
    header.setRange(8, 12, 'WAVE'.codeUnits);
    header.setRange(12, 16, 'fmt '.codeUnits);
    header.setRange(36, 40, 'data'.codeUnits);
    data.setUint32(4, bytes + 36, Endian.little);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 16000, Endian.little);
    data.setUint32(28, 32000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    data.setUint32(40, bytes, Endian.little);
    for (final span in [(4, 8), (16, 36), (40, 44)]) {
      header.setRange(
        span.$1,
        span.$2,
        data.buffer.asUint8List().sublist(span.$1, span.$2),
      );
    }
    return header;
  }
}
