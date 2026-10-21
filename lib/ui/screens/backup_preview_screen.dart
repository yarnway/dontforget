import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../services/recovery/backup_inspector.dart';

class BackupPreviewScreen extends StatefulWidget {
  const BackupPreviewScreen({super.key, this.inspector, this.pickPath});
  final BackupInspector? inspector;
  final Future<String?> Function()? pickPath;
  @override
  State<BackupPreviewScreen> createState() => _BackupPreviewScreenState();
}

class _BackupPreviewScreenState extends State<BackupPreviewScreen> {
  bool busy = false;
  BackupPreview? preview;
  String? error;
  String? fileName;
  Future<void> check() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final String? selected;
      if (widget.pickPath != null) {
        selected = await widget.pickPath!();
      } else {
        final result = await FilePicker.pickFile(dialogTitle: '选择备份以检查');
        selected = result?.path;
      }
      if (selected == null) return;
      if (mounted) {
        setState(() {
          preview = null;
          fileName = paths.basename(selected!);
        });
      }
      final result =
          await (widget.inspector ?? BackupInspector(databaseFactory)).inspect(
            File(selected),
          );
      if (mounted) setState(() => preview = result);
    } on FormatException catch (failure) {
      if (mounted) {
        setState(() {
          preview = null;
          error = failure.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          preview = null;
          error = '未能读取备份，请检查文件访问权限后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('检查备份')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '先了解备份，再决定恢复',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              '此步骤仅检查 JSON 快照或独立 SQLite 镜像，不修改当前数据。恢复执行将在后续阶段提供。支持 v7–v9，文件上限 64 MB。',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: busy ? null : check,
              icon: const Icon(Icons.folder_open),
              label: Text(busy ? '检查中…' : '选择备份'),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (fileName != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(fileName!),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (preview case final result?) ...[
              const SizedBox(height: 24),
              Text('结构检查通过', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text('数据版本 v${result.version}'),
              Text(
                result.timestamp == null
                    ? '镜像未记录快照时间'
                    : '快照时间：${result.timestamp!.toLocal()}',
              ),
              Text(
                '设置 ${result.counts['settings']} · 媒体索引 ${result.counts['media_records']} · 事项 ${result.counts['reminders']}',
              ),
              Text(
                '本机缺失附件：${result.missingMedia} · 未解析关联：${result.unresolvedReferences}',
              ),
              Text(
                result.containsCredentials
                    ? '包含 API 密钥；此备份未加密，请妥善保管。'
                    : '未检测到 API 密钥。',
              ),
              const SizedBox(height: 16),
              const Text('备份只包含附件路径，不包含录音、图片或文件本体。结构通过不代表附件齐全，也不代表恢复已经完成。'),
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('文件校验摘要'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText('SHA-256\n${result.digest}'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
