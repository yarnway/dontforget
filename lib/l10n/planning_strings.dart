import 'package:flutter/material.dart';
import 'app_localizations.dart';

String planningText(BuildContext context, String key) {
  final language = AppLocalizations.of(context).locale.languageCode;
  final values = _strings[key];
  return values == null
      ? key
      : values[language == 'zh'
            ? 0
            : language == 'ja'
            ? 2
            : 1];
}

const _strings = <String, List<String>>{
  'independentDates': [
    '已生成独立日期，未完成上一天也会保留下一天提醒（滚动 60 天）',
    'Independent dates for a rolling 60 days; an unfinished date does not block the next one.',
    '60日分の独立した日程です。未完了でも翌日の通知は残ります。',
  ],
  'returnWindow': [
    '出行天气覆盖时长（分钟，1–1440）',
    'Weather window after departure (minutes, 1–1440)',
    '外出後の天気確認時間（分、1–1440）',
  ],
  'reloadPlan': ['重新载入已保存计划', 'Reload saved plan', '保存済みプランを再読込'],
  'editDeparturePlan': [
    '查看或调整出门计划',
    'View or edit departure plan',
    '外出プランを確認・編集',
  ],
  'checkCoverage': [
    '查看提醒覆盖与修复',
    'Check reminder coverage and repair',
    '通知の範囲と修復を確認',
  ],
  'inAppOnly': [
    '当前平台需保持应用运行；本页不代表关闭应用后仍会提醒。',
    'Keep the app running on this platform; this page does not confirm reminders after closing it.',
    'この環境ではアプリを起動したままにしてください。終了後の通知は未確認です。',
  ],

  'created': ['已创建', 'Created', '作成'],
  'edited': ['已修改', 'Edited', '変更'],
  'completed': ['已完成', 'Completed', '完了'],
  'snoozed': ['已延后', 'Snoozed', '通知を延期'],
  'skipped': ['已跳过本次', 'Occurrence skipped', '今回をスキップ'],
  'plan_changed': ['计划已调整', 'Plan changed', 'プラン変更'],
  'item_done': ['清单项完成', 'Item completed', '項目を完了'],
  'item_reopened': ['清单项重新打开', 'Item reopened', '項目を再開'],
  'departure_record': ['出门记录已更新', 'Departure record updated', '外出記録を更新'],
  'word_review': ['逐词反馈', 'Word feedback', '単語評価'],

  'rainThreshold': [
    '降雨概率阈值（%）',
    'Rain probability threshold (%)',
    '降水確率のしきい値（%）',
  ],
  'medicineDates': [
    '单药日期可留空，沿用计划起止日期；填写格式为 YYYY-MM-DD。',
    'Leave medicine dates blank to use the course dates, or enter YYYY-MM-DD.',
    '各薬の日付は空欄ならプランの期間を使います。指定する場合は YYYY-MM-DD で入力してください。',
  ],
  'testAi': [
    '测试 AI（一次文字 JSON 请求）',
    'Test AI (one text JSON request)',
    'AI テスト（テキスト JSON リクエスト 1 回）',
  ],
  'aiTestPassed': [
    '当前配置的文字 JSON 请求通过；图片和语音能力需分别测试。',
    'Text JSON request passed. Image and audio support need separate tests.',
    'テキスト JSON リクエストが成功しました。画像と音声は別に確認してください。',
  ],
  'editMedicationPlan': [
    '在用药计划中校对服药安排',
    'Review timing in the medication plan',
    '服薬プランで服用予定を確認',
  ],
  'learningManage': ['学习管理', 'Learning', '学習管理'],
  'learningOverview': [
    '学习档案与反馈',
    'Learning history and feedback',
    '学習履歴とフィードバック',
  ],
  'wordArchive': ['有反馈的单词', 'Words with feedback', '評価済みの単語'],
  'learningEvidence': [
    '以下为此版本开始记录的逐词反馈次数；同词同次反馈去重，不补造过去记录。',
    'Counts below use word feedback recorded by this version, deduplicated across batches. Older history is not invented.',
    '以下はこのバージョンで記録した単語評価の回数です。同じ評価は重複集計せず、過去の記録は推定しません。',
  ],
  'loadForecast': [
    '未来七天到期词量（未套用每日额度）',
    'Words due over seven days (before daily limits)',
    '今後 7 日間の期限単語数（1 日上限の適用前）',
  ],
  'studyPlans': ['学习批次与暂停', 'Study batches and pause controls', '学習セットと一時停止'],
  'learningIntervals': [
    '认识后的五级复习间隔（天）',
    'Five review intervals after Known (days)',
    '「知っている」評価後の 5 段階の復習間隔（日）',
  ],
  'saveIntervals': [
    '保存后续复习间隔',
    'Save intervals for future feedback',
    '今後の評価に使う間隔を保存',
  ],
  'customWords': ['自定义词表', 'Custom vocabulary list', 'カスタム単語リスト'],
  'wordlistFormat': [
    '每行：单词、释义、例句，用 Tab 分隔。最多 140 词，按每批 20 词预览后确认。',
    'One word, meaning and example per line, separated by tabs. Up to 140 words; review batches of 20 before confirming.',
    '各行に単語・意味・例文をタブで区切って入力します。最大 140 語、20 語ずつ確認して登録します。',
  ],
  'correctWords': ['校对词汇内容', 'Correct vocabulary notes', '単語内容を修正'],
  'wordNotes': [
    '保留“单词 — 释义”和例句格式',
    'Keep the word — meaning and example format',
    '単語 — 意味と例文の形式を維持してください',
  ],
  'spellingPractice': ['拼写练习', 'Spelling practice', 'スペル練習'],
  'spellingAnswer': ['输入对应英文', 'Type the English word', '対応する英単語を入力'],
  'checkSpelling': ['检查拼写', 'Check spelling', 'スペルを確認'],
  'spellingCorrect': ['拼写正确', 'Correct spelling', '正解です'],
  'spellingExpected': ['参考拼写', 'Expected spelling', '正しいスペル'],
  'nextWord': ['下一词', 'Next word', '次の単語'],

  'previewChanged': [
    '预览时刻已过，请重新核对并确认。',
    'The preview time has passed. Review and confirm again.',
    'プレビューの時刻が過ぎました。再度確認してください。',
  ],
  'backup': ['备份', 'Backup', 'バックアップ'],
  'exportBackup': [
    '导出任务与附件备份包',
    'Export tasks and attachments',
    'タスクと添付をエクスポート',
  ],
  'importBackup': [
    '打开备份包并预览恢复',
    'Open bundle and preview restore',
    'バックアップを開いて復元を確認',
  ],
  'backupHint': [
    '备份包包含任务、草稿和附件，排除模型密钥；目前不加密。附件合计上限 32 MiB，缺失附件会显示数量。恢复前仍需检查并确认。',
    'Includes tasks, drafts and attachments, without model keys. Not encrypted. Attachments are limited to 32 MiB; missing files are reported. Review and confirm before restoring.',
    'タスク・下書き・添付を含み、モデルのキーは除外します。暗号化されません。添付は合計 32 MiB までで、欠落数を表示します。復元前に内容を確認してください。',
  ],
  'missingMedia': ['缺失附件', 'Missing attachments', '不足している添付'],
  'lastBackup': ['最近导出', 'Last export', '前回のエクスポート'],
  'exportCancelled': ['已取消保存', 'Save cancelled', '保存をキャンセルしました'],

  'planning': ['计划与清单', 'Plans and checklists', 'プランとチェックリスト'],
  'planningHint': [
    '用药、出门清单、周期与执行记录',
    'Medication, departures, repeats and history',
    '服薬・外出・繰り返し・履歴',
  ],
  'medication': ['用药', 'Medication', '服薬'],
  'departure': ['出门', 'Departure', '外出'],
  'manage': ['管理', 'Manage', '管理'],
  'title': ['计划名称', 'Plan name', 'プラン名'],
  'person': ['服用人', 'Person', '服用する人'],
  'source': [
    '原始描述／处方文字',
    'Original description / prescription text',
    '元の説明・処方内容',
  ],
  'sourceSaved': [
    '从已保存的图片、录音或文字选择',
    'Choose a saved image, recording or text',
    '保存済みの画像・録音・テキストを選択',
  ],
  'extract': ['AI 提取为待确认草稿', 'Extract an AI draft for review', 'AI で確認用下書きを作成'],
  'start': ['开始日期', 'Start date', '開始日'],
  'end': ['结束日期', 'End date', '終了日'],
  'name': ['药名', 'Medicine name', '薬の名前'],
  'strength': ['规格／剂型', 'Strength / form', '規格・剤形'],
  'amount': ['每次数量', 'Amount per dose', '1 回の量'],
  'unit': ['单位', 'Unit', '単位'],
  'meal': ['饭前／饭后等原始要求', 'Original meal instructions', '食前・食後などの指示'],
  'times': [
    '确认后的时刻（HH:mm，逗号分隔）',
    'Confirmed times (HH:mm, comma separated)',
    '確認済みの時刻（HH:mm、カンマ区切り）',
  ],
  'notes': ['医嘱说明', 'Instructions', '服用の指示'],
  'evidence': ['识别来源', 'Source evidence', '識別元'],
  'unresolved': ['待核对：', 'Needs review: ', '要確認：'],
  'reviewed': [
    '已核对并解决上述不确定信息',
    'I checked and resolved these uncertainties',
    '不明点を確認し解決しました',
  ],
  'addMedicine': ['添加药品', 'Add medicine', '薬を追加'],
  'remove': ['移除', 'Remove', '削除'],
  'confirmMedication': [
    '已逐药核对用量、时刻和疗程',
    'I verified each dose, time and course',
    '各薬の量・時刻・期間を確認しました',
  ],
  'medHint': [
    '按处方核对；缺失信息保留待确认，不自动推定药物、剂量或疗程。',
    'Check the prescription. Missing medicines, doses and course dates stay unresolved.',
    '処方に沿って確認してください。薬・用量・期間の不足情報は推定しません。',
  ],
  'preview': ['预览', 'Preview', 'プレビュー'],
  'activate': ['确认并启用', 'Confirm and activate', '確認して有効化'],
  'saveDraft': ['保存草稿', 'Save draft', '下書きを保存'],
  'draftSaved': ['草稿已保存', 'Draft saved', '下書きを保存しました'],
  'saved': ['已保存', 'Saved', '保存しました'],
  'failed': [
    '未保存，请核对输入或重新载入后重试',
    'Not saved. Check the input or reload and retry.',
    '未保存です。入力を確認するか再読み込みして再試行してください。',
  ],
  'incomplete': [
    '请补齐名称、起止日期，以及每种药的规格、用量、单位、餐次和具体时刻。',
    'Complete the name, course dates and each medicine’s strength, amount, unit, meal instructions and times.',
    '名前・開始終了日・各薬の規格、量、単位、食事の指示、具体的な時刻を入力してください。',
  ],
  'doses': ['待提醒剂次', 'Future doses', '今後の服薬回数'],
  'taken': ['已服用', 'Taken', '服用済み'],
  'notTaken': ['记录未服用', 'Record not taken', '未服用として記録'],
  'pending': ['待处理', 'Pending', '未処理'],
  'place': ['出门地点／场景标签', 'Departure place / context label', '出発場所・場面ラベル'],
  'departureTime': ['预计出门时间', 'Expected departure', '外出予定時刻'],
  'lead': ['提前分钟数', 'Minutes before departure', '何分前に通知'],
  'weekdays': ['重复星期（周一至周日）', 'Repeat weekdays (Mon–Sun)', '繰り返す曜日（月〜日）'],
  'calendarHint': [
    '工作日按周一至周五；未接入法定调休日历。',
    'Weekdays mean Monday–Friday; public holiday adjustments are not connected.',
    '平日は月〜金です。祝日・振替出勤日は連携されていません。',
  ],
  'items': ['常备物品（每行一项）', 'Everyday items (one per line)', '常備品（1 行に 1 項目）'],
  'onceItems': [
    '一次性事项（每行一项）',
    'One-time tasks (one per line)',
    '今回限りの項目（1 行に 1 項目）',
  ],
  'rainItems': [
    '降雨条件物品（每行一项）',
    'Items for rain (one per line)',
    '雨のときの持ち物（1 行に 1 項目）',
  ],
  'learning': [
    '主动记录出门习惯（本机）',
    'Record departure habits on this device',
    '外出習慣をこの端末に記録',
  ],
  'learningHint': [
    '仅记录你主动确认的出门时间和地点标签；可关闭并删除。不会启用后台定位。',
    'Only times and place labels you confirm are recorded. You can disable and delete them. No background location is enabled.',
    '確認した外出時刻と場所ラベルのみ記録します。無効化・削除が可能です。バックグラウンド測位は行いません。',
  ],
  'weatherEnabled': [
    '启用城市天气（Open-Meteo）',
    'Enable city weather (Open-Meteo)',
    '都市の天気を有効化（Open-Meteo）',
  ],
  'weatherConsent': [
    '查询会向 Open-Meteo 发送所选城市坐标；不发送出门记录。',
    'Queries send the selected city coordinates to Open-Meteo, without departure records.',
    '選んだ都市の座標を Open-Meteo に送信します。外出履歴は送信しません。',
  ],
  'city': ['搜索天气城市', 'Search weather city', '天気の都市を検索'],
  'search': ['搜索', 'Search', '検索'],
  'refreshWeather': ['刷新天气', 'Refresh weather', '天気を更新'],
  'weatherUnknown': [
    '天气未知或已过期，请自行确认',
    'Weather unavailable or stale; check the forecast',
    '天気が不明または古いため確認してください',
  ],
  'rain': [
    '预计出门时段有降雨风险',
    'Rain risk during the departure window',
    '外出時間帯に降雨の可能性があります',
  ],
  'noRain': [
    '当前预报低于所选降雨阈值',
    'Current forecast is below the selected rain threshold',
    '現在の予報は設定した降雨のしきい値未満です',
  ],
  'leaveNow': ['记录现在出门', 'Record departure now', '今から外出として記録'],
  'clearRecords': ['删除出门记录', 'Delete departure records', '外出記録を削除'],
  'suggest': ['本地习惯建议', 'Local habit suggestion', '端末内の習慣に基づく提案'],
  'aiSuggest': ['AI 分析时间摘要', 'Ask AI about the time summary', 'AI で時刻の要約を分析'],
  'adopt': ['采用建议时刻', 'Use suggested time', '提案時刻を採用'],
  'notEnough': [
    '有效样本不足或时间波动较大，保留原提醒。',
    'Not enough consistent samples; keeping the existing reminder.',
    '有効な記録が不足しているか時刻の変動が大きいため、現在の通知を維持します。',
  ],
  'pause': ['暂停', 'Pause', '一時停止'],
  'resume': ['继续', 'Resume', '再開'],
  'trash': ['回收站', 'Trash', 'ごみ箱'],
  'moveTrash': ['移入回收站', 'Move to trash', 'ごみ箱へ移動'],
  'restore': ['恢复', 'Restore', '復元'],
  'archive': ['归档', 'Archive', 'アーカイブ'],
  'unarchive': ['取消归档', 'Unarchive', 'アーカイブ解除'],
  'history': ['执行记录', 'History', '実行履歴'],
  'edit': ['编辑', 'Edit', '編集'],
  'newChecklist': ['新建清单', 'New checklist', 'チェックリストを作成'],
  'tags': ['标签（逗号分隔）', 'Tags (comma separated)', 'タグ（カンマ区切り）'],
  'project': ['项目', 'Project', 'プロジェクト'],
  'interval': ['每隔几个周期', 'Repeat interval', '繰り返し間隔'],
  'repeatEnd': ['重复结束日期（可选）', 'Repeat end date (optional)', '繰り返し終了日（任意）'],
  'checklist': [
    '清单项（每行一项）',
    'Checklist items (one per line)',
    'チェック項目（1 行に 1 項目）',
  ],
  'empty': ['暂无内容', 'Nothing here yet', 'まだありません'],
  'filter': ['搜索标题、标签或项目', 'Search title, tags or project', '名前・タグ・プロジェクトを検索'],
  'newPlan': ['新建计划', 'New plan', '新しいプラン'],
  'retention': ['记录保留天数', 'Record retention days', '記録の保存日数'],
  'courseRange': [
    '疗程最多 93 天、1000 剂次；日期包含首末日。',
    'Up to 93 calendar days and 1,000 doses, including both course dates.',
    '開始日と終了日を含む最大 93 日・1,000 回までです。',
  ],
  'doseRange': [
    '选择日期查看逐药记录',
    'Choose a date to view dose records',
    '日付を選んで各薬の記録を表示',
  ],
};
