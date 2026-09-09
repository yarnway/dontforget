import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/reminder.dart';

/// 大数据序列导出分析服务
///
/// 导出包含 16 维结构化分析字段的 RFC 4180 CSV（带 UTF-8 BOM `\uFEFF`），
/// 原生完美兼容 Windows Excel 2019/2021/365 及 WPS，支持一键插入数据透视表 (Pivot Table)。
class DataExportService {
  const DataExportService();

  /// 16 维结构化字段表头
  static const List<String> csvHeaders = [
    '任务ID (Task ID)',
    '任务标题 (Title)',
    '详细描述 (Description)',
    '四象限分类 (Quadrant Name)',
    '象限层级 (Quadrant Level)',
    '当前状态 (Status)',
    '截止时间 (Due DateTime)',
    '截止年份 (Due Year)',
    '截止月份 (Due Month)',
    '截止星期 (Due Weekday)',
    '提前提醒分钟 (Advance Notice Min)',
    '循环模式 (Recurrence)',
    '艾宾浩斯复习阶梯 (Review Level 0-5)',
    '下次复习时间 (Next Review At)',
    '长期停滞预警 (Stagnation Warning)',
    '32位状态位掩码 (Bitmask Hex)',
  ];

  /// 生成符合 RFC 4180 标准并带有 UTF-8 BOM 的 CSV 字符串
  String generateCsvContent(List<Reminder> tasks, {String locale = 'zh'}) {
    final buffer = StringBuffer();
    // 写入 UTF-8 BOM 字符，确保 Windows Excel 2019+ 打开绝不出现乱码
    buffer.write('\uFEFF');

    // 写入表头
    buffer.writeln(_buildCsvRow(csvHeaders));

    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final monthFormat = DateFormat('yyyy-MM');
    final isEn = locale.startsWith('en');

    for (final task in tasks) {
      final isOverdue = task.isOverdue;
      final status = task.isCompleted
          ? '已完成'
          : (isOverdue ? '已逾期' : '进行中');

      final quadrantName = _getQuadrantName(task.quadrantLevel);
      final dueTime = task.triggerTime;
      final dueStr = dueTime != null ? dateFormat.format(dueTime) : '未设置';
      final yearStr = dueTime != null ? dueTime.year.toString() : '未设置';
      final monthStr = dueTime != null ? monthFormat.format(dueTime) : '未设置';
      final weekdayStr = dueTime != null ? _getWeekdayName(dueTime, isEn: isEn) : '未设置';
      final nextReviewStr = task.nextReviewAt != null
          ? dateFormat.format(task.nextReviewAt!)
          : '无';
      final stagnationStr = task.isStagnant() ? '是' : '否';
      final bitmaskHex = '0x${task.bitmask.toRadixString(16).padLeft(8, '0').toUpperCase()}';

      final List<String> rowValues = [
        task.id,
        task.taskTitle,
        task.taskSummary ?? '',
        quadrantName,
        task.quadrantLevel.toString(),
        status,
        dueStr,
        yearStr,
        monthStr,
        weekdayStr,
        task.urgencyLevel ?? '常规',
        task.recurrenceDescription ?? task.recurrenceRule ?? '无',
        task.spacedRepetitionLevel.toString(),
        nextReviewStr,
        stagnationStr,
        bitmaskHex,
      ];

      buffer.writeln(_buildCsvRow(rowValues));
    }

    return buffer.toString();
  }

  /// 导出为本地文件，默认保存在用户 Documents 目录
  Future<File> exportToFile(
    List<Reminder> tasks, {
    String? customDirectory,
    String? filename,
    String locale = 'zh',
  }) async {
    final directoryPath = customDirectory ?? await _getDefaultExportDirectory();
    final name = filename ??
        'DontForget_Export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
    final targetPath = p.join(directoryPath, name);

    final csvContent = generateCsvContent(tasks, locale: locale);
    final file = File(targetPath);
    await file.writeAsString(csvContent, encoding: utf8);
    return file;
  }

  Future<String> _getDefaultExportDirectory() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final exportDir = Directory(p.join(docDir.path, 'DontForget_Exports'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return exportDir.path;
    } catch (_) {
      return Directory.current.path;
    }
  }

  String _getWeekdayName(DateTime date, {bool isEn = false}) {
    const zhDays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    const enDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final idx = (date.weekday - 1).clamp(0, 6);
    return isEn ? enDays[idx] : zhDays[idx];
  }

  String _getQuadrantName(int level) {
    switch (level) {
      case 1:
        return '重要且紧急 (Q1)';
      case 2:
        return '重要不紧急 (Q2)';
      case 3:
        return '紧急不重要 (Q3)';
      case 4:
        return '不重要不紧急 (Q4)';
      default:
        return '普通事项';
    }
  }

  String _buildCsvRow(List<String> values) {
    return values.map(_escapeCsvCell).join(',');
  }

  String _escapeCsvCell(String input) {
    // 若包含逗号、双引号或换行符，需双引号包裹并将内部双引号转义为双个双引号
    if (input.contains(',') ||
        input.contains('"') ||
        input.contains('\n') ||
        input.contains('\r')) {
      return '"${input.replaceAll('"', '""')}"';
    }
    return input;
  }
}
