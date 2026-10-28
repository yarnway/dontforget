import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

String contentText(BuildContext context, String key) {
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
  'title': ['内容管理', 'Content manager', 'コンテンツ管理'],
  'originals': ['原始资料', 'Original records', '元の資料'],
  'restore': ['恢复材料', 'Restore materials', '復元用ファイル'],
  'archive': ['统一归档', 'Archive', 'アーカイブ'],
  'archived': ['归档库', 'Archived items', 'アーカイブ済み'],
  'available': ['可归档事项', 'Items to archive', 'アーカイブ対象'],
  'scan': ['重新检查引用', 'Refresh references', '参照を再確認'],
  'hint': [
    '任务、附件、用药来源及草稿中的引用均保留，包含回收站与归档。最近24小时及使用中的资料不会清理。',
    'References from tasks, attachments, medication sources and drafts are protected, including trash and archive. Recent 24-hour and active material is retained.',
    'タスク・添付・服薬資料・下書きの参照を保護します。ごみ箱・アーカイブ・直近24時間・使用中の資料も保持します。',
  ],
  'empty': ['没有匹配的内容', 'No matching content', '該当する内容はありません'],
  'filter': [
    '查找标题、项目、标签或文件名',
    'Search title, project, tag or filename',
    '件名・プロジェクト・タグ・ファイル名で検索',
  ],
  'referenced': ['仍被引用，保留', 'Referenced; retained', '参照あり・保持'],
  'backupProtected': [
    '保留的备份仍需这些文件',
    'Retained backups still require these files',
    '保持中のバックアップで必要なファイル',
  ],
  'recent': ['最近24小时，保留', 'Recent 24 hours; retained', '直近24時間・保持'],
  'active': ['正在使用，保留', 'In use; retained', '使用中・保持'],
  'unknown': [
    '来源或目录结构不明，保留',
    'Unrecognized ownership or layout; retained',
    '所有元や構造を確認できないため保持',
  ],
  'eligible': [
    '未被引用，可选择清理',
    'Unreferenced; available to select',
    '参照なし・選択して削除できます',
  ],
  'external': [
    '未列入清理的原文件保留，仅移除这条记录',
    'Unlisted source files stay; only the record is removed',
    '一覧にない元ファイルは保持し、記録のみ削除します',
  ],
  'selected': ['已选择', 'Selected', '選択済み'],
  'clean': ['清理所选内容', 'Clean selected content', '選択した内容を削除'],
  'cleanConfirm': [
    '永久清理这些未引用内容？',
    'Permanently clean these unreferenced items?',
    '参照のない内容を完全に削除しますか？',
  ],
  'cleanHint': [
    '将移除所选独立记录及列出的本应用文件，无法撤销。外部原文件和未选择内容保留；执行前会再次检查引用。',
    'Selected standalone records and listed app-owned files will be removed permanently. External sources and unselected content stay. References are checked again before removal.',
    '選択した独立記録とアプリ所有ファイルを完全に削除します。外部の元ファイルと未選択の内容は保持し、実行直前に参照を再確認します。',
  ],
  'cancel': ['取消', 'Cancel', 'キャンセル'],
  'confirm': ['确认', 'Confirm', '確認'],
  'failed': [
    '操作未完成或内容已变化，请重新检查。',
    'Operation incomplete or content changed. Refresh and retry.',
    '未完了または内容が変更されました。再確認してください。',
  ],
  'done': ['处理完成', 'Completed', '完了'],
  'pending': [
    '有未完成的文件清理，可重试；仍被引用的文件会还原并保留。',
    'File cleanup is incomplete. Retry; newly referenced files are restored and retained.',
    '未完了の削除があります。再試行時、再参照されたファイルは戻して保持します。',
  ],
  'retry': ['重试未完成清理', 'Retry interrupted cleanup', '未完了の削除を再試行'],
  'detail': ['内容详情', 'Content details', '内容の詳細'],
  'archiveAction': ['归档并停止提醒', 'Archive and stop reminders', 'アーカイブして通知を停止'],
  'unarchiveAction': ['移回当前事项', 'Return to current items', '現在の項目へ戻す'],
  'archiveHint': [
    '将一起处理此事项及列出的计划成员；保留完成状态、历史与附件。归档会停止相关提醒，移回后按现有安排重新检查。',
    'This item and the listed plan members are handled together. Outcomes, history and attachments stay. Archiving stops reminders; returning rechecks the existing schedule.',
    'この項目と表示した計画メンバーをまとめて処理します。完了状態・履歴・添付を保持し、アーカイブで通知を停止、戻すと既存予定を再確認します。',
  ],
  'members': ['相关事项', 'Related items', '関連項目'],
  'nativeFailed': [
    '内容已保存，部分提醒同步失败。',
    'Content saved; some reminders could not sync.',
    '内容は保存済みですが一部の通知を同期できませんでした。',
  ],
  'metadata': ['批量编辑项目与标签', 'Edit projects and tags', 'プロジェクトとタグを一括編集'],
  'project': ['项目', 'Project', 'プロジェクト'],
  'tags': ['标签', 'Tags', 'タグ'],
  'keep': ['保持不变', 'Keep unchanged', '変更しない'],
  'set': ['设为填写内容', 'Set to entered value', '入力内容に設定'],
  'clear': ['清空', 'Clear', 'クリア'],
  'add': ['添加', 'Add', '追加'],
  'remove': ['移除', 'Remove', '削除'],
  'replace': ['替换', 'Replace', '置換'],
  'metadataHint': [
    '最多50条普通事项；逐项预览后一次保存。不会改变提醒时刻、周期或完成状态。',
    'Up to 50 ordinary tasks. Review each change, then save together. Reminder times, recurrence and outcomes stay unchanged.',
    '通常タスクを最大50件、変更を確認してまとめて保存します。通知時刻・繰返し・完了状態は変更しません。',
  ],
  'metadataInvalid': [
    '请检查项目或标签：项目最多128字，标签最多16个、每个64字，以逗号或换行分隔。',
    'Check values: project up to 128 characters; up to 16 tags of 64 characters each, separated by commas or newlines.',
    '値を確認してください。プロジェクト128文字、タグ16個・各64文字まで。カンマまたは改行で区切ります。',
  ],
  'preview': ['预览变更', 'Preview changes', '変更を確認'],
  'save': ['保存变更', 'Save changes', '変更を保存'],
  'templateImport': ['导入模板', 'Import templates', 'テンプレートを読込'],
  'templateExport': ['导出模板', 'Export templates', 'テンプレートを保存'],
  'templateHint': [
    '仅传输模板内容，不包含任务、提醒时刻、附件或模型密钥。同名模板需选择跳过、另存副本或替换。',
    'Only template content is transferred, without tasks, reminder times, attachments or API keys. For matching names, choose skip, copy or replace.',
    'テンプレート内容のみで、タスク・通知時刻・添付・モデルキーは含みません。同名の場合はスキップ・コピー・置換を選択します。',
  ],
  'skip': ['跳过', 'Skip', 'スキップ'],
  'copy': ['新增副本', 'Add copy', 'コピーを追加'],
  'conflict': ['同名模板已存在', 'A template with this name exists', '同名のテンプレートがあります'],
  'templateInvalid': [
    '模板文件无效、超过容量或模板库已变化，请重新导入。',
    'Invalid or oversized template file, or library changed. Import again.',
    'ファイルが無効・容量超過、またはライブラリが変更されました。再読込してください。',
  ],
  'task': ['普通事项', 'Task', 'タスク'],
  'medicationPlan': ['用药计划', 'Medication plan', '服薬計画'],
  'departure': ['出门计划', 'Departure plan', '外出計画'],
  'study': ['学习批次', 'Study batch', '学習バッチ'],
};
