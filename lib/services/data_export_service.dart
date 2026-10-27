import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/reminder.dart';

/// Analysis CSV only: no credentials, settings, attachment bodies or restore data.
class DataExportService {
  const DataExportService();
  static const csvHeaders = [
    '任务ID (Task ID)',
    '任务标题 (Title)',
    '详细描述 (Description)',
    '四象限分类 (Quadrant Name)',
    '象限层级 (Quadrant Level)',
    '当前状态 (Status)',
    '本地提醒时间 (Reminder DateTime)',
    '提醒年份 (Reminder Year)',
    '提醒月份 (Reminder Month)',
    '提醒星期 (Reminder Weekday)',
    '紧急程度 (Urgency)',
    '循环模式 (Recurrence)',
    '复习阶梯 (Review Level 0-5)',
    '本地下次复习时间 (Next Review At)',
    '长期停滞预警 (Stagnation Warning)',
    '32位状态位掩码 (Bitmask Hex)',
    '本地事项截止时间 (Deadline DateTime)',
  ];
  static const _headers = {
    'zh': csvHeaders,
    'en': [
      'Task ID',
      'Title',
      'Description',
      'Quadrant Name',
      'Quadrant Level',
      'Status',
      'Reminder DateTime (local)',
      'Reminder Year',
      'Reminder Month',
      'Reminder Weekday',
      'Urgency',
      'Recurrence',
      'Review Level (0-5)',
      'Next Review At (local)',
      'Stagnation Warning',
      'Bitmask Hex',
      'Deadline DateTime (local)',
    ],
    'ja': [
      'タスクID',
      'タイトル',
      '説明',
      '分類',
      '象限レベル',
      '状態',
      '通知時刻（ローカル）',
      '通知の年',
      '通知の月',
      '通知の曜日',
      '緊急度',
      '繰り返し',
      '復習レベル（0-5）',
      '次の復習（ローカル時刻）',
      '長期停滞',
      'ビットマスク（16進数）',
      'タスク期限（ローカル）',
    ],
  };
  static const _labels = {
    'zh': [
      '已完成',
      '提醒时间已过',
      '进行中',
      '是',
      '否',
      '重要且紧急 (Q1)',
      '重要不紧急 (Q2)',
      '紧急不重要 (Q3)',
      '不重要不紧急 (Q4)',
      '普通事项',
    ],
    'en': [
      'Completed',
      'Reminder time passed',
      'In progress',
      'Yes',
      'No',
      'Important and urgent (Q1)',
      'Important, not urgent (Q2)',
      'Urgent, not important (Q3)',
      'Neither important nor urgent (Q4)',
      'Task',
    ],
    'ja': [
      '完了',
      '通知時刻を経過',
      '進行中',
      'はい',
      'いいえ',
      '重要・緊急 (Q1)',
      '重要・緊急ではない (Q2)',
      '緊急・重要ではない (Q3)',
      '重要でも緊急でもない (Q4)',
      'タスク',
    ],
  };
  String _known(String? input, String language) {
    const values = {
      'urgent': ['Urgent', '紧急', '緊急'],
      'general': ['General', '常规', '通常'],
      'not urgent': ['Not urgent', '不紧急', '緊急ではない'],
      'none': ['None', '无', 'なし'],
      'daily': ['Daily', '每天', '毎日'],
      'workday': ['Workdays', '工作日', '平日'],
      'weekly': ['Weekly', '每周', '毎週'],
      'monthly': ['Monthly', '每月', '毎月'],
      'yearly': ['Yearly', '每年', '毎年'],
    };
    return values[input?.toLowerCase().replaceAll('_', ' ')]?[language == 'zh'
            ? 1
            : language == 'ja'
            ? 2
            : 0] ??
        input ??
        '';
  }

