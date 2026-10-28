import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

String routineText(BuildContext context, String key) {
  final l = AppLocalizations.of(context).locale.languageCode;
  final v = _strings[key];
  return v == null
      ? key
      : v[l == 'zh'
            ? 0
            : l == 'ja'
            ? 2
            : 1];
}

const _strings = <String, List<String>>{
  'independent': [
    '按日期独立提醒（未来60天）',
    'Independent dates (next 60 days)',
    '日付ごとに独立（60日先まで）',
  ],
  'independentHint': [
    '漏做、跳过或延后某一天不会改变其他日期。旧周期的逾期、延后或已确认事项需先处理，再转换。',
    'Missed, skipped or snoozed dates do not move other dates. Resolve a legacy overdue, snoozed or acknowledged date before converting.',
    '未完了・スキップ・延期は他の日に影響しません。既存の延期を処理してから切替えます。',
  ],
  'holiday': ['节假日规则', 'Holiday rule', '祝日ルール'],
  'none': ['按原星期与日期', 'Use existing weekdays and dates', '元の曜日・日付に従う'],
  'skip_holidays': ['避开已公布放假日', 'Skip published days off', '公表済みの休日を除外'],
  'workdays': [
    '按日历工作日及调休（周一至周五为基础）',
    'Calendar workdays and make-up days (Mon–Fri base)',
    '日程の営業日・振替出勤日（月〜金が基本）',
  ],
  'calendarHint': [
    '默认不启用。内置中国大陆2026年放假与调休；其他地区／年份可导入日历。未覆盖日期暂停新增提醒，明确额外日期优先。',
    'Off by default. Includes mainland China 2026 arrangements. Import other regions/years. Uncovered dates wait for calendar data; explicit extra dates take priority.',
    '初期設定は無効。中国本土2026年の休日・振替を収録。他の地域・年は読込できます。未収録日は追加を保留し、明示した追加日を優先します。',
  ],
  'calendarSource': ['日历来源及覆盖', 'Calendar source and coverage', '出典と収録期間'],
  'calendarImport': ['导入日历 JSON', 'Import calendar JSON', '日程JSONを読込'],
  'calendarInvalid': [
    '日历格式、来源、覆盖或日期无效。',
    'Invalid calendar format, source, coverage or dates.',
    '形式・出典・期間・日付が無効です。',
  ],
  'calendarMissing': [
    '部分未来日期没有日历资料，等待更新。',
    'Calendar data is missing for some future dates.',
    '一部の将来日程が未収録です。',
  ],
  'location': ['获取一次当前位置', 'Use current location once', '現在地を一度取得'],
  'locationHint': [
    '仅点击后请求系统授权并获取一次约略坐标。确认采用后才保存到计划；后台不读取位置，天气请求使用已确认地点。',
    'Only this action requests permission and one approximate position. Confirm before saving to the plan. Background weather uses the confirmed place without reading location.',
    '操作時のみ許可を求め、概略位置を一度取得します。確認後に計画へ保存。バックグラウンドの天気は保存地点を使用し、位置取得は行いません。',
  ],
  'available': [
    '已取得约略位置，请确认采用。',
    'Approximate position ready for confirmation.',
    '概略位置を確認して採用してください。',
  ],
  'denied': [
    '未允许定位，可继续手动选择城市。',
    'Location denied; choose a city manually.',
    '位置情報が拒否されました。都市を手動で選べます。',
  ],
  'deniedForever': [
    '系统已拒绝定位，可打开设置修复。',
    'Location blocked; open settings to repair.',
    '位置情報が無効です。設定を開いて修正できます。',
  ],
  'disabled': [
    '系统定位服务未开启。',
    'System location services are off.',
    'システムの位置情報サービスが無効です。',
  ],
  'unsupported': [
    '此平台定位不可用，请手动选择城市。',
    'Location unavailable here; select a city manually.',
    'この環境で位置を取得できません。都市を選択してください。',
  ],
  'failed': [
    '未取得有效位置，请重试或选择城市。',
    'No valid position; retry or choose a city.',
    '有効な位置を取得できません。再試行または都市選択してください。',
  ],
  'settingsUnavailable': [
    '无法打开定位设置，请到系统设置手动调整。',
    'Could not open location settings; adjust them in system settings.',
    '位置情報の設定を開けません。システム設定で変更してください。',
  ],
  'settings': ['打开定位设置', 'Open location settings', '位置情報の設定を開く'],
  'approximate': ['当前位置（约略）', 'Current place (approximate)', '現在地（概略）'],
  'apply': ['采用到计划草稿', 'Use in plan draft', '計画の下書きに適用'],
  'background': [
    '允许应用仍运行时在后台刷新天气',
    'Allow background weather while the app is running',
    'アプリ実行中のバックグラウンド天気更新',
  ],
  'backgroundHint': [
    '默认仅前台刷新。开启后仅使用保存地点，冷却／失败退避仍生效。系统可能挂起或结束应用；不能保证关闭后刷新。已提交提醒继续使用基础清单，恢复前台会补排并修正天气。',
    'Foreground only by default. Opt-in uses the saved place with cooldown/backoff. The OS may suspend or stop the app; closed-app refresh is not guaranteed. Submitted reminders retain base items; resume replenishes dates and weather.',
    '初期設定は前面のみ。許可後も保存地点と待機・再試行間隔を使用します。OS停止後の更新は保証されません。予約通知は基本リストを保持し、復帰時に日程と天気を補います。',
  ],
  'preview': ['预览', 'Preview', 'プレビュー'],
  'cancel': ['取消', 'Cancel', 'キャンセル'],
  'confirm': ['确认', 'Confirm', '確認'],
  'seriesOwner': ['周期计划', 'Recurring plan', '繰返し計画'],
  'schedule_replaced': ['未来安排已替换', 'Future schedule replaced', '将来の予定を更新'],
};
