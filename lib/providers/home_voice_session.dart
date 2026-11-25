part of 'home_controller.dart';

/// Coordinates progressive WAV snapshot transcription while the user holds the
/// swipe-up-right gesture on non-streaming ASR backends (Tencent Flash / LLM Whisper).
class _ProgressiveSnapshotTranscriber {
  static LiveSpeechSession start({
    required LivePcmRecording pcm,
    required Future<String> Function(String path) transcribeFile,
    required bool Function() isActive,
    required void Function(String text) onText,
  }) {
    final token = CancelToken();
    final result = (() async {
      String? lastText;
      var lastTranscribedBytes = 0;
      try {
        while (!token.isCancelled && isActive() && !pcm.isEnded) {
          final targetBytes = lastTranscribedBytes == 0
              ? 16000 // ~0.5s initial speech
              : lastTranscribedBytes + 32000; // ~1.0s additional speech
          await pcm.waitForBytes(targetBytes, token);
          if (token.isCancelled || !isActive() || pcm.isEnded) break;
          if (pcm.writtenBytes < 16000) continue;

          final snapPath =
              '${pcm.file.parent.path}/snap_${const Uuid().v4()}.wav';
          var copiedBytes = 0;
          try {
            copiedBytes = await pcm.writeWavSnapshot(
              snapPath,
              minBytes: 16000,
              cancellation: token,
            );
            if (copiedBytes > 0 && !token.isCancelled && isActive()) {
              final text = (await transcribeFile(snapPath)).trim();
              if (text.isNotEmpty && !token.isCancelled && isActive()) {
                lastText = text;
                lastTranscribedBytes = copiedBytes;
                onText(text);
              }
            }
          } catch (_) {
            // Transient snapshot failures must not abort ongoing capture;
            // final transcription on release still runs on the full recording.
            if (!token.isCancelled && !pcm.isEnded) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
          } finally {
            try {
              final snapFile = File(snapPath);
              if (await snapFile.exists()) await snapFile.delete();
            } catch (_) {}
          }
        }

        if (token.isCancelled || !isActive()) {
          throw const SpeechRecognitionException('cancelled');
        }
        // Wait for LivePcmRecording.finish() to flush its WAV header before
        // deciding whether a final tail pass is needed.
        final finalPath = await pcm.finish();
        if (token.isCancelled || !isActive()) {
          throw const SpeechRecognitionException('cancelled');
        }
        if (lastText != null &&
            (pcm.writtenBytes - lastTranscribedBytes) < 3200) {
          return lastText;
        }
        final fullText = (await transcribeFile(finalPath)).trim();
        if (fullText.isNotEmpty) {
          onText(fullText);
          return fullText;
        }
        if (lastText != null && lastText.isNotEmpty) return lastText;
        throw const FormatException('Empty speech');
      } finally {
        if (!token.isCancelled) token.cancel();
      }
    })();

    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return LiveSpeechSession(result, () {
      if (!token.isCancelled) token.cancel();
    });
  }
}
