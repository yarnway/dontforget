import 'dart:async';
import 'package:flutter/material.dart';

/// App-wide feedback in normal layout: no overlay, focus change or message queue.
/// Accepts existing SnackBar descriptions while migrating callers incrementally;
/// the SnackBar itself is never mounted.
class InlineFeedback extends StatefulWidget {
  const InlineFeedback({super.key, required this.child});
  final Widget child;

  static InlineFeedbackState of(BuildContext context) =>
      context.findAncestorStateOfType<InlineFeedbackState>()!;

  @override
  State<InlineFeedback> createState() => InlineFeedbackState();
}

class InlineFeedbackState extends State<InlineFeedback> {
  SnackBar? _message;
  Timer? _expiry;

  void showSnackBar(SnackBar message) {
    _expiry?.cancel();
    setState(() => _message = message);
    // Actionable results (for example Undo) remain until explicitly handled.
    if (message.action == null &&
        !MediaQuery.of(context).accessibleNavigation) {
      final duration = message.duration < const Duration(seconds: 8)
          ? const Duration(seconds: 8)
          : message.duration;
      _expiry = Timer(duration, hideCurrentSnackBar);
    }
  }

  void hideCurrentSnackBar() {
    _expiry?.cancel();
    if (mounted && _message != null) setState(() => _message = null);
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (message != null)
          Material(
            key: const ValueKey('inline-feedback'),
            color: colors.inverseSurface,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: DefaultTextStyle(
                            style: Theme.of(context).textTheme.bodyMedium!
                                .copyWith(color: colors.onInverseSurface),
                            child: message.content,
                          ),
                        ),
                      ),
                    ),
                    if (message.action case final action?)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: colors.inversePrimary,
                        ),
                        onPressed: () {
                          hideCurrentSnackBar();
                          action.onPressed();
                        },
                        child: Text(action.label),
                      ),
                    Semantics(
                      label: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      button: true,
                      child: IconButton(
                        color: colors.onInverseSurface,
                        onPressed: hideCurrentSnackBar,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
