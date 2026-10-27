import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

enum VoiceReleaseAction { save, cancel, text }

class VoiceCaptureGesture {
  bool _selectionOpen = false;

  void reset() => _selectionOpen = false;

  VoiceReleaseAction update(Offset movement) {
    // Slide up to choose, then move horizontally. A small vertical drift while
    // choosing must not unexpectedly save the recording. Returning to the input
    // closes the selection area and restores the normal release-to-save action.
    if (movement.dy <= -48) _selectionOpen = true;
    if (movement.dy >= -16) _selectionOpen = false;
    if (!_selectionOpen || movement.dx.abs() < 24) {
      return VoiceReleaseAction.save;
    }
    return movement.dx < 0
        ? VoiceReleaseAction.cancel
        : VoiceReleaseAction.text;
  }
}

class VoiceCaptureFeedback extends StatelessWidget {
  const VoiceCaptureFeedback({super.key, required this.action});
  final VoiceReleaseAction action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    Widget target(VoiceReleaseAction value, IconData icon, String label) {
      final selected = action == value;
      final color = value == VoiceReleaseAction.cancel
          ? colors.error
          : colors.primary;
      return Expanded(
        child: AnimatedContainer(
          key: ValueKey('voice-target-${value.name}'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: .15)
                : colors.surfaceContainerLow,
            border: Border.all(
              color: selected ? color : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? color : colors.onSurfaceVariant,
                size: 24,
              ),
              const SizedBox(height: 6),
              Text(
                l10n.get(label),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? color : colors.onSurface,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Row(
        children: [
          target(
            VoiceReleaseAction.cancel,
            Icons.close_rounded,
            'voiceSlideCancel',
          ),
          const SizedBox(width: 10),
          target(
            VoiceReleaseAction.text,
            Icons.text_fields_rounded,
            'voiceSlideText',
          ),
        ],
      ),
    );
  }
}
