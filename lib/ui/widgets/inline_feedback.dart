import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum FeedbackTone { info, success, warning, error }

/// Compact feedback without a layout shift, focus change or modal barrier.
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
  FeedbackTone _tone = FeedbackTone.info;
  final _actionFocus = FocusNode(debugLabel: 'Feedback action');
  final _closeFocus = FocusNode(debugLabel: 'Close feedback');
  FocusNode? _previousFocus;

  void _toggleFeedbackFocus() {
    if (_message == null) return;
    if (_actionFocus.hasFocus || _closeFocus.hasFocus) {
      _restoreFocus();
    } else {
      _previousFocus = FocusManager.instance.primaryFocus;
      (_message!.action == null ? _closeFocus : _actionFocus).requestFocus();
    }
  }

  void _restoreFocus() {
    final previous = _previousFocus;
    if (previous?.context != null && previous!.canRequestFocus) {
      previous.requestFocus();
    }
    _previousFocus = null;
  }

  void showSnackBar(SnackBar message, {FeedbackTone tone = FeedbackTone.info}) {
    _expiry?.cancel();
    setState(() {
      _message = message;
      _tone = tone;
    });
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
    if (_actionFocus.hasFocus || _closeFocus.hasFocus) _restoreFocus();
    if (mounted && _message != null) setState(() => _message = null);
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _actionFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    final colors = Theme.of(context).colorScheme;
    final (accent, icon) = switch (_tone) {
      FeedbackTone.success => (
        colors.primary,
        Icons.check_circle_outline_rounded,
      ),
      FeedbackTone.error => (colors.error, Icons.error_outline_rounded),
      FeedbackTone.warning => (colors.tertiary, Icons.warning_amber_rounded),
      FeedbackTone.info => (colors.secondary, Icons.info_outline_rounded),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f6): _toggleFeedbackFocus,
      },
      child: LayoutBuilder(
        builder: (context, size) {
          final insets = MediaQuery.paddingOf(context);
          final top = insets.top + kToolbarHeight + 8;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Keep route semantics in its own subtree; Undo remains reachable.
              Semantics(container: true, child: widget.child),
              if (message != null)
                PositionedDirectional(
                  top: top,
                  end: 12 + insets.right,
                  width: math.min(
                    440,
                    math.max(0, size.maxWidth - 24 - insets.horizontal),
                  ),
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    child: Material(
                      key: const ValueKey('inline-feedback'),
                      color: Color.alphaBlend(
                        accent.withValues(alpha: 0.05),
                        colors.surfaceContainerHigh,
                      ),
                      elevation: 6,
                      shadowColor: colors.shadow.withValues(alpha: 0.22),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: accent.withValues(alpha: 0.3)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.max(
                            message.action == null ? 60 : 96,
                            math.min(
                              240,
                              size.maxHeight -
                                  top -
                                  16 -
                                  MediaQuery.viewInsetsOf(context).bottom,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Icon(icon, color: accent, size: 22),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 12,
                                    bottom: 12,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: SingleChildScrollView(
                                          child: DefaultTextStyle(
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium!
                                                .copyWith(
                                                  color: colors.onSurface,
                                                  height: 1.4,
                                                ),
                                            child: message.content,
                                          ),
                                        ),
                                      ),
                                      if (message.action case final action?)
                                        TextButton(
                                          focusNode: _actionFocus,
                                          onPressed: () {
                                            hideCurrentSnackBar();
                                            action.onPressed();
                                          },
                                          child: Text(action.label),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              Semantics(
                                label: MaterialLocalizations.of(
                                  context,
                                ).closeButtonTooltip,
                                button: true,
                                child: IconButton(
                                  focusNode: _closeFocus,
                                  color: colors.onSurfaceVariant,
                                  onPressed: hideCurrentSnackBar,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
