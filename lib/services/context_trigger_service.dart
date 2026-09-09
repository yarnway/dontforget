import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/reminder.dart';

/// 情境环境模式
enum ContextProfile {
  general,  // 通用默认模式
  office,   // 办公环境
  deepWork, // 深度高压专注
  home,     // 家庭生活
  commute,  // 移动通勤
}

/// 情境触发器定义规则
class ContextTriggerRule {
  final String type; // 'wifi' or 'profile'
  final String value; // SSID 名称或情境名称
  final String? prompt; // 附带的动作提示文案

  const ContextTriggerRule({
    required this.type,
    required this.value,
    this.prompt,
  });

  factory ContextTriggerRule.fromJson(Map<String, dynamic> json) => ContextTriggerRule(
        type: json['type'] as String? ?? 'wifi',
        value: json['value'] as String? ?? '',
        prompt: json['prompt'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'value': value,
        if (prompt != null) 'prompt': prompt,
      };

  String toJsonString() => jsonEncode(toJson());

  static ContextTriggerRule? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ContextTriggerRule.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }
}

/// 情境感知触发器与事后摘要服务 (Context-Aware Triggers & Catch-Up Digest)
class ContextTriggerService {
  static final ContextTriggerService _instance = ContextTriggerService._internal();
  factory ContextTriggerService() => _instance;
  ContextTriggerService._internal();

  ContextProfile _currentProfile = ContextProfile.general;
  ContextProfile get currentProfile => _currentProfile;

  String? _detectedSsid;
  String? get detectedSsid => _detectedSsid;

  /// 已触发过情境提醒的 Task ID 缓存（避免频繁打扰）
  final Set<String> _sessionTriggeredTaskIds = {};

  /// 专注情境下被拦截静音的次要任务队列（Q3 与 Q4）
  final List<Reminder> _suppressedReminders = [];
  List<Reminder> get suppressedReminders => List.unmodifiable(_suppressedReminders);

  final StreamController<ContextProfile> _profileController =
      StreamController<ContextProfile>.broadcast();
  Stream<ContextProfile> get onProfileChanged => _profileController.stream;

  final StreamController<List<Reminder>> _catchUpDigestController =
      StreamController<List<Reminder>>.broadcast();
  Stream<List<Reminder>> get onCatchUpDigestReady => _catchUpDigestController.stream;

  final StreamController<List<Reminder>> _suppressedUpdateController =
      StreamController<List<Reminder>>.broadcast();
  Stream<List<Reminder>> get onSuppressedUpdated => _suppressedUpdateController.stream;

  /// 切换当前情境环境
  void switchProfile(ContextProfile newProfile) {
    final oldProfile = _currentProfile;
    if (oldProfile == newProfile) return;

    _currentProfile = newProfile;
    _profileController.add(newProfile);
    debugPrint('📍 [ContextEngine] 情境切换: $oldProfile -> $newProfile');

    // 若从高压专注/办公环境退出到通用/家庭环境，自动生成事后摘要汇总
    if ((oldProfile == ContextProfile.deepWork || oldProfile == ContextProfile.office) &&
        (newProfile == ContextProfile.general || newProfile == ContextProfile.home)) {
      triggerCatchUpDigest();
    }
  }

  /// 触发事后摘要汇总 (Catch-Up Digest)
  void triggerCatchUpDigest() {
    if (_suppressedReminders.isEmpty) return;

    final digestList = List<Reminder>.from(_suppressedReminders);
    _suppressedReminders.clear();
    _suppressedUpdateController.add(const []);
    _catchUpDigestController.add(digestList);
    debugPrint('📋 [ContextEngine] 生成情境摘要汇总，共 ${digestList.length} 项次要事务');
  }

  /// 清空被拦截任务
  void clearSuppressed() {
    _suppressedReminders.clear();
    _suppressedUpdateController.add(const []);
  }

  /// 判定当前通知是否应当在情境下被底层拦截
  bool shouldInterceptNotification(Reminder reminder) {
    final isHighFocus =
        _currentProfile == ContextProfile.deepWork || _currentProfile == ContextProfile.office;
    if (isHighFocus && (reminder.quadrantLevel == 3 || reminder.quadrantLevel == 4)) {
      // 记录到拦截队列中待事后摘要
      if (!_suppressedReminders.any((r) => r.id == reminder.id)) {
        _suppressedReminders.add(reminder);
        _suppressedUpdateController.add(List.unmodifiable(_suppressedReminders));
      }
      return true;
    }
    return false;
  }

  /// 嗅探当前 Wi-Fi SSID (仅在 Windows 原生命令行执行 netsh，防卡顿超时处理)
  Future<String?> detectCurrentWifiSsid() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return null;
    try {
      final result = await Process.run(
        'netsh',
        ['wlan', 'show', 'interfaces'],
        runInShell: true,
      ).timeout(const Duration(seconds: 2));

      if (result.exitCode == 0) {
        final stdout = result.stdout.toString();
        final lines = stdout.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith('SSID') && !trimmed.startsWith('BSSID')) {
            final parts = trimmed.split(':');
            if (parts.length >= 2) {
              final ssid = parts.sublist(1).join(':').trim();
              if (ssid.isNotEmpty) {
                _detectedSsid = ssid;
                return ssid;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Wi-Fi SSID detection note: $e');
    }
    return null;
  }

  /// 扫描待办列表，匹配符合当前情境感知触发规则的任务
  List<Reminder> evaluateContextTriggers(List<Reminder> reminders, {String? ssid}) {
    final activeSsid = (ssid ?? _detectedSsid)?.toLowerCase();
    final currentProfileStr = _currentProfile.name.toLowerCase();

    final matched = <Reminder>[];

    for (final reminder in reminders) {
      if (reminder.isCompleted) continue;
      if (_sessionTriggeredTaskIds.contains(reminder.id)) continue;

      final rule = ContextTriggerRule.tryParse(reminder.contextTrigger);
      if (rule == null) continue;

      bool isMatch = false;

      if (rule.type == 'wifi' && activeSsid != null && rule.value.isNotEmpty) {
        if (activeSsid.contains(rule.value.toLowerCase())) {
          isMatch = true;
        }
      } else if (rule.type == 'profile' && rule.value.isNotEmpty) {
        if (rule.value.toLowerCase() == currentProfileStr) {
          isMatch = true;
        }
      }

      if (isMatch) {
        _sessionTriggeredTaskIds.add(reminder.id);
        matched.add(reminder);
        debugPrint('📍 [ContextEngine] 命中情境触发器: [${reminder.taskTitle}] (${rule.type}: ${rule.value})');
      }
    }

    return matched;
  }

  /// 清空本轮会话已触发的记录
  void resetSessionTriggers() {
    _sessionTriggeredTaskIds.clear();
  }
}
