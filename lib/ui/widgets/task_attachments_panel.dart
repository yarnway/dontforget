import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;

import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../models/media_record.dart';
import '../../models/reminder.dart';
import '../../models/task_details.dart';
import '../../providers/providers.dart';
import '../../services/local_media_store.dart';
import '../../services/task_attachment_files.dart';
import '../formatters/byte_size.dart';
import 'inline_feedback.dart';

class TaskAttachmentPicker {
  Future<String?> image() async =>
      (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;
  Future<String?> file() async => (await FilePicker.pickFile())?.path;
}

final taskAttachmentPickerProvider = Provider((ref) => TaskAttachmentPicker());
final taskAttachmentFilesProvider = Provider((ref) => TaskAttachmentFiles());
final taskAttachmentPathProvider = Provider((ref) => LocalMediaStore());

final taskAttachmentRecordsProvider =
    Provider<Future<Map<String, MediaRecord>> Function(List<String>)>((ref) {
      final database = ref.read(databaseHelperProvider);
      return (ids) async {
        if (ids.isEmpty) return {};
        return database.read(database.captureGeneration(), (db) async {
          final rows = await db.query(
            'MediaRecords',
            where: 'id IN (${List.filled(ids.length, '?').join(',')})',
            whereArgs: ids,
          );
          return {
            for (final row in rows)
              row['id'] as String: MediaRecord.fromJson(row),
          };
        });
      };
    });

class TaskAttachmentsPanel extends ConsumerStatefulWidget {
  const TaskAttachmentsPanel({
    super.key,
    required this.task,
    this.enabled = true,
    this.readOnly = false,
    this.onBusyChanged,
  });
  final Reminder task;
  final bool enabled;
  final bool readOnly;
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<TaskAttachmentsPanel> createState() =>
      _TaskAttachmentsPanelState();
}

class _TaskAttachmentsPanelState extends ConsumerState<TaskAttachmentsPanel> {
  bool _busy = false;
  String? _readKey;
  Future<Map<String, MediaRecord>>? _records;

  Reminder? get _current {
    final row = ref.read(remindersByIdProvider)[widget.task.id];
    return row != null && row.isVisible ? row : null;
  }

  void _setBusy(bool value) {
    if (!mounted) return;
    setState(() => _busy = value);
    widget.onBusyChanged?.call(value);
  }

