import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Reserves space beside the board; the composer stays outside this area.
/// On compact windows only the board is replaced, without a modal barrier.
class WorkspaceToolArea extends StatelessWidget {
  const WorkspaceToolArea({super.key, required this.child, this.tool});
  final Widget child;
  final Widget? tool;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final width = (constraints.maxWidth * .36).clamp(360.0, 420.0);
      final colors = Theme.of(context).colorScheme;
      return Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: !wide && tool != null,
            child: ExcludeFocus(
              excluding: !wide && tool != null,
              child: TickerMode(
                enabled: wide || tool == null,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    end: wide && tool != null ? width : 0,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
          if (tool != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                width: wide ? width : double.infinity,
                height: double.infinity,
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    wide ? 0 : 12,
                    8,
                    12,
                    8,
                  ),
                  child: Material(
                    key: const ValueKey('workspace-tool-panel'),
                    color: colors.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: tool,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class WorkspaceToolFrame extends StatelessWidget {
  const WorkspaceToolFrame({
    super.key,
    required this.title,
    required this.icon,
    this.children = const [],
    this.body,
    this.actions = const [],
    this.onClose,
    this.canClose = true,
    this.embedded = false,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? body;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final bool canClose, embedded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 760,
        maxHeight: embedded
            ? double.infinity
            : MediaQuery.sizeOf(context).height * .85,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .4,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 16),
                  child: Row(
                    children: [
                      Icon(icon, size: 22, color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      ...actions,
                      IconButton(
                        tooltip: AppLocalizations.of(context).get('close'),
                        onPressed: canClose
                            ? onClose ?? () => Navigator.pop(context)
                            : null,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child:
                  body ??
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
