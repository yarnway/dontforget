String globalCaptureText(String language, String key) {
  const labels = {
    'title': ['全局快捷记录', 'Global capture shortcut', 'グローバル入力ショートカット'],
    'hint': [
      '应用运行时，Ctrl+Alt+Space 唤起窗口并聚焦首页输入；已有编辑内容保留。',
      'While the app is running, Ctrl+Alt+Space opens its window and focuses the home input. Existing edits are kept.',
      'アプリ起動中、Ctrl+Alt+Spaceでウィンドウとホーム入力を開きます。編集中の内容は保持されます。',
    ],
    'conflict': [
      '快捷键不可用或已被其他应用占用，请处理后重试。',
      'The shortcut is unavailable or already in use. Resolve the conflict and retry.',
      'ショートカットが使用できないか、別のアプリが使用中です。確認して再試行してください。',
    ],
    'unavailable': [
      '暂时无法启用快捷键，请重试。',
      'The shortcut is unavailable. Try again.',
      'ショートカットを有効にできません。再試行してください。',
    ],
    'saveFailed': [
      '快捷键设置未保存，请重试。',
      'Shortcut settings were not saved. Try again.',
      'ショートカット設定を保存できませんでした。再試行してください。',
    ],
    'retry': ['重试', 'Retry', '再試行'],
  };
  return labels[key]?[language == 'zh'
          ? 0
          : language == 'ja'
          ? 2
          : 1] ??
      key;
}
