import 'package:dont_forget/ui/widgets/voice_capture_feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slide up then left or right selects a release action', () {
    final gesture = VoiceCaptureGesture();
    expect(gesture.update(const Offset(-80, 0)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(0, -80)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(-80, -80)), VoiceReleaseAction.cancel);
    expect(gesture.update(const Offset(80, -80)), VoiceReleaseAction.text);
    expect(gesture.update(const Offset(0, -80)), VoiceReleaseAction.save);
  });

  test('horizontal choice tolerates drift until returning to the input', () {
    final gesture = VoiceCaptureGesture();
    gesture.update(const Offset(0, -60));
    expect(gesture.update(const Offset(-80, -30)), VoiceReleaseAction.cancel);
    expect(gesture.update(const Offset(80, -30)), VoiceReleaseAction.text);
    expect(gesture.update(const Offset(80, 0)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(80, -30)), VoiceReleaseAction.save);
  });

  test('a new recording does not inherit the previous selection area', () {
    final gesture = VoiceCaptureGesture();
    gesture.update(const Offset(80, -80));
    gesture.reset();
    expect(gesture.update(const Offset(80, -30)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(80, -80)), VoiceReleaseAction.text);
  });
}
