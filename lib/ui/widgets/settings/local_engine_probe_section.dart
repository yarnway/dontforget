import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/providers.dart';
import '../../../services/llm_service.dart';
import '../inline_feedback.dart';

/// Probes local OpenAI-compatible inference servers (Ollama / LM Studio / LocalAI)
/// and lets the user apply a detected endpoint to AI settings in one tap.
class LocalEngineProbeSection extends ConsumerStatefulWidget {
  const LocalEngineProbeSection({
    super.key,
    required this.onApply,
    this.enabled = true,
  });

  final ValueChanged<LocalInferenceEndpoint> onApply;
  final bool enabled;

  @override
  ConsumerState<LocalEngineProbeSection> createState() =>
      _LocalEngineProbeSectionState();
}

class _LocalEngineProbeSectionState
    extends ConsumerState<LocalEngineProbeSection> {
  bool _isProbing = false;
  List<LocalInferenceEndpoint>? _probeResults;

  Future<void> _probeLocalEngines() async {
    if (_isProbing) return;
    setState(() => _isProbing = true);
    try {
      final llmService = ref.read(llmServiceProvider);
      final results = await llmService.probeLocalInferenceEndpoints();
      if (mounted) setState(() => _probeResults = results);
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).get('probeFailed')),
          ),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final onlineColor = isDark
        ? const Color(0xFF6DD58C)
        : const Color(0xFF146C2E);

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.radar_rounded, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.get('localEngineProbe'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: _isProbing ? null : _probeLocalEngines,
                  icon: _isProbing
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      : const Icon(Icons.refresh_rounded, size: 14),
                  label: Text(
                    _isProbing ? l10n.get('probing') : l10n.get('probeNow'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.get('probeDesc'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            if (_probeResults != null) ...[
              const SizedBox(height: 10),
              for (final ep in _probeResults!)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: ep.isAvailable
                            ? colors.primary.withValues(alpha: 0.45)
                            : colors.outlineVariant,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          ep.isAvailable
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: ep.isAvailable
                              ? onlineColor
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${ep.name} (Port ${ep.port})',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                ep.isAvailable
                                    ? '${ep.recommendedModel} · ${ep.latencyMs}ms'
                                    : l10n.get('portNotListening'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: ep.isAvailable
                                      ? onlineColor
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (ep.isAvailable)
                          FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(64, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            onPressed: widget.enabled
                                ? () => widget.onApply(ep)
                                : null,
                            child: Text(
                              l10n.get('applyToSettings'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
