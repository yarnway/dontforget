import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import 'inline_feedback.dart';

const _filePreviewMaxBytes = 128 * 1024;

Future<({String text, bool truncated})?> readBoundedWorkspaceTextPreview(
  String filePath,
) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final raf = await file.open();
    final Uint8List raw;
    try {
      raw = await raf.read(_filePreviewMaxBytes + 1);
    } finally {
      await raf.close();
    }
    if (raw.isEmpty) return null;
    final truncated = raw.length > _filePreviewMaxBytes;
    final slice = truncated ? raw.sublist(0, _filePreviewMaxBytes) : raw;
    if (slice.contains(0)) return null;
    final decoded = utf8.decode(slice, allowMalformed: truncated);
    if (decoded.trim().isEmpty) return null;
    return (text: decoded, truncated: truncated);
  } catch (_) {
    return null;
  }
}

Future<void> showWorkspaceImagePreviewDialog(
  BuildContext context,
  String filePath,
) {
  final l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              InteractiveViewer(
                maxScale: 4.0,
                child: Image.file(
                  File(filePath),
                  cacheWidth: 2048,
                  semanticLabel: p.basename(filePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(l10n.get('cannotLoadImage')),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton(
                  tooltip: l10n.get('close'),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> showWorkspaceFilePreviewDialog(
  BuildContext context,
  String filePath, {
  required bool Function() isActive,
}) {
  final l10n = AppLocalizations.of(context);
  final colors = Theme.of(context).colorScheme;
  final fileName = p.basename(filePath);
  final previewFuture = readBoundedWorkspaceTextPreview(filePath);
  final feedback = InlineFeedback.of(context);

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.description_outlined, color: colors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fileName,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<({String text, bool truncated})?>(
          future: previewFuture,
          builder: (dialogCtx, snapshot) {
            final preview = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.get('localPath')}: $filePath',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const Divider(height: 18),
                if (snapshot.connectionState != ConnectionState.done)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.get('loading')),
                      ],
                    ),
                  )
                else if (preview != null) ...[
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${l10n.get('contentPreview')}:',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('home-file-preview-copy'),
                        onPressed: () async {
                          try {
                            await Clipboard.setData(
                              ClipboardData(text: preview.text),
                            );
                            if (isActive() && feedback.mounted) {
                              feedback.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.get('taskAttachmentTextCopied'),
                                  ),
                                ),
                                tone: FeedbackTone.success,
                              );
                            }
                          } catch (_) {
                            if (isActive() && feedback.mounted) {
                              feedback.showSnackBar(
                                SnackBar(
                                  content: Text(l10n.get('operationFailed')),
                                ),
                                tone: FeedbackTone.error,
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: Text(l10n.get('taskAttachmentCopyText')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 240),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.45,
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        preview.text,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  if (preview.truncated) ...[
                    const SizedBox(height: 6),
                    Text(
                      l10n.get('taskAttachmentTextTruncated'),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ] else
                  Text(
                    l10n.get('binaryFileNotice'),
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.get('close'), style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

Future<void> openWorkspaceVideoExternally(
  BuildContext context,
  String filePath, {
  required bool Function() isActive,
}) async {
  final l10n = AppLocalizations.of(context);
  final feedback = InlineFeedback.of(context);
  final fileName = p.basename(filePath);
  var launched = false;
  try {
    final file = File(filePath);
    if (await file.exists()) {
      launched = await launchUrl(
        Uri.file(filePath),
        mode: LaunchMode.externalApplication,
      );
    }
  } catch (_) {
    launched = false;
  }
  if (!isActive() || !feedback.mounted) return;
  feedback.hideCurrentSnackBar();
  feedback.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      content: Text(
        launched
            ? '${l10n.get('openedVideo')}: $fileName'
            : l10n.get('videoOpenFailed'),
      ),
    ),
    tone: launched ? FeedbackTone.info : FeedbackTone.error,
  );
}
