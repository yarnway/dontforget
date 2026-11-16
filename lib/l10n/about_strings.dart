String aboutText(String language, String key) {
  const values = {
    'notesOnPage': [
      '完整说明见发布页。',
      'Full notes are on the release page.',
      '詳細はリリースページをご覧ください。',
    ],
    'copyFailed': ['复制失败，请重试。', 'Copy failed. Retry.', 'コピーできません。再試行してください。'],
    'title': ['关于与更新', 'About and updates', 'このアプリと更新'],
    'description': [
      '本地优先的事项记录、提醒与复习工具',
      'Local-first notes, reminders and review',
      'ローカル優先の記録・リマインダー・復習ツール',
    ],
    'version': ['当前版本', 'Installed version', '現在のバージョン'],
    'loading': ['读取版本中…', 'Reading version…', 'バージョンを確認中…'],
    'versionError': [
      '无法读取版本，请重试。',
      'Version unavailable. Retry.',
      'バージョンを取得できません。再試行してください。',
    ],
    'retry': ['重试', 'Retry', '再試行'],
    'copyVersion': ['复制版本', 'Copy version', 'バージョンをコピー'],
    'copied': ['已复制', 'Copied', 'コピーしました'],
    'project': ['项目主页', 'Project home', 'プロジェクトのホーム'],
    'licenses': ['第三方开源许可', 'Third-party licenses', 'サードパーティのライセンス'],
    'updates': ['应用更新', 'App updates', 'アプリの更新'],
    'resources': ['项目与许可', 'Project and licenses', 'プロジェクトとライセンス'],
    'check': ['检查更新', 'Check for updates', '更新を確認'],
    'checking': ['正在检查…', 'Checking…', '確認中…'],
    'hint': [
      '从 GitHub 检查发布版本，不自动安装。',
      'Check GitHub releases. Install updates manually.',
      'GitHub の公開版を確認します。インストールは手動です。',
    ],
    'newer': ['发现新版本', 'An update is available', '新しいバージョンがあります'],
    'current': ['已是最新发布版', 'You have the latest release', '最新の公開版です'],
    'ahead': [
      '当前版本高于发布版',
      'Your version is ahead of the public release',
      '公開版より新しいバージョンです',
    ],
    'sameVersionBuildUnknown': [
      '版本相同，构建号未核对',
      'Same version; build unverified',
      'バージョンは同じですが、ビルド番号は未確認です',
    ],
    'publicVersion': ['公开版本', 'Public release', '公開バージョン'],
    'checked': ['最近检查', 'Last checked', '最終確認'],
    'notes': ['更新说明', 'Release notes', '更新内容'],
    'releasePage': ['打开发布页', 'Open release page', 'リリースページを開く'],
    'allReleases': ['查看所有版本', 'View all releases', 'すべてのリリースを見る'],
    'network': [
      '连接失败，请检查网络后重试。',
      'Connection failed. Check your network and retry.',
      '接続できません。ネットワークを確認して再試行してください。',
    ],
    'timeout': [
      '检查超时，请重试。',
      'Check timed out. Retry.',
      '確認がタイムアウトしました。再試行してください。',
    ],
    'rateLimited': [
      '请求受限，请稍后重试或查看发布页。',
      'Request limit reached. Retry later or view releases.',
      'リクエストが制限されています。後で再試行するか、公開版を確認してください。',
    ],
    'noRelease': [
      '暂无发布版本，可查看发布页。',
      'No public release found. View the release page.',
      '公開版がありません。リリースページをご確認ください。',
    ],
    'invalidResponse': [
      '版本信息校验失败，请重试或查看发布页。',
      'Release verification failed. Retry or view releases.',
      'リリース情報を検証できません。再試行するか、公開版を確認してください。',
    ],
    'server': [
      '更新服务不可用，请稍后重试。',
      'Update service unavailable. Retry later.',
      '更新サービスを利用できません。後で再試行してください。',
    ],
    'openFailed': [
      '无法打开浏览器，可复制链接。',
      'Browser unavailable. Copy the link.',
      'ブラウザーを開けません。リンクをコピーしてください。',
    ],
    'copyLink': ['复制链接', 'Copy link', 'リンクをコピー'],
    'noPackage': [
      '此版本无当前平台安装包，可查看发布页。',
      'No package for this platform. View the release page.',
      'この環境向けのパッケージはありません。公開版をご確認ください。',
    ],
    'windowsSetup': [
      '下载 Windows 安装版',
      'Download Windows installer',
      'Windows インストーラーを取得',
    ],
    'windowsPortable': [
      '下载 Windows 便携版',
      'Download Windows portable',
      'Windows ポータブル版を取得',
    ],
    'linuxArchive': [
      '下载 Linux 安装包',
      'Download Linux archive',
      'Linux パッケージを取得',
    ],
    'androidUniversal': [
      '下载 Android 通用 APK',
      'Download universal Android APK',
      'Android 汎用 APK を取得',
    ],
    'androidArm64': [
      '下载 Android ARM64 APK',
      'Download Android ARM64 APK',
      'Android ARM64 APK を取得',
    ],
    'iosUnsigned': ['下载 iOS IPA', 'Download iOS IPA', 'iOS IPA を取得'],
    'iosHint': [
      'iOS 包需通过 AltStore 个人重签安装，免费账号通常每7天续期。',
      'Install the iOS IPA with personal AltStore signing. Free accounts usually require renewal every 7 days.',
      'iOS IPA は AltStore で個人署名してインストールします。無料アカウントは通常7日ごとの更新が必要です。',
    ],
    'iosGuide': ['查看 iOS 安装说明', 'iOS installation guide', 'iOS インストール手順'],
    'arm64Hint': [
      '不确定手机架构时，请选择通用 APK。',
      'Choose the universal APK if you are unsure of your device architecture.',
      '端末のアーキテクチャが不明な場合は、汎用 APK を選んでください。',
    ],
  };
  final index = switch (language) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  };
  return values[key]?[index] ?? key;
}
