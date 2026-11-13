/// A stopped recording remains available until the editor chooses text or audio.
/// Closing releases its temporary file only after recognition has stopped reading.
class VoiceTextDraft {
  VoiceTextDraft({
    required this.result,
    required this.saveOriginal,
    required this.releaseCapture,
  });

  final Future<String?> result;
  final Future<bool> Function() saveOriginal;
  final Future<void> Function(bool) releaseCapture;
  Future<bool>? _sending;
  Future<void>? _releasing;
  bool _sent = false;

  Future<bool> sendOriginal() {
    if (_sent) return Future.value(true);
    if (_releasing != null) return Future.value(false);
    return _sending ??= saveOriginal().then(
      (sent) {
        _sent = sent;
        if (!sent) _sending = null;
        return sent;
      },
      onError: (Object error, StackTrace stack) {
        _sending = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<void> release({bool sentText = false}) => _releasing ??= () async {
    try {
      await _sending;
    } catch (_) {
      // The owner still releases (or preserves) an unsuccessful capture.
    }
    await releaseCapture(sentText);
  }();
}
