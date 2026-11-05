String speechText(String language, String key) {
  const values = {
    'title': ['录音转文字', 'Recording transcription', '録音の文字起こし'],
    'provider': [
      '腾讯云语音识别',
      'Tencent Cloud speech recognition',
      'Tencent Cloud 音声認識',
    ],
    'scope': [
      '按住输入区录音，上滑往右转文字。支持中文和英文，结果进入草稿，编辑后再发送。',
      'Hold the input to record, slide up and right to transcribe. Chinese and English results stay in an editable draft.',
      '入力欄を長押しして録音し、上へスライドして右を選ぶと文字起こしします。中国語・英語の結果は編集可能な下書きに残ります。',
    ],
    'privacy': [
      '启用后，仅在你选择转文字或重试识别时，将录音发送到腾讯云，可能产生服务费用。凭据保存在系统安全存储，不写入数据库或可移植备份。',
      'When enabled, choosing transcription or retry uploads audio to Tencent Cloud and may incur service charges. Credentials use system secure storage and are excluded from database rows and portable backups.',
      '有効にすると、文字起こしまたは再試行を選んだ場合に録音をTencent Cloudへ送信します。料金が発生する場合があります。認証情報はシステムの安全な領域に保存され、DBや持ち運び用バックアップには含まれません。',
    ],
    'enabled': [
      '启用腾讯云录音转文字',
      'Enable Tencent transcription',
      'Tencent文字起こしを有効にする',
    ],
    'credentials': [
      '填写已开通语音识别服务账号的凭据',
      'Enter credentials for an account with speech recognition enabled',
      '音声認識が有効なアカウントの認証情報を入力',
    ],
    'remove': ['清除语音凭据', 'Clear speech credentials', '音声認証情報を消去'],
    'incomplete': [
      '请完整填写有效的 AppID、SecretId 和 SecretKey。',
      'Enter a valid AppID, SecretId and SecretKey.',
      '有効なAppID、SecretId、SecretKeyを入力してください。',
    ],
    'unavailable': [
      '设置或安全凭据暂不可用，请返回“数据保护”检查后重试。',
      'Settings or secure credentials are unavailable. Check Data protection and retry.',
      '設定または認証情報を利用できません。データ保護を確認して再試行してください。',
    ],
    'saveFailed': [
      '保存失败，输入已保留，请重试。',
      'Could not save. Your input is kept; retry.',
      '保存できませんでした。入力は保持されています。',
    ],
    'legacy': [
      '原语音凭据属于其他服务。保留现状，或填写腾讯云凭据替换；清除也需保存后生效。',
      'Existing speech credentials belong to another service. Keep them, replace with Tencent credentials, or clear and save.',
      '既存の認証情報は別サービスのものです。保持するか、Tencent情報で置き換えるか、消去して保存してください。',
    ],
    'limit': [
      '单段最多5分钟、10MB；失败时保留原声。',
      'Up to 5 minutes / 10 MB per recording. Original audio is kept on failure.',
      '1件最大5分・10MBです。失敗時は元の録音を保持します。',
    ],
    'help': ['腾讯云配置帮助', 'Tencent setup help', 'Tencent設定のヘルプ'],
    'guide': [
      '在腾讯云控制台开通“录音文件识别极速版”，并获取本人的 AppID、SecretId、SecretKey。请勿把凭据发到聊天或提交到仓库。',
      'Enable Flash recording recognition in Tencent Cloud and obtain your AppID, SecretId and SecretKey. Keep credentials out of chat and source control.',
      'Tencent Cloudで高速録音認識を有効にし、自分のAppID、SecretId、SecretKeyを取得してください。チャットやソース管理に貼り付けないでください。',
    ],
    'not_configured': [
      '腾讯云录音转文字尚未配置。请在设置中完成配置；原声已保存。',
      'Configure Tencent recording transcription in Settings. Original audio was saved.',
      '設定でTencent文字起こしを設定してください。元の録音は保存しました。',
    ],
    'authentication': [
      '腾讯云鉴权失败，请检查语音凭据、权限及手机时间。原声已保存。',
      'Tencent authentication failed. Check credentials, permissions and device time. Original audio was saved.',
      'Tencent認証に失敗しました。認証情報、権限、端末時刻を確認してください。元の録音は保存しました。',
    ],
    'not_activated': [
      '腾讯云语音服务尚未开通，请在腾讯云控制台开通。原声已保存。',
      'Enable Tencent speech recognition in its console. Original audio was saved.',
      'Tencent管理画面で音声認識を有効にしてください。元の録音は保存しました。',
    ],
    'quota': [
      '腾讯云语音额度不足或账号欠费，请检查服务状态。原声已保存。',
      'Tencent speech quota or billing needs attention. Original audio was saved.',
      'Tencentの残量・支払い状況を確認してください。元の録音は保存しました。',
    ],
    'throttled': [
      '腾讯云语音请求繁忙，请稍后重试。原声已保存。',
      'Tencent speech service is busy. Retry shortly. Original audio was saved.',
      '音声サービスが混雑しています。後で再試行してください。元の録音は保存しました。',
    ],
    'too_large': [
      '录音超过10MB，原声已保存，请缩短后重试。',
      'Recording exceeds 10 MB. Original audio was saved.',
      '録音が10MBを超えています。元の録音は保存しました。',
    ],
    'too_long': [
      '录音超过5分钟，原声已保存，请缩短后重试。',
      'Recording exceeds 5 minutes. Original audio was saved.',
      '録音が5分を超えています。元の録音は保存しました。',
    ],
    'format': [
      '录音格式暂不支持识别，请重新录制。原声已保存。',
      'This audio format could not be recognized. Record again. Original audio was saved.',
      'この録音形式を認識できません。再録音してください。元の録音は保存しました。',
    ],
    'network': [
      '腾讯云语音连接失败，请检查网络后重试。原声已保存。',
      'Could not connect to Tencent speech recognition. Check your network. Original audio was saved.',
      'Tencent音声認識に接続できません。接続を確認してください。元の録音は保存しました。',
    ],
    'timeout': [
      '腾讯云语音识别超时，请重试。原声已保存。',
      'Tencent transcription timed out. Retry. Original audio was saved.',
      'Tencent文字起こしがタイムアウトしました。元の録音は保存しました。',
    ],
    'failed': [
      '录音暂未能转为文字，原声已保存，可稍后重试。',
      'Could not transcribe. Original audio was saved for retry.',
      '文字起こしできませんでした。元の録音は再試行用に保存しました。',
    ],
  };
  final index = switch (language) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  };
  return (values[key] ?? values['failed']!)[index];
}
