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
    Widget field(String label, String local, String peer) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(l10n.get('syncThisDevice'), style: theme.textTheme.labelMedium),
          Text(local.isEmpty ? '—' : local),
          const SizedBox(height: 4),
          Text(l10n.get('syncPeerDevice'), style: theme.textTheme.labelMedium),
          Text(peer.isEmpty ? '—' : peer),
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
              return ExpansionTile(
                key: PageStorageKey(conflict.taskId),
                tilePadding: EdgeInsets.zero,
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                title: Text(
                  local.title.isEmpty ? peer.title : local.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
