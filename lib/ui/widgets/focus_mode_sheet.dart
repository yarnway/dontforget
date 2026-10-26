import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../services/context_trigger_service.dart';
import '../../services/recovery/runtime_gate.dart';
import 'workspace_tool_panel.dart';

class FocusModeSheet extends ConsumerStatefulWidget {
  const FocusModeSheet({super.key, this.onClose, this.embedded = false});
  final VoidCallback? onClose;
  final bool embedded;
  @override
  ConsumerState<FocusModeSheet> createState() => _FocusModeSheetState();
}

class _FocusModeSheetState extends ConsumerState<FocusModeSheet> {
  late final RuntimeRecoveryGate _gate;
  late final RuntimeRecoveryToken? _birth;
  bool _busy = false;
  String? _feedback;
  @override
  void initState() {
    super.initState();
    _gate = ref.read(runtimeRecoveryGateProvider);
    _birth = _gate.paused ? null : _gate.capture();
  }

  Future<void> _apply(bool enabled) async {
    if (_busy || !_gate.isCurrent(_birth)) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final result = await ref
          .read(immersiveModeProvider.notifier)
          .apply(enabled);
      if (!mounted || !_gate.isCurrent(_birth)) return;
      setState(
        () => _feedback = result.failed == 0
            ? 'focusApplied'
            : 'focusPartialFailure',
      );
    } catch (_) {
      if (mounted && _gate.isCurrent(_birth)) {
        setState(() => _feedback = 'focusPartialFailure');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final enabled = ref.watch(immersiveModeProvider);
    final profile = ref.watch(contextProfileProvider);
    final contextQuiet =
        profile == ContextProfile.office || profile == ContextProfile.deepWork;
    final colors = Theme.of(context).colorScheme;
    return WorkspaceToolFrame(
      title: loc.get('focusTitle'),
      icon: Icons.shield_outlined,
      embedded: widget.embedded,
      onClose: widget.onClose,
      children: [
        Material(
          color: enabled
              ? colors.primaryContainer.withValues(alpha: .35)
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 6,
            ),
            title: Text(loc.get(enabled ? 'focusOn' : 'focusOff')),

            value: enabled,
            onChanged: _busy || !_gate.isCurrent(_birth) ? null : _apply,
          ),
        ),
        const SizedBox(height: 16),
        Text(loc.get('focusScope')),
        const SizedBox(height: 12),
        Text(
          loc.get('focusSession'),
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(loc.get('focusDetails')),
          children: [
            Text(
              loc.get('focusLimit'),
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        if (contextQuiet) ...[
          const SizedBox(height: 16),
          Text(
            loc.get('focusContextQuiet'),
            style: TextStyle(color: colors.primary),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(loc.get('focusApplying')),
        ],
        if (_feedback != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              loc.get(_feedback!),
              style: TextStyle(
                color: _feedback == 'focusPartialFailure'
                    ? colors.error
                    : colors.primary,
              ),
            ),
          ),
        ],
        if (_feedback == 'focusPartialFailure')
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy || !_gate.isCurrent(_birth)
                  ? null
                  : () => _apply(enabled),
              icon: const Icon(Icons.refresh),
              label: Text(loc.get('focusRetry')),
            ),
          ),
      ],
    );
  }
}
