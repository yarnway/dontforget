import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../services/context_trigger_service.dart';
import '../../services/recovery/runtime_gate.dart';

class FocusModeSheet extends ConsumerStatefulWidget {
  const FocusModeSheet({super.key});
  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const FocusModeSheet(),
  );
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
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      loc.get('focusTitle'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: loc.get('close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(loc.get(enabled ? 'focusOn' : 'focusOff')),
                subtitle: Text(loc.get('focusSession')),
                value: enabled,
                onChanged: _busy || !_gate.isCurrent(_birth) ? null : _apply,
              ),
              const SizedBox(height: 12),
              Text(loc.get('focusScope')),
              const SizedBox(height: 12),
              Text(
                loc.get('focusLimit'),
                style: TextStyle(color: colors.onSurfaceVariant),
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
          ),
        ),
      ),
    );
  }
}