  void _feedback(
    String key, {
    VoidCallback? undo,
    FeedbackTone tone = FeedbackTone.info,
  }) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.get(key)),
        action: undo == null
            ? null
            : SnackBarAction(label: l10n.get('undo'), onPressed: undo),
      ),
      tone: tone,
    );
  }

  Future<void> _add(bool image) async {
    if (_busy || !widget.enabled || widget.readOnly) return;
    final task = _current;
    if (task == null ||
        task.details.attachmentIds.length >= TaskDetails.maxAttachments) {
      return;
    }
    _setBusy(true);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = database.captureGeneration();
      final gate = ref.read(runtimeRecoveryGateProvider);
      final token = gate.capture();
      final picker = ref.read(taskAttachmentPickerProvider);
      final selected = await (image ? picker.image() : picker.file());
      if (selected == null || !mounted) return;
      gate.check(token);
      database.checkGeneration(generation);
      await ref
          .read(remindersProvider.notifier)
          .addTaskAttachment(
            task,
            selected,
            generation,
            files: ref.read(taskAttachmentFilesProvider),
          );
      if (mounted) {
        await ref.read(mediaRecordsProvider.notifier).refreshMediaRecords();
      }
      gate.check(token);
      _feedback('taskAttachmentAdded', tone: FeedbackTone.success);
    } on AttachmentTooLarge {
      _feedback('taskAttachmentTooLarge', tone: FeedbackTone.warning);
    } catch (_) {
      _feedback('taskAttachmentFailed', tone: FeedbackTone.error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _link(
    String id,
    bool linked, {
    DataGeneration? generation,
  }) async {
    if (!mounted || _busy || !widget.enabled || widget.readOnly) return;
    final task = _current;
    if (task == null) return;
    _setBusy(true);
    try {
      final database = ref.read(databaseHelperProvider);
      final ticket = generation ?? database.captureGeneration();
      final gate = ref.read(runtimeRecoveryGateProvider);
      final token = gate.capture();
      final notifier = ref.read(remindersProvider.notifier);
      gate.check(token);
      await notifier.setTaskAttachmentLinked(task, id, linked, ticket);
      gate.check(token);
      _feedback(
        linked ? 'taskAttachmentAdded' : 'taskAttachmentRemoved',
        tone: FeedbackTone.success,
        undo: linked
            ? null
            : () {
                if (mounted) {
                  _link(id, true, generation: ticket);
                } else if (gate.isCurrent(token) && database.isCurrent(ticket)) {
                  unawaited(
                    notifier
                        .setTaskAttachmentLinked(task, id, true, ticket)
                        .then<void>((_) {}, onError: (Object _) {}),
                  );
                }
              },
      );
    } catch (_) {
      _feedback('taskAttachmentFailed', tone: FeedbackTone.error);
    } finally {
      _setBusy(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      remindersByIdProvider.select((byId) {
        final row = byId[widget.task.id];
        return row != null && row.isVisible ? row : null;
      }),
    );
    final task = current ?? widget.task;
    final ids = <String>{
      if (task.recordId != null) task.recordId!,
      ...task.details.attachmentIds,
    }.toList();
    final key = ids.join('\u0000');
    if (_readKey != key) {
      _readKey = key;
      _records = ref.read(taskAttachmentRecordsProvider)(ids);
    }
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled =
        current != null && widget.enabled && !widget.readOnly && !_busy;
    return Container(
      key: const ValueKey('task-attachments'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.get('taskAttachments'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!widget.readOnly)
            Text(
              l10n.get('taskAttachmentsHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          FutureBuilder<Map<String, MediaRecord>>(
            future: _records,
            builder: (context, snapshot) {
              if (ids.isEmpty) return const SizedBox.shrink();
              if (!snapshot.hasData && !snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(AppLocalizations.of(context).get('loading')),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final id in ids)
                      _AttachmentTile(
                        key: ValueKey('attachment-$id'),
                        media: snapshot.data?[id],
                        original: id == task.recordId,
                        store: ref.read(taskAttachmentPathProvider),
                        onRemove:
                            enabled && task.details.attachmentIds.contains(id)
                            ? () => _link(id, false)
                            : null,
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          if (!widget.readOnly)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('attach-photo'),
                  onPressed:
                      enabled &&
                          task.details.attachmentIds.length <
                              TaskDetails.maxAttachments
                      ? () => _add(true)
                      : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(l10n.get('taskAttachmentPhoto')),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('attach-file'),
                  onPressed:
                      enabled &&
                          task.details.attachmentIds.length <
                              TaskDetails.maxAttachments
                      ? () => _add(false)
                      : null,
                  icon: const Icon(Icons.note_add_outlined),
                  label: Text(l10n.get('taskAttachmentFile')),
                ),
              ],
            ),
          if (!widget.readOnly) const SizedBox(height: 8),
          if (!widget.readOnly)
            Text(
              l10n.get('taskAttachmentLimit'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _AttachmentTile extends StatefulWidget {
  const _AttachmentTile({
    super.key,
    required this.media,
    required this.original,
    required this.store,
    this.onRemove,
  });
  final MediaRecord? media;
  final bool original;
  final LocalMediaStore store;
  final VoidCallback? onRemove;
  @override
  State<_AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends State<_AttachmentTile> {
  Future<String?>? _path;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _AttachmentTile old) {
    super.didUpdateWidget(old);
    if (old.media?.contentOrPath != widget.media?.contentOrPath) _resolve();
  }

  void _resolve() {
    final media = widget.media;
    _path = media == null || media.type == 'text'
        ? Future.value(null)
        : widget.store.resolvePath(media.contentOrPath);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final media = widget.media;
    final name = media == null
        ? l10n.get('taskAttachmentUnavailable')
        : media.type == 'text'
        ? l10n.get('taskAttachmentOriginal')
        : path.basename(media.contentOrPath);
    return SizedBox(
      width: 148,
      child: FutureBuilder<String?>(
        future: _path,
        builder: (context, snapshot) {
          final resolved = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap:
                      media == null ||
                          (media.type != 'text' && resolved == null)
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TaskAttachmentPreview(
                              media: media,
                              resolvedPath: resolved,
                            ),
                          ),
                        ),
                  child: Semantics(
                    label: '${l10n.get('taskAttachmentPreview')}: $name',
                    button: true,
                    enabled:
                        media != null &&
                        (media.type == 'text' || resolved != null),
                    child: SizedBox(
                      height: 104,
                      child: media?.type == 'image' && resolved != null
                          ? Image.file(
                              File(resolved),
                              fit: BoxFit.cover,
                              cacheWidth: 384,
                              excludeFromSemantics: true,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image_outlined),
                            )
                          : Icon(
                              media == null
                                  ? Icons.broken_image_outlined
                                  : media.type == 'image'
                                  ? Icons.image_outlined
                                  : media.type == 'audio'
                                  ? Icons.audiotrack_outlined
                                  : media.type == 'video'
                                  ? Icons.videocam_outlined
                                  : Icons.description_outlined,
                              size: 30,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.original)
                Text(
                  l10n.get('taskAttachmentOriginal'),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              if (!widget.original)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: IconButton(
                    tooltip: '${l10n.get('taskAttachmentRemove')}: $name',
                    onPressed: widget.onRemove,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class TaskAttachmentPreview extends StatefulWidget {
  const TaskAttachmentPreview({
    super.key,
    required this.media,
    required this.resolvedPath,
  });
  final MediaRecord media;
  final String? resolvedPath;
  @override
  State<TaskAttachmentPreview> createState() => _TaskAttachmentPreviewState();
}

class _TaskAttachmentPreviewState extends State<TaskAttachmentPreview> {
  static const _maxPreviewBytes = 128 * 1024;
  static const _previewableTextExtensions = {
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.csv',
    '.tsv',
    '.log',
    '.yaml',
    '.yml',
    '.xml',
    '.ini',
    '.cfg',
    '.conf',
    '.toml',
    '.env',
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.html',
    '.css',
    '.sql',
    '.sh',
    '.ps1',
    '.bat',
  };

  bool _saving = false;
  Future<({String text, bool truncated})?>? _textPreview;
  Future<int?>? _fileSize;

  @override
  void initState() {
    super.initState();
    _loadPreviewMetadata();
  }

  @override
  void didUpdateWidget(covariant TaskAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolvedPath != widget.resolvedPath ||
        oldWidget.media.id != widget.media.id ||
        oldWidget.media.type != widget.media.type) {
      _textPreview = null;
      _fileSize = null;
      _loadPreviewMetadata();
    }
  }

  void _loadPreviewMetadata() {
    final filePath = widget.resolvedPath;
    if (filePath != null && widget.media.type != 'text') {
      _fileSize = _readFileSize(filePath);
    }
    _loadTextPreview();
  }

  static Future<int?> _readFileSize(String filePath) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) return null;
      return await f.length();
    } catch (_) {
      return null;
    }
  }

  void _loadTextPreview() {
    final filePath = widget.resolvedPath;
    if (widget.media.type != 'file' || filePath == null) return;
    final ext = path.extension(filePath).toLowerCase();
    final nameExt = path.extension(widget.media.contentOrPath).toLowerCase();
    if (!_previewableTextExtensions.contains(ext) &&
        !_previewableTextExtensions.contains(nameExt)) {
      return;
    }
    _textPreview = _readTextPreview(filePath);
  }

  static Future<({String text, bool truncated})?> _readTextPreview(
    String filePath,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final total = await file.length();
      if (total == 0) return (text: '', truncated: false);
      final readLen = total > _maxPreviewBytes ? _maxPreviewBytes : total;
      final raf = await file.open();
      final Uint8List bytes;
      try {
        bytes = await raf.read(readLen);
      } finally {
        await raf.close();
      }
      if (bytes.contains(0)) return null;
      final truncated = total > _maxPreviewBytes;
      final decoded = utf8.decode(bytes, allowMalformed: truncated);
      return (text: decoded, truncated: truncated);
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyText(String text) async {
    final l10n = AppLocalizations.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      final inline = context.findAncestorStateOfType<InlineFeedbackState>();
      if (inline != null) {
        inline.showSnackBar(
          SnackBar(content: Text(l10n.get('taskAttachmentTextCopied'))),
          tone: FeedbackTone.success,
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(l10n.get('taskAttachmentTextCopied'))),
        );
      }
    } catch (_) {}
  }

  Future<void> _saveCopy() async {
    if (_saving || widget.resolvedPath == null) return;
    setState(() => _saving = true);
    try {
      final file = File(widget.resolvedPath!);
      if (await file.length() > TaskAttachmentFiles.maxBytes) {
        throw const AttachmentTooLarge();
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final saved = await FilePicker.saveFile(
        fileName: path.basename(widget.media.contentOrPath),
        bytes: bytes,
      );
      if (mounted && saved != null) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('taskAttachmentSaved'),
            ),
          ),
          tone: FeedbackTone.success,
        );
      }
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('taskAttachmentUnavailable'),
            ),
          ),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final media = widget.media;
    final file = widget.resolvedPath;
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              media.type == 'text'
                  ? l10n.get('taskAttachmentOriginal')
                  : path.basename(media.contentOrPath),
            ),
            actions: [
              if (_fileSize != null)
                FutureBuilder<int?>(
                  future: _fileSize,
                  builder: (context, sizeSnap) {
                    final bytes = sizeSnap.data;
                    if (bytes == null) return const SizedBox.shrink();
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(
                          formatByteSize(bytes),
                          key: const ValueKey('attachment-preview-size'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
          body: SafeArea(
            child: FutureBuilder<({String text, bool truncated})?>(
              future: _textPreview,
              builder: (context, snapshot) {
                final textPreview = snapshot.data;
                return Column(
                  children: [
                    Expanded(
                      child: media.type == 'image' && file != null
                          ? Center(
                              child: InteractiveViewer(
                                minScale: 0.5,
                                maxScale: 4,
                                child: Image.file(
                                  File(file),
                                  semanticLabel: path.basename(file),
                                  fit: BoxFit.contain,
                                  cacheWidth: 2048,
                                  errorBuilder: (_, __, ___) => Text(
                                    l10n.get('taskAttachmentUnavailable'),
                                  ),
                                ),
                              ),
                            )
                          : textPreview != null
                          ? SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (textPreview.truncated)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: Text(
                                        l10n.get('taskAttachmentTextTruncated'),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  Container(
                                    key: const ValueKey(
                                      'attachment-text-preview',
                                    ),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color:
                                          theme.colorScheme.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: theme.colorScheme.outlineVariant,
                                      ),
                                    ),
                                    child: SelectableText(
                                      textPreview.text,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontFamily: 'monospace',
                                            height: 1.5,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(24),
                                child: SelectableText(
                                  media.type == 'text'
                                      ? media.contentOrPath
                                      : file == null
                                      ? l10n.get('taskAttachmentUnavailable')
                                      : l10n.get('taskAttachmentFileHint'),
                                ),
                              ),
                            ),
                    ),
                    if (file != null || textPreview != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            if (textPreview != null &&
                                textPreview.text.isNotEmpty)
                              OutlinedButton.icon(
                                key: const ValueKey('attachment-copy-text'),
                                onPressed: () => _copyText(textPreview.text),
                                icon: const Icon(Icons.copy_outlined),
                                label: Text(l10n.get('taskAttachmentCopyText')),
                              ),
                            if (file != null)
                              FilledButton.tonalIcon(
                                onPressed: _saving ? null : _saveCopy,
                                icon: const Icon(Icons.save_alt),
                                label: Text(l10n.get('taskAttachmentSaveCopy')),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
