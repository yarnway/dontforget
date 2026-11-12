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

  test(
    'up prepares recognition, near right edits and further right explicitly sends',
    () {
      final gesture = VoiceCaptureGesture();
      expect(gesture.selectionOpen, isFalse);
      gesture.update(const Offset(0, -60));
      expect(gesture.selectionOpen, isTrue);
      expect(gesture.update(const Offset(80, -60)), VoiceReleaseAction.text);
      expect(gesture.update(const Offset(110, -60)), VoiceReleaseAction.send);
      expect(gesture.update(const Offset(0, 0)), VoiceReleaseAction.save);
      expect(gesture.selectionOpen, isFalse);
    },
  );

  test('a new recording does not inherit the previous selection area', () {
    final gesture = VoiceCaptureGesture();
    gesture.update(const Offset(80, -80));
    gesture.reset();
    expect(gesture.update(const Offset(80, -30)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(80, -80)), VoiceReleaseAction.text);
  });
  test('small send-boundary tremors retain one clearly selected action', () {
    final gesture = VoiceCaptureGesture();
    expect(gesture.update(const Offset(97, -70)), VoiceReleaseAction.send);
    for (final x in [95.0, 91.0, 85.0, 96.0]) {
      expect(gesture.update(Offset(x, -70)), VoiceReleaseAction.send);
    }
    expect(gesture.update(const Offset(70, -70)), VoiceReleaseAction.text);
    expect(gesture.update(const Offset(95, -70)), VoiceReleaseAction.text);
    expect(gesture.update(const Offset(97, -70)), VoiceReleaseAction.send);
  });
  test('returning down or resetting always disarms a selected send action', () {
    final gesture = VoiceCaptureGesture();
    gesture.update(const Offset(110, -70));
    expect(gesture.update(const Offset(110, 0)), VoiceReleaseAction.save);
    expect(gesture.update(const Offset(85, -70)), VoiceReleaseAction.text);
    gesture.update(const Offset(110, -70));
    gesture.reset();
    expect(gesture.update(const Offset(85, -70)), VoiceReleaseAction.text);
  });
  test(
    'edit and cancel targets tolerate drift but can return to the neutral area',
    () {
      final gesture = VoiceCaptureGesture();
      expect(gesture.update(const Offset(-25, -70)), VoiceReleaseAction.cancel);
      expect(gesture.update(const Offset(-20, -70)), VoiceReleaseAction.cancel);
      expect(gesture.update(const Offset(0, -70)), VoiceReleaseAction.save);
      expect(gesture.update(const Offset(25, -70)), VoiceReleaseAction.text);
      expect(gesture.update(const Offset(20, -70)), VoiceReleaseAction.text);
      expect(gesture.update(const Offset(0, -70)), VoiceReleaseAction.save);
    },
  );
}
