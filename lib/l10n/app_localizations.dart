import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;
  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'appTitle': "Don't Forget",
      'settings': 'Settings',
      'q1': 'Urgent & Important',
      'q2': 'Important',
      'q3': 'Urgent & Not Important',
      'q4': 'General Reminders',
      'hint': 'What should I not forget?',
      'recording': 'Recording audio...',
      'save': 'Save',
      'apiKey': 'LLM API Key',
      'baseUrl': 'API Base URL',
      'modelName': 'Model Name',
      'language': 'Language',
    },
    'zh': {
      'appTitle': '别忘了',
      'settings': '设置',
      'q1': '紧急且重要',
      'q2': '重要不紧急',
      'q3': '紧急不重要',
      'q4': '不重要不紧急',
      'hint': '有什么事情别忘了？',
      'recording': '正在录音...',
      'save': '保存',
      'apiKey': '大模型 API Key',
      'baseUrl': '接口基础地址',
      'modelName': '模型名称',
      'language': '语言',
    },
    'ja': {
      'appTitle': '忘れないで',
      'settings': '設定',
      'q1': '緊急かつ重要',
      'q2': '重要',
      'q3': '緊急だが重要ではない',
      'q4': '重要でも緊急でもない',
      'hint': '何を忘れないようにしますか？',
      'recording': '録音中...',
      'save': '保存',
      'apiKey': 'APIキー',
      'baseUrl': 'ベースURL',
      'modelName': 'モデル名',
      'language': '言語',
    },
  };

  String get(String key) {
    return _localizedValues[locale.languageCode]?[key] ?? _localizedValues['en']![key]!;
  }
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'zh', 'ja'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
