import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../data/database_helper.dart';
import '../../l10n/content_management_strings.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/content/content_cleanup_service.dart';
import '../../services/local_media_store.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/shared_text_inbox.dart';
import '../formatters/byte_size.dart';
import '../screens/notification_repair_screen.dart';
import '../screens/shared_text_inbox_screen.dart';
import '../../l10n/shared_text_strings.dart';
import 'editable_text_menu.dart';
import 'external_backup_references_dialog.dart';

final contentCleanupServiceProvider = Provider<Future<ContentCleanupService>>((
  ref,
) async {
  final database = ref.watch(databaseHelperProvider);
  return ContentCleanupService(
    database,
    await getApplicationDocumentsDirectory(),
  );
});

class ContentManagementPanel extends ConsumerStatefulWidget {
  const ContentManagementPanel({super.key});
  @override
  ConsumerState<ContentManagementPanel> createState() =>
      _ContentManagementPanelState();
}

class _ContentManagementPanelState
    extends ConsumerState<ContentManagementPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  ContentInventory? _inventory;
  final _query = TextEditingController();
  final _selected = <String>{};
  String _view = 'originals';
  bool _onlyEligible = false;
  bool _prompting = false;
  bool _busy = false, _showArchive = true, _nativeFailed = false;
  String? _message;
  bool get _current =>
      mounted && _database.isCurrent(_generation) && _runtime.isCurrent(_birth);
  String t(String key) => contentText(context, key);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(contentCleanupServiceProvider);
      final inventory = await service.inspect(_generation);
      if (_current) {
        setState(() {
          _inventory = inventory;
          _selected.clear();
          _message = null;
        });
      }
    } catch (_) {
      if (_current) setState(() => _message = 'failed');
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, List<String> lines, String hint) async {
    setState(() => _prompting = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(hint),
                      const SizedBox(height: 10),
                      ...lines.map(Text.new),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  key: const ValueKey('content-confirm'),
                  onPressed: () => Navigator.pop(c, true),
                  child: Text(t('confirm')),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  Future<void> _clean() async {
    if (!_current || _busy || _inventory == null || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(contentCleanupServiceProvider);
      final plan = await service.prepare(
        _inventory!,
        Set.of(_selected),
        _generation,
        isCurrent: () => _current,
      );
      if (!_current) return;
      final confirmed = await _confirm(t('cleanConfirm'), [
        '${plan.entries.length} · ${_size(plan.bytes)}',
        ...plan.entries.map((e) => e.label),
      ], t('cleanHint'));
      if (!_current || !confirmed) return;
      final result = await service.clean(
        plan,
        _generation,
        isCurrent: () => _current,
      );
      if (!_current) return;
      ref.invalidate(mediaRecordsProvider);
      ContentInventory? refreshed;
      try {
        refreshed = await service.inspect(_generation);
      } catch (_) {}
      if (_current) {
        setState(() {
          if (refreshed != null) _inventory = refreshed;
          _selected.clear();
          _message = result.pending ? 'pending' : 'done';
        });
      }
    } catch (_) {
      if (_current) setState(() => _message = 'failed');
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _repair(String job) async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(contentCleanupServiceProvider);
      await service.repair(job, _generation, isCurrent: () => _current);
      final inventory = await service.inspect(_generation);
      if (_current) {
        setState(() {
          _inventory = inventory;
          _selected.clear();
          _message = 'done';
        });
      }
    } catch (_) {
      if (_current) setState(() => _message = 'failed');
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _archive(Reminder row, List<Reminder> all) async {
    if (!_current || _busy) return;
    final children = List<Reminder>.unmodifiable(
      all.where((e) => e.details.planId == row.id),
    );
    final archived = row.details.archivedAt == null;
    setState(() => _busy = true);
    try {
      final confirmed =
          await _confirm(t(archived ? 'archiveAction' : 'unarchiveAction'), [
            '${row.taskTitle} · ${t('members')}: ${children.length}',
            ...children.take(10).map((e) => e.taskTitle),
            if (children.length > 10) '… +${children.length - 10}',
          ], t('archiveHint'));
      if (!_current || !confirmed) return;
      final result = await ref
          .read(remindersProvider.notifier)
          .changeContentArchive(row, children, archived, _generation);
      if (_current) {
        setState(() {
          _nativeFailed = result.nativeSyncFailures > 0;
          _message = _nativeFailed ? 'nativeFailed' : 'done';
        });
      }
    } catch (_) {
      if (_current) setState(() => _message = 'failed');
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _detail(ContentCleanupEntry entry) async {
    final record = entry.record;
    String? image;
    if (record?['type'] == 'image') {
      image = await LocalMediaStore().resolvePath(
        record!['content_or_path'] as String,
      );
    }
    if (!mounted || !_current) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('detail')),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(entry.label),
                if (record != null)
                  SelectableText(record['content_or_path'] as String),
                if (image != null)
                  Image.file(
                    File(image),
                    cacheWidth: 1160,
                    semanticLabel: entry.label,
                    errorBuilder: (_, error, stack) => Text(t('failed')),
                  ),
                for (final path in entry.files) SelectableText(path),
                Text(entry.reason.isEmpty ? t('eligible') : t(entry.reason)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t('close')),
          ),
        ],
      ),
    );
  }

  String _size(int bytes) => formatByteSize(bytes);

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final l10n = AppLocalizations.of(context);
    final sharedDraftCount = ref.watch(
      workspaceDraftsProvider.select(SharedTextInbox.count),
    );
    final entries = (_inventory?.entries ?? <ContentCleanupEntry>[])
        .where(
          (e) =>
              (_view == 'restore'
                  ? e.kind == ContentEntryKind.restore
                  : e.kind != ContentEntryKind.restore) &&
              e.label.toLowerCase().contains(query) &&
              (!_onlyEligible || e.eligible),
        )
        .toList();
    final eligible = entries.where((e) => e.eligible).toList();
    final selectedBytes = (_inventory?.entries ?? <ContentCleanupEntry>[])
        .where((e) => _selected.contains(e.key))
        .fold<int>(0, (n, e) => n + e.bytes);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .48,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        key: const ValueKey('content-shared-drafts'),
                        leading: const Icon(Icons.inbox_outlined),
                        title: Text(
                          sharedTextLabel(
                            AppLocalizations.of(context).locale.languageCode,
                            'title',
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (sharedDraftCount > 0) ...[
                              Badge.count(
                                key: const ValueKey(
                                  'content-shared-drafts-count',
                                ),
                                count: sharedDraftCount,
                              ),
                              const SizedBox(width: 8),
                            ],
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: _busy
                            ? null
                            : () => openSharedTextInbox(context, ref),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final view in [
                            'originals',
                            'restore',
                            'archive',
                          ])
                            ChoiceChip(
                              label: Text(t(view)),
                              selected: _view == view,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() {
                                      _view = view;
                                      _selected.clear();
                                    }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const ValueKey('content-query'),
                        contextMenuBuilder: buildEditableTextMenu,
                        controller: _query,
                        decoration: InputDecoration(
                          hintText: t('filter'),
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.text.isEmpty
                              ? null
                              : IconButton(
                                  key: const ValueKey('content-query-clear'),
                                  tooltip: l10n.get('clearSearch'),
                                  icon: const Icon(Icons.clear_rounded, size: 18),
                                  onPressed: () {
                                    _query.clear();
                                    setState(() {});
                                  },
                                ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      if (_view != 'archive') ...[
                        ListTile(
                          key: const ValueKey('content-external-backups'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.shield_outlined),
                          title: Text(t('externalBackups')),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: _busy
                              ? null
                              : () async {
                                  await showDialog<void>(
                                    context: context,
                                    builder: (_) =>
                                        const ExternalBackupReferencesDialog(),
                                  );
                                  if (_current && _inventory != null) {
                                    await _load();
                                  }
                                },
                        ),
                        ExpansionTile(
                          key: const ValueKey('content-protection-help'),
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            t('protectionHelp'),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          leading: const Icon(Icons.shield_outlined),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                t('hint'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton.icon(
                              key: const ValueKey('content-scan'),
                              onPressed: _busy ? null : _load,
                              icon: const Icon(Icons.refresh),
                              label: Text(t('scan')),
                            ),
                            FilledButton.tonal(
                              key: const ValueKey('content-clean'),
                              onPressed: _busy || _selected.isEmpty
                                  ? null
                                  : _clean,
                              child: Text(
                                '${t('clean')} (${_selected.length}/100)',
                              ),
                            ),
                          ],
                        ),
                        if (_inventory != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            t('scannedSpace').replaceAll(
                              '{bytes}',
                              _size(_inventory!.scannedBytes),
                            ),
                            key: const ValueKey('content-scanned-space'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            t('spaceSummary')
                                .replaceAll('{count}', '${eligible.length}')
                                .replaceAll(
                                  '{bytes}',
                                  _size(
                                    eligible.fold<int>(
                                      0,
                                      (n, e) => n + e.bytes,
                                    ),
                                  ),
                                ),
                            key: const ValueKey('content-space-summary'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (_selected.isNotEmpty)
                            Text(
                              t('selectionSummary')
                                  .replaceAll('{count}', '${_selected.length}')
                                  .replaceAll('{bytes}', _size(selectedBytes)),
                            ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilterChip(
                                key: const ValueKey('content-eligible-only'),
                                label: Text(t('eligibleOnly')),
                                selected: _onlyEligible,
                                onSelected: _busy
                                    ? null
                                    : (v) => setState(() => _onlyEligible = v),
                              ),
                              TextButton(
                                key: const ValueKey('content-select-visible'),
                                onPressed:
                                    _busy ||
                                        eligible.isEmpty ||
                                        _selected.length >= 100
                                    ? null
                                    : () => setState(() {
                                        for (final e in eligible) {
                                          if (_selected.length >= 100) break;
                                          _selected.add(e.key);
                                        }
                                      }),
                                child: Text(t('selectVisible')),
                              ),
                              TextButton(
                                key: const ValueKey('content-clear-selection'),
                                onPressed: _busy || _selected.isEmpty
                                    ? null
                                    : () => setState(_selected.clear),
                                child: Text(t('clearSelection')),
                              ),
                            ],
                          ),
                        ],
                        for (final job in _inventory?.pendingJobs ?? <String>[])
                          ListTile(
                            title: Text(t('pending')),
                            trailing: TextButton(
                              key: ValueKey('content-repair:$job'),
                              onPressed: _busy ? null : () => _repair(job),
                              child: Text(t('retry')),
                            ),
                          ),
                      ] else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final value in [true, false])
                              ChoiceChip(
                                label: Text(
                                  t(value ? 'archived' : 'available'),
                                ),
                                selected: _showArchive == value,
                                onSelected: _busy
                                    ? null
                                    : (_) =>
                                          setState(() => _showArchive = value),
                              ),
                          ],
                        ),
                      if (_message != null) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          container: true,
                          liveRegion: true,
                          child: Text(t(_message!)),
                        ),
                      ],
                      if (_nativeFailed)
                        TextButton(
                          onPressed: notificationRepairAction(
                            context,
                          ).onPressed,
                          child: Text(
                            AppLocalizations.of(
                              context,
                            ).get('repairNotifications'),
                          ),
                        ),
                      if (_busy && !_prompting) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          semanticsLabel: AppLocalizations.of(
                            context,
                          ).get('loading'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _view == 'archive'
                  ? _ArchiveTabView(
                      query: query,
                      showArchive: _showArchive,
                      busy: _busy,
                      labelFor: t,
                      onArchive: _archive,
                    )
                  : _inventory == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10n.get('contentCleanupUnscanned'),
                          key: const ValueKey('content-unscanned-hint'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : entries.isEmpty
                  ? Center(child: Text(t('empty')))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        return Card(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              CheckboxListTile(
                                key: ValueKey('content-entry:${entry.key}'),
                                title: Text(
                                  entry.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_size(entry.bytes)} · ${t(entry.reason.isEmpty ? 'eligible' : entry.reason)}',
                                ),
                                value: _selected.contains(entry.key),
                                onChanged:
                                    _busy ||
                                        !entry.eligible ||
                                        (!_selected.contains(entry.key) &&
                                            _selected.length >= 100)
                                    ? null
                                    : (value) => setState(() {
                                        if (value == true) {
                                          _selected.add(entry.key);
                                        } else {
                                          _selected.remove(entry.key);
                                        }
                                      }),
                              ),
                              if (entry.eligible &&
                                  entry.record != null &&
                                  entry.record!['type'] != 'text' &&
                                  entry.files.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Text(t('external')),
                                ),
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: TextButton(
                                  onPressed: () => _detail(entry),
                                  child: Text(t('detail')),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Isolated subscriber for the Archive tab so reminder mutations do not rebuild
/// the Originals / Restore cleanup views.
class _ArchiveTabView extends ConsumerWidget {
  const _ArchiveTabView({
    required this.query,
    required this.showArchive,
    required this.busy,
    required this.labelFor,
    required this.onArchive,
  });

  final String query;
  final bool showArchive;
  final bool busy;
  final String Function(String key) labelFor;
  final Future<void> Function(Reminder row, List<Reminder> all) onArchive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(remindersProvider);
    final roots =
        all
            .where(
              (e) =>
                  e.details.planId == null &&
                  e.details.deletedAt == null &&
                  e.details.data['learning_archive'] != true &&
                  (e.details.archivedAt != null) == showArchive &&
                  '${e.taskTitle} ${e.details.project} ${e.details.tags.join(' ')}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort((a, b) => a.taskTitle.compareTo(b.taskTitle));
    if (roots.isEmpty) {
      return Center(child: Text(labelFor('empty')));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: roots.length,
      itemBuilder: (context, i) {
        final row = roots[i];
        return Card(
          child: ListTile(
            title: Text(row.taskTitle),
            subtitle: Text(
              [
                labelFor(row.details.kind),
                if (row.details.project.isNotEmpty) row.details.project,
                if (row.details.tags.isNotEmpty) row.details.tags.join(' / '),
              ].join(' · '),
            ),
            isThreeLine: false,
            trailing: IconButton(
              key: ValueKey('content-archive:${row.id}'),
              tooltip: labelFor(
                row.details.archivedAt == null
                    ? 'archiveAction'
                    : 'unarchiveAction',
              ),
              onPressed: busy ? null : () => onArchive(row, all),
              icon: Icon(
                row.details.archivedAt == null
                    ? Icons.archive_outlined
                    : Icons.unarchive_outlined,
              ),
            ),
          ),
        );
      },
    );
  }
}