  String _language(String locale) => locale.startsWith('zh')
      ? 'zh'
      : locale.startsWith('ja')
      ? 'ja'
      : 'en';
  Iterable<String> _lines(
    List<Reminder> tasks,
    String locale,
    DateTime now,
  ) sync* {
    final language = _language(locale), labels = _labels[_language(locale)]!;
    final date = DateFormat('yyyy-MM-dd HH:mm:ss');
    yield '\uFEFF${_row(_headers[language]!)}\r\n';
    for (final task in tasks) {
      final due = task.triggerTime?.toLocal();
      final overdue = !task.isCompleted && due != null && due.isBefore(now);
      final stagnant =
          !task.isCompleted &&
          task.quadrantLevel == 2 &&
          task.createdAt != null &&
          now.difference(task.createdAt!).inHours >= 24;
      final mask =
          (task.bitmask & ~(TaskBitmask.overdue | TaskBitmask.stagnant)) |
          (overdue ? TaskBitmask.overdue : 0) |
          (stagnant ? TaskBitmask.stagnant : 0);
      final days = switch (language) {
        'zh' => const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'],
        'ja' => const ['月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日', '日曜日'],
        _ => const [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ],
      };
      yield '${_row([task.id, task.taskTitle, task.taskSummary ?? '', task.quadrantLevel >= 1 && task.quadrantLevel <= 4 ? labels[4 + task.quadrantLevel] : labels[9], '${task.quadrantLevel}', labels[task.isCompleted
          ? 0
          : overdue
          ? 1
          : 2], due == null ? '' : date.format(due), due == null ? '' : '${due.year}', due == null ? '' : '${due.year}-${due.month.toString().padLeft(2, '0')}', due == null ? '' : days[due.weekday - 1], _known(task.urgencyLevel, language), task.recurrenceDescription ?? _known(task.recurrenceRule, language), '${task.spacedRepetitionLevel}', task.nextReviewAt == null ? '' : date.format(task.nextReviewAt!.toLocal()), labels[stagnant ? 3 : 4], '0x${mask.toRadixString(16).padLeft(8, '0').toUpperCase()}', task.eventTime == null ? '' : date.format(task.eventTime!.toLocal())])}\r\n';
    }
  }

  String generateCsvContent(
    List<Reminder> tasks, {
    String locale = 'zh',
    DateTime? now,
  }) => _lines(tasks, locale, now ?? DateTime.now()).join();
  Future<Uri?> saveWithDialog(
    List<Reminder> tasks, {
    required String locale,
    required String title,
    bool Function()? isCurrent,
  }) async {
    final snapshot = List<Reminder>.unmodifiable(tasks);
    final now = DateTime.now();
    final bytes = snapshot.length >= 1000
        ? await Isolate.run(() => _encode(snapshot, locale, now))
        : _encode(snapshot, locale, now);
    if (isCurrent != null && !isCurrent()) return null;
    return FilePicker.saveFile(
      fileName: _filename(),
      bytes: bytes,
      mimeType: 'text/csv',
      dialogTitle: title,
    );
  }

  static Uint8List _encode(List<Reminder> tasks, String locale, DateTime now) =>
      Uint8List.fromList(
        utf8.encode(
          const DataExportService().generateCsvContent(
            tasks,
            locale: locale,
            now: now,
          ),
        ),
      );
  String _filename() =>
      'DontForget_Export_${DateTime.now().microsecondsSinceEpoch}.csv';
  Future<File> exportToFile(
    List<Reminder> tasks, {
    String? customDirectory,
    String? filename,
    String locale = 'zh',
  }) async {
    final directory = customDirectory == null
        ? Directory(
            p.join(
              (await getApplicationDocumentsDirectory()).path,
              'DontForget_Exports',
            ),
          )
        : Directory(customDirectory);
    await directory.create(recursive: true);
    final name = filename ?? _filename();
    if (p.basename(name) != name || !name.toLowerCase().endsWith('.csv')) {
      throw ArgumentError('Invalid CSV filename');
    }
    final file = File(p.join(directory.path, name));
    await file.create(exclusive: true); // Never overwrite an earlier export.
    final sink = file.openWrite(encoding: utf8);
    try {
      var count = 0;
      for (final line in _lines(tasks, locale, DateTime.now())) {
        sink.write(line);
        if (++count % 256 == 0) await sink.flush();
      }
      await sink.flush();
      await sink.close();
      return file;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      await file.delete();
      rethrow;
    }
  }

  static final _formula = RegExp(r'^[\s\x00-\x1f]*[=+\-@]');
  static final _quote = RegExp('[,"\r\n]');
  String _row(List<String> fields) => fields
      .map((input) {
        // Spreadsheet software can interpret text as a formula even when CSV quoted.
        final value =
            _formula.hasMatch(input) ||
                input.startsWith('\t') ||
                input.startsWith('\r') ||
                input.startsWith('\n')
            ? "'$input"
            : input;
        return value.contains(_quote)
            ? '"${value.replaceAll('"', '""')}"'
            : value;
      })
      .join(',');
}
