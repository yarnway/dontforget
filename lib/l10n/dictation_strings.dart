import 'app_localizations.dart';

String dictationText(AppLocalizations loc, String key) {
  const values = {
    'title': ['语音听写', 'Voice dictation', '音声入力'],
    'start': [
      '开始听写（长按切换语言）',
      'Start dictation (hold to change language)',
      '音声入力（長押しで言語選択）',
    ],
    'starting': ['正在启动麦克风…', 'Starting microphone…', 'マイクを起動中…'],
    'ready': ['正在听写，请说话…', 'Listening…', 'お話しください…'],
    'partial': ['正在听写…', 'Listening…', '音声入力中…'],
    'finishing': ['正在完成识别…', 'Finishing recognition…', '認識を完了中…'],
    'stop': ['完成听写', 'Finish dictation', '音声入力を完了'],
    'discard': ['取消本次听写', 'Discard this dictation', '今回の音声入力を破棄'],
    'hint': [
      '点麦克风听写 · 长按选择中／英文',
      'Tap mic to dictate · Hold for Chinese / English',
      'マイクで入力・長押しで中国語／英語を選択',
    ],
    'privacy': [
      '由手机当前配置的系统语音服务识别，可能需要联网并由该服务处理音频。文字留在草稿中，确认后再发送。',
      'Uses your configured Android speech service, which may process audio online. Review the draft before sending.',
      '端末の音声認識サービスを使用します。音声のオンライン処理が必要な場合があります。送信前に下書きを確認してください。',
    ],
    'system': ['系统语音服务设置', 'System speech settings', 'システム音声設定'],
    'record': ['原声录音', 'Voice memo', '録音メモ'],
    'recordHint': ['按住录音，保存原声', 'Hold to record and save audio', '長押しで録音を保存'],
    'save': ['保存录音', 'Save audio', '録音を保存'],
    'dictation_permission': [
      '请允许麦克风权限后重试，原草稿已保留。',
      'Allow microphone access and retry. Your draft is kept.',
      'マイクを許可して再試行してください。下書きは保持されています。',
    ],
    'dictation_network': [
      '语音服务网络异常，请检查网络后重试。已识别文字保留在草稿中。',
      'Speech service network error. Check your connection and retry. Recognized text is kept.',
      '音声サービスの通信エラーです。接続を確認してください。認識済みの文字は保持されています。',
    ],
    'dictation_empty': [
      '没有听清，请重新听写。原草稿已保留。',
      'No speech recognized. Try again. Your draft is kept.',
      '音声を認識できませんでした。下書きは保持されています。',
    ],
    'dictation_language': [
      '当前系统语音服务不支持所选语言，请长按麦克风切换语言或检查系统语音服务。',
      'Your speech service cannot use this language. Hold the microphone to change language or check system speech settings.',
      '選択した言語が利用できません。マイクを長押しして言語を変更するか、システム音声設定を確認してください。',
    ],
    'dictation_busy': [
      '语音服务正在使用，请稍后再试。',
      'Speech service is busy. Try again shortly.',
      '音声サービスが使用中です。しばらくして再試行してください。',
    ],
    'dictation_timeout': [
      '听写已超时停止，已识别文字保留在草稿中。',
      'Dictation timed out. Recognized text is kept in the draft.',
      '音声入力がタイムアウトしました。認識済みの文字は下書きに残っています。',
    ],
    'dictation_unavailable': [
      '系统语音服务不可用。请长按麦克风，检查系统语音服务设置后重试。',
      'System speech recognition is unavailable. Hold the microphone to check speech settings.',
      '音声認識を利用できません。マイクを長押ししてシステム音声設定を確認してください。',
    ],
    'composing': [
      '请先确认输入法候选文字，再开始听写。',
      'Confirm your keyboard composition before dictating.',
      '変換中の文字を確定してから音声入力してください。',
    ],
  };
  final index = switch (loc.locale.languageCode) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  };
  return (values[key] ?? values['dictation_unavailable']!)[index];
}
