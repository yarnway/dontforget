import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

String routineText(BuildContext context, String key) {
  final l = AppLocalizations.of(context).locale.languageCode;
  return routinePolicyText(l, key);
}

String routinePolicyText(String l, String key) {
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
  ..._extendedStrings,
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

const _extendedStrings = <String, List<String>>{
  'captureNeedsPlan': [
    '原文已保存；这个周期还不够明确，请在计划管理中设置后启用提醒。',
    'Source saved. Configure this unclear recurrence in plan management before enabling reminders.',
    '原文を保存しました。不明確な繰返しは計画管理で設定してから通知を有効にしてください。',
  ],
  'calendarChangeRegion': [
    '将切换地区并替换本计划的日历资料；历史日期与操作记录保留。',
    'Switch region and replace this plan’s calendar. Historical dates and action records remain.',
    '地域と計画の日程資料を切替えます。過去の日程と操作履歴は保持します。',
  ],
  'calendarUpdatePreview': ['预览日历更新', 'Preview calendar update', '日程更新の確認'],
  'calendarReplaceCoverage': [
    '替换重叠区间的资料，保留其他年份。计划保存后仅更新未处理的未来安排。',
    'Replace overlapping coverage and keep other years. Saving the plan updates only untouched future dates.',
    '重複期間の資料を更新し、他の年は保持。保存後は未処理の将来日程のみ更新します。',
  ],
  'calendarKeepYears': [
    '保留已有年份并补充新覆盖。每份资料保留自己的来源；空缺日期继续等待更新。',
    'Keep existing years and add coverage. Each snapshot retains its source; gaps still wait for data.',
    '既存の年と出典を保持して期間を追加。未収録日は更新を待ちます。',
  ],
  'calendarUnverifiedSource': [
    '导入来源由你核对，不会自动访问网址；最多保留4份资料。',
    'Verify imported sources yourself; URLs are not fetched. Up to four snapshots.',
    '出典をご確認ください。URLへの自動接続はせず、資料は最大4件です。',
  ],
  'calendarFile': ['从文件导入更新', 'Import update from file', 'ファイルから更新'],
  'calendarExport': ['导出当前日历', 'Export current calendar', '現在の日程を出力'],
  'datesTitle': ['日期与记录', 'Dates and records', '日程と記録'],
  'date_past': ['历史及今日', 'Past and today', '過去と今日'],
  'date_future': ['今日及以后', 'Today and future', '今日以降'],
  'date_all': ['全部', 'All', 'すべて'],
  'date_pending': ['待处理', 'Unprocessed', '未処理'],
  'date_handled': ['已处理', 'Handled', '処理済み'],
  'date_removed': ['已移除', 'Removed', '除外済み'],
  'dateStatus': ['状态', 'Status', '状態'],
  'dateSearch': ['搜索标题或日期', 'Search title or date', '件名・日付を検索'],
  'dateFrom': ['开始日期', 'From', '開始日'],
  'dateTo': ['结束日期', 'To', '終了日'],
  'dateClear': ['清除日期筛选', 'Clear date range', '期間を解除'],
  'dateCount': ['符合条件的日期', 'Matching dates', '該当する日程'],
  'dateMore': ['显示更多日期', 'Show more dates', 'さらに表示'],
  'dateEmpty': [
    '没有符合条件的日期；未打开期间不会补造完成记录。',
    'No matching dates. Time away never fabricates completion records.',
    '該当日程はありません。不在中の完了記録は作成されません。',
  ],
  'dateUnavailable': [
    '当前计划不可用，请返回后重开。',
    'Plan unavailable; return and reopen.',
    '計画を利用できません。戻って開き直してください。',
  ],
  'dateMedicationReadOnly': [
    '用药日期在此只读；请在用药计划中核对并登记实际服药情况。',
    'Medication dates are read-only here. Review actual dose outcomes in the medication plan.',
    '服薬日は閲覧のみです。実際の服薬結果は服薬計画で確認・記録してください。',
  ],
  'dateParentInactive': [
    '计划已暂停或移除，先在计划中恢复后再操作单日。',
    'Resume or restore the plan before editing a date.',
    '計画を再開・復元してから個別の日程を操作してください。',
  ],
  'dateScheduled': ['原安排', 'Original schedule', '元の予定'],
  'dateAlarm': ['当前提醒', 'Current alarm', '現在の通知'],
  'dateEvent': ['事项时间', 'Event time', '予定時刻'],
  'dateSnoozed': ['已延后至', 'Snoozed until', '延期先'],
  'dateHistory': ['操作记录', 'Action history', '操作履歴'],
  'date_complete': ['标为完成', 'Mark complete', '完了にする'],
  'date_skip': ['跳过这一天', 'Skip this date', 'この日をスキップ'],
  'date_reopen': ['重新打开', 'Reopen', '未完了に戻す'],
  'date_trash': ['移除这一天', 'Remove this date', 'この日を除外'],
  'date_restore': ['恢复这一天', 'Restore this date', 'この日を復元'],
  'dateActionHint': [
    '只修改这个日期，保留原安排与实际操作时间；其他日期不变。过去的安排不会重新响铃。',
    'Only this date changes. Original schedule and action time are retained. Past alarms will not ring again.',
    'この日のみ変更し、元の予定と操作日時を保持します。過去の通知は再送しません。',
  ],
  'dateStale': [
    '计划或日期已变化，请核对最新记录后重试。',
    'Plan or date changed; review the latest record and retry.',
    '日程が変更されています。最新の記録を確認してください。',
  ],
  'dateNativeFailed': [
    '日期已保存，部分通知需要修复。',
    'Date saved; some notifications need repair.',
    '日程は保存されました。通知の修復が必要です。',
  ],
  'dateRepair': ['修复提醒', 'Repair notifications', '通知を修復'],
  'dateShowAllPlans': ['查看全部计划', 'Show all plans', 'すべての計画を表示'],
  'manageCapturedPlan': ['管理周期与日期', 'Manage recurrence and dates', '繰返しと日程を管理'],
};
