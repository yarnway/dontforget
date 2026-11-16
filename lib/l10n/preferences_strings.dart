String preferencesText(String language, String key) {
  const labels = {
    'connection': ['高级连接配置', 'Advanced connection settings', '詳細な接続設定'],
    'common': ['常用偏好', 'Everyday preferences', '基本設定'],
    'features': ['功能与数据', 'Features and data', '機能とデータ'],
    'aboutHint': [
      '版本信息、检查更新与开源许可',
      'Version, updates and open-source licenses',
      'バージョン・更新・オープンソースライセンス',
    ],
    'ai': ['AI 服务', 'AI services', 'AIサービス'],
    'aiHint': [
      '模型服务与语音转写',
      'Model services and transcription',
      'モデルサービスと文字起こし',
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
      '备份、恢复与凭据管理',
      'Backups, recovery and credentials',
      'バックアップ・復元・認証情報管理',
    ],
    'contentHint': [
      '管理事项与原始附件',
      'Manage tasks and original attachments',
      'タスクと元の添付ファイルを管理',
    ],
    'conflict': [
      '设置已在其他页面更改。当前输入已保留，请重新打开后编辑。',
      'Settings changed elsewhere. Your input is kept. Reopen Settings to edit.',
      '設定が別画面で変更されました。入力は保持されています。設定を開き直してください。',
    ],
  };
  return (labels[key] ?? labels['common']!)[switch (language) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  }];
}
