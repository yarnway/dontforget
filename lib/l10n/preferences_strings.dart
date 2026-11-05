String preferencesText(String language, String key) {
  const labels = {
    'connection': ['高级连接配置', 'Advanced connection settings', '詳細な接続設定'],
    'common': ['常用偏好', 'Everyday preferences', '基本設定'],
    'features': ['功能与数据', 'Features and data', '機能とデータ'],
    'ai': ['AI 服务', 'AI services', 'AIサービス'],
    'aiHint': [
      '模型与录音转文字，按需配置',
      'Models and recording transcription, when needed',
      'モデルと録音文字起こしを必要に応じて設定',
    ],
    'notifications': ['通知与提醒', 'Notifications and reminders', '通知とリマインダー'],
    'notificationsHint': [
      '权限、提醒状态与诊断',
      'Permissions, delivery status and diagnostics',
      '権限・配信状態・診断',
    ],
    'sync': ['设备与同步', 'Devices and sync', 'デバイスと同期'],
    'syncHint': ['局域网同步与本地模型', 'LAN sync and local models', 'LAN同期とローカルモデル'],
    'protectionHint': [
      '备份、恢复与安全凭据',
      'Backups, recovery and secure credentials',
      'バックアップ・復元・認証情報',
    ],
    'contentHint': [
      '管理事项与原始附件',
      'Manage tasks and original attachments',
      'タスクと元の添付ファイルを管理',
    ],
    'conflict': [
      '偏好已在其他页面修改，请重新打开设置后再编辑。当前输入已保留。',
      'Preferences changed elsewhere. Reopen Settings before editing again. Your input is kept.',
      '設定が別画面で変更されました。設定を開き直してください。現在の入力は保持されています。',
    ],
  };
  return (labels[key] ?? labels['common']!)[switch (language) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  }];
}
