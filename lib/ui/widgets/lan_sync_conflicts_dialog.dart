import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/lan_sync_service.dart';

enum LanSyncConflictAction { openLocal, adoptPeerText, adoptPeerTrash }

class LanSyncConflictsDialog extends StatelessWidget {
  const LanSyncConflictsDialog({
    super.key,
    required this.conflicts,
    required this.openableTaskIds,
    required this.adoptableTaskIds,
    required this.trashActionTaskIds,
  });

  final List<LanSyncConflict> conflicts;
  final Set<String> openableTaskIds;
  final Set<String> adoptableTaskIds;
  final Set<String> trashActionTaskIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget sideBox({
      required IconData icon,
      required String heading,
      required String value,
      required Color background,
      required Color border,
      required Color accent,
    }) => MergeSemantics(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    heading,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Semantics(
              label: value.isEmpty ? l10n.get('emptyValue') : null,
              excludeSemantics: value.isEmpty,
              child: Text(value.isEmpty ? '—' : value),
            ),
          ],
        ),
      ),
    );
    Widget field(String label, String local, String peer) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 6),
          sideBox(
            icon: Icons.devices_outlined,
            heading: l10n.get('syncThisDevice'),
            value: local,
            background: colors.surfaceContainerLow,
            border: colors.outlineVariant,
            accent: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 6),
          sideBox(
            icon: Icons.sync_alt_rounded,
            heading: l10n.get('syncPeerDevice'),
            value: peer,
            background: colors.secondaryContainer.withValues(alpha: 0.45),
            border: colors.primary.withValues(alpha: 0.35),
            accent: colors.primary,
          ),
        ],
      ),
    );
    String trash(bool value) =>
        l10n.get(value ? 'syncInTrash' : 'syncOutsideTrash');
    Widget action(
      LanSyncConflict conflict,
      LanSyncConflictAction choice,
      String label,
    ) => Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        onPressed: () =>
            Navigator.pop(context, (conflict: conflict, action: choice)),
        child: Text(label),
      ),
    );

    return AlertDialog(
      key: const ValueKey('lan-sync-conflicts-dialog'),
      title: Text(l10n.get('syncConflictTitle')),
      content: SizedBox(
        width: 540,
        height: MediaQuery.sizeOf(context).height * .56,
        child: SelectionArea(
          child: ListView.builder(
            itemCount: conflicts.length,
            itemBuilder: (context, index) {
              final conflict = conflicts[index];
              final local = conflict.local, peer = conflict.peer;
              final diffLabels = <String>[
                if (local.title != peer.title) l10n.get('syncTaskTitle'),
                if (local.note != peer.note) l10n.get('syncTaskNote'),
                if (local.inTrash != peer.inTrash)
                  l10n.get('syncTaskTrashStatus'),
              ];
              return ExpansionTile(
                key: PageStorageKey(conflict.taskId),
                tilePadding: EdgeInsets.zero,
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                title: Text(
                  local.title.isEmpty ? peer.title : local.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: diffLabels.isEmpty
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          diffLabels.join(' · '),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ),
                children: [
                  if (local.title != peer.title)
                    field(l10n.get('syncTaskTitle'), local.title, peer.title),
                  if (local.note != peer.note)
                    field(l10n.get('syncTaskNote'), local.note, peer.note),
                  if (local.inTrash != peer.inTrash)
                    field(
                      l10n.get('syncTaskTrashStatus'),
                      trash(local.inTrash),
                      trash(peer.inTrash),
                    ),
                  if (openableTaskIds.contains(conflict.taskId))
                    action(
                      conflict,
                      LanSyncConflictAction.openLocal,
                      l10n.get('syncOpenLocalTask'),
                    ),
                  if (adoptableTaskIds.contains(conflict.taskId))
                    action(
                      conflict,
                      LanSyncConflictAction.adoptPeerText,
                      l10n.get('syncAdoptPeerText'),
                    ),
                  if (trashActionTaskIds.contains(conflict.taskId))
                    action(
                      conflict,
                      LanSyncConflictAction.adoptPeerTrash,
                      l10n.get(
                        peer.inTrash
                            ? 'syncMoveLocalToTrash'
                            : 'syncRestoreLocal',
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.get('close')),
        ),
      ],
    );
  }
}
