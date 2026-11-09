/// Transport errors can contain signed URLs. Only safe codes leave ASR clients.
class SpeechRecognitionException implements Exception {
  const SpeechRecognitionException(this.code);
  final String code;
  @override
  String toString() => 'SpeechRecognitionException($code)';
}
