String aboutText(String language, String key) {
  const values = {
    'notesOnPage': [
      '完整更新说明见发布页。',
      'Open the release page for the full notes.',
      '更新内容の詳細はリリースページをご覧ください。',
    ],
    'copyFailed': [
      '暂时无法复制，请重试。',
      'Could not copy. Try again.',
      'コピーできませんでした。再試行してください。',
    ],
    'title': ['关于与更新', 'About and updates', 'このアプリと更新'],
    'description': [
      '本地优先的事项记录、提醒与复习工具',
      'Local-first notes, reminders and review',
      'ローカル優先の記録・リマインダー・復習ツール',
    ],
    'version': ['当前版本', 'Installed version', '現在のバージョン'],
    'loading': ['正在读取版本…', 'Reading version…', 'バージョンを確認中…'],
    'versionError': [
      '暂时无法读取安装版本，请重试。',
      'Could not read the installed version. Try again.',
      'インストール済みのバージョンを取得できませんでした。再試行してください。',
    ],
    'retry': ['重试', 'Retry', '再試行'],
    'copyVersion': ['复制版本信息', 'Copy version information', 'バージョン情報をコピー'],
    'copied': ['已复制', 'Copied', 'コピーしました'],
    'project': ['项目主页', 'Project home', 'プロジェクトのホーム'],
    'licenses': ['第三方开源许可', 'Third-party licenses', 'サードパーティのライセンス'],
    'updates': ['应用更新', 'App updates', 'アプリの更新'],
    'check': ['检查更新', 'Check for updates', '更新を確認'],
    'checking': ['正在检查…', 'Checking…', '確認中…'],
    'hint': [
      '点击检查时，从项目的 GitHub 获取公开版本信息。',
      'Check GitHub for this project’s public releases when you choose.',
      'ボタンを押すと、このプロジェクトの GitHub 公開リリースを確認します。',
    ],
    'newer': ['发现新版本', 'An update is available', '新しいバージョンがあります'],
    'current': ['当前已是最新发布版本', 'You have the latest release', '最新の公開バージョンです'],
    'ahead': [
      '当前版本高于公开发行版',
      'Your version is newer than the public release',
      '公開リリースより新しいバージョンを使用中です',
    ],
    'sameVersionBuildUnknown': [
      '版本号相同，构建号尚未核对',
      'Same version; build number could not be verified',
      'バージョンは同じですが、ビルド番号は未確認です',
    ],
    'publicVersion': ['公开版本', 'Public release', '公開バージョン'],
    'checked': ['最近检查', 'Last checked', '最終確認'],
    'notes': ['更新说明', 'Release notes', '更新内容'],
    'releasePage': ['打开发布页', 'Open release page', 'リリースページを開く'],
    'allReleases': ['查看所有版本', 'View all releases', 'すべてのリリースを見る'],
    'network': [
      '暂时无法连接更新服务，请检查网络后重试。',
      'Could not connect. Check your network and try again.',
      '更新サービスに接続できません。ネットワークを確認して再試行してください。',
    ],
    'timeout': [
      '检查超时，请稍后重试。',
      'The check timed out. Try again shortly.',
      '確認がタイムアウトしました。しばらくして再試行してください。',
    ],
    'rateLimited': [
      '更新服务暂时限制请求，请稍后重试或打开发布页。',
      'Too many requests. Try again later or open the releases page.',
      'リクエストが制限されています。後で再試行するか、リリースページを開いてください。',
    ],
    'noRelease': [
      '暂未找到公开发行版，可打开发布页查看。',
      'No public release was found. You can open the releases page.',
      '公開リリースが見つかりません。リリースページをご確認ください。',
    ],
    'invalidResponse': [
      '版本信息未通过核对，请稍后重试或打开发布页。',
      'Release information could not be verified. Retry or open the releases page.',
      'リリース情報を確認できませんでした。再試行するか、リリースページを開いてください。',
    ],
    'server': [
      '更新服务暂不可用，请稍后重试。',
      'The update service is unavailable. Try again later.',
      '更新サービスを利用できません。しばらくして再試行してください。',
    ],
    'openFailed': [
      '暂时无法打开浏览器，可复制链接后打开。',
      'Could not open the browser. Copy the link to open it yourself.',
      'ブラウザーを開けません。リンクをコピーして開いてください。',
    ],
    'copyLink': ['复制链接', 'Copy link', 'リンクをコピー'],
    'noPackage': [
      '此版本暂未提供当前平台的安装包，可在发布页查看。',
      'There is no package for this platform in this release. Check the release page.',
      'このリリースには、この環境向けのパッケージがありません。リリースページをご確認ください。',
    ],
    'windowsSetup': [
      '下载 Windows 安装器',
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
      '下载 Android ARM64 小包',
      'Download smaller Android ARM64 APK',
      'Android ARM64 小型 APK を取得',
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
