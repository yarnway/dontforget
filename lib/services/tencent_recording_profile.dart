import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

RecordConfig tencentRecordingProfile([
  TargetPlatform? platform,
]) => RecordConfig(
  // The Windows WAV encoder rewrites Media Foundation's finalized RIFF header
  // incorrectly in record_windows 1.0.7. PCM output to a .wav path lets the
  // native WAV sink finalize the container itself, without that rewrite.
  encoder: (platform ?? defaultTargetPlatform) == TargetPlatform.windows
      ? AudioEncoder.pcm16bits
      : AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
);
