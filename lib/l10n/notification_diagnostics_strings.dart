const notificationDiagnosticsStrings = <String, Map<String, String>>{
  'en': {
    'notificationDiagnosticsTitle': 'Notification self-check',
    'notificationDiagnosticsPending': 'System scheduled notifications: {count}',
    'notificationDiagnosticsUnavailable': 'Temporarily unavailable',
    'notificationDiagnosticsPermission': 'Permission: {status}',
    'notificationDiagnosticsRepair': 'Pending repair: {count}',
    'notificationDiagnosticsFailure': 'Latest recorded failure: {time}',
    'notificationDiagnosticsNoFailure': 'No failure in the current journal',
    'notificationDiagnosticsTest': 'Send test notification',
    'notificationDiagnosticsTestTitle': '[TEST] DontForget notification',
    'notificationDiagnosticsTestBody':
        'This is a notification self-check. No task was created or changed.',
    'notificationDiagnosticsSubmitted': 'Submitted to system',
    'notificationDiagnosticsDenied':
        'Notifications are not enabled. Check system permission and try again.',
    'notificationDiagnosticsFailed':
        'Could not submit the test notification. Check permission and try again.',
    'notificationDiagnosticsDeliveryHint':
        'The test is scheduled for 5 seconds from now. Actual delivery depends on system permission, Focus mode and platform scheduling.',
    'notificationDiagnosticsRuntimeHint':
        'Native scheduled notifications are unavailable on this platform. Keep the app running for in-app reminders; this does not repair system notifications.',
  },
  'zh': {
    'notificationDiagnosticsTitle': '通知自检',
    'notificationDiagnosticsPending': '系统已安排通知：{count}',
    'notificationDiagnosticsUnavailable': '暂不可用',
    'notificationDiagnosticsPermission': '权限：{status}',
    'notificationDiagnosticsRepair': '待修复：{count}',
    'notificationDiagnosticsFailure': '最近一次记录的失败：{time}',
    'notificationDiagnosticsNoFailure': '当前通知日志没有失败记录',
    'notificationDiagnosticsTest': '发送测试通知',
    'notificationDiagnosticsTestTitle': '【测试】DontForget 通知',
    'notificationDiagnosticsTestBody': '这是一条通知自检消息，未创建或修改任务。',
    'notificationDiagnosticsSubmitted': '已提交系统',
    'notificationDiagnosticsDenied': '通知尚未开启，请检查系统权限后重试。',
    'notificationDiagnosticsFailed': '测试通知未能提交，请检查权限后重试。',
    'notificationDiagnosticsDeliveryHint':
        '测试通知计划于 5 秒后投递，实际送达取决于系统权限、专注模式和平台调度。',
    'notificationDiagnosticsRuntimeHint':
        '此平台暂不支持原生定时通知。应用需保持运行才能显示应用内提醒；这不代表系统通知已修复。',
  },
  'ja': {
    'notificationDiagnosticsTitle': '通知のセルフチェック',
    'notificationDiagnosticsPending': 'システムの通知予定：{count}',
    'notificationDiagnosticsUnavailable': '現在取得できません',
    'notificationDiagnosticsPermission': '権限：{status}',
    'notificationDiagnosticsRepair': '要修復：{count}',
    'notificationDiagnosticsFailure': '直近の失敗記録：{time}',
    'notificationDiagnosticsNoFailure': '現在の通知ログに失敗記録はありません',
    'notificationDiagnosticsTest': 'テスト通知を送信',
    'notificationDiagnosticsTestTitle': '【テスト】DontForget 通知',
    'notificationDiagnosticsTestBody': '通知のセルフチェックです。タスクは作成・変更されません。',
    'notificationDiagnosticsSubmitted': 'システムに送信しました',
    'notificationDiagnosticsDenied': '通知が無効です。システムの権限を確認して再試行してください。',
    'notificationDiagnosticsFailed': 'テスト通知を送信できませんでした。権限を確認して再試行してください。',
    'notificationDiagnosticsDeliveryHint':
        '5 秒後の通知を予約します。実際の表示はシステム権限、集中モード、各プラットフォームの処理に依存します。',
    'notificationDiagnosticsRuntimeHint':
        'この環境はネイティブの時刻指定通知に対応していません。アプリ内リマインダーにはアプリの起動が必要です。システム通知の修復を意味しません。',
  },
};
