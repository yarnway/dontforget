import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

String protectionText(BuildContext context, String key) {
  final l = AppLocalizations.of(context).locale.languageCode;
  final v = _strings[key];
  return v == null
      ? key
      : v[l == 'zh'
            ? 0
            : l == 'ja'
            ? 2
            : 1];
}

const _strings = <String, List<String>>{
  'title': ['数据与安全', 'Data and security', 'データとセキュリティ'],
  'credentialTitle': ['模型密钥', 'Model credentials', 'モデルのキー'],
  'notConfigured': [
    '尚未配置密钥；配置后仅保存到系统安全存储。',
    'No credentials configured. New keys use system secure storage.',
    'キー未設定です。設定したキーはシステムの安全な領域に保存します。',
  ],
  'secured': [
    '当前配置的密钥已改存系统安全存储；新备份不导出密钥。旧备份可能仍含旧密钥。',
    'Current API keys use system secure storage and are excluded from new backups. Older backups may still contain old keys.',
    '現在のキーはシステムの安全な領域に保存し、新しいバックアップから除外します。古いバックアップには以前のキーが残る場合があります。',
  ],
  'unavailable': [
    '系统安全存储暂不可用，AI 已停用。请解锁系统后重试；不会改为明文保存。',
    'Secure storage is unavailable; AI is disabled. Unlock the system and retry. Keys will not be saved as plaintext.',
    '安全な保存領域にアクセスできず AI は無効です。システムを解除して再試行してください。平文では保存しません。',
  ],
  'missing': [
    '此设备缺少已保存的密钥，请重新配置；任务与附件仍可使用。',
    'This device has no matching saved keys. Configure them again; tasks and attachments remain available.',
    'この端末に対応するキーがありません。再設定してください。タスクと添付は利用できます。',
  ],
  'migrationPending': [
    '旧密钥尚未安全迁移，原数据已保留，AI 暂停使用这些密钥。请重试。',
    'Legacy keys could not be migrated safely. Original data is preserved; AI will not use these keys until repaired.',
    '古いキーを安全に移行できませんでした。元データを保持し、修復まで AI で使用しません。',
  ],
  'cleanupPending': [
    '配置已保存，旧安全存储条目仍待清理。请解锁系统后重试。',
    'Settings saved; old secure entries still need cleanup. Unlock the system and retry.',
    '設定は保存済みですが古い安全な項目の削除が未完了です。解除後に再試行してください。',
  ],
  'retry': ['重新检查安全存储', 'Check secure storage again', '安全な保存領域を再確認'],
  'retryDirty': [
    '当前有未保存的设置，请先保存或放弃修改后再重新载入密钥。',
    'Save or discard the current settings draft before reloading credentials.',
    '未保存の設定を保存または破棄してからキーを再読込してください。',
  ],
  'forget': ['移除当前模型密钥', 'Remove current model keys', '現在のモデルキーを削除'],
  'forgetHint': [
    '将停用所有模型并移除当前密钥；任务、附件和模型地址保留。',
    'Disable all models and remove current keys. Tasks, attachments and endpoint settings remain.',
    '全モデルを無効にして現在のキーを削除します。タスク・添付・接続先は保持します。',
  ],
  'cancel': ['取消', 'Cancel', 'キャンセル'],
  'confirm': ['确认移除', 'Remove keys', '削除'],
  'failed': [
    '操作未完成，请重试；未将密钥改为明文保存。',
    'Operation incomplete. Retry; credentials were not saved as plaintext.',
    '操作が完了しませんでした。再試行してください。キーを平文には保存していません。',
  ],
  'backupHint': [
    '完整备份任务与附件，可选密码加密。单附件最多 512 MiB，附件合计 2 GiB；旧 JSON 备份仍可导入。所有导出均排除模型密钥。加密仅用于导出文件，本机内容与自动恢复副本未加密。',
    'Back up tasks and attachments with optional password encryption. Up to 512 MiB per attachment and 2 GiB total; legacy JSON imports remain supported. API keys are always excluded. Encryption applies to exports; local content and automatic recovery copies are unencrypted.',
    'タスクと添付を任意のパスワード暗号化で保存します。添付は各 512 MiB、合計 2 GiB まで。旧 JSON も読込可能です。モデルキーは常に除外します。暗号化は保存ファイルのみです。端末内の内容と自動復元コピーは暗号化しません。',
  ],
  'encrypt': [
    '使用密码加密备份（推荐）',
    'Encrypt backup with a password (recommended)',
    'パスワードで暗号化（推奨）',
  ],
  'password': ['备份密码', 'Backup password', 'バックアップのパスワード'],
  'passwordAgain': ['再次输入密码', 'Repeat password', 'パスワードを再入力'],
  'passwordHint': [
    '至少 12 个字符。密码不会保存，遗失后无法恢复加密备份。',
    'At least 12 characters. Passwords are not saved; encrypted backups cannot be recovered without them.',
    '12 文字以上。パスワードは保存しません。紛失すると暗号化バックアップを復元できません。',
  ],
  'passwordMismatch': [
    '请输入至少 12 个字符且两次一致的密码。',
    'Enter matching passwords of at least 12 characters.',
    '12 文字以上の同じパスワードを入力してください。',
  ],
  'passwordError': [
    '密码不正确或备份已损坏，原数据未更改。',
    'Wrong password or damaged backup. Original data was not changed.',
    'パスワードが異なるかバックアップが破損しています。元データは変更していません。',
  ],
  'backupFailed': [
    '备份操作未完成，请检查可用空间、文件或容量限制后重试。',
    'Backup operation incomplete. Check free space, source files and size limits, then retry.',
    'バックアップを完了できませんでした。空き容量、ファイル、容量制限を確認してください。',
  ],
  'export': ['导出完整备份', 'Export full backup', '完全なバックアップを保存'],
  'import': ['导入并预检备份', 'Import and inspect backup', 'バックアップを読込・確認'],
  'unlock': ['输入备份密码', 'Enter backup password', 'バックアップのパスワードを入力'],
  'continue': ['解密并预检', 'Decrypt and inspect', '復号して確認'],
  'cancelled': [
    '已取消，原数据未更改。',
    'Cancelled. Original data was not changed.',
    'キャンセルしました。元データは変更していません。',
  ],
  'saved': ['备份已导出', 'Backup exported', 'バックアップを保存しました'],
  'scan': ['正在检查附件', 'Checking attachments', '添付を確認中'],
  'key': ['正在生成加密密钥', 'Deriving encryption key', '暗号キーを生成中'],
  'write': ['正在分块打包', 'Writing backup chunks', '分割して保存中'],
  'read': ['正在校验备份', 'Verifying backup', 'バックアップを検証中'],
  'missingMedia': ['缺失附件', 'Missing attachments', '見つからない添付'],
  'lastBackup': ['最近一次导出', 'Last export', '前回の保存'],
  'cache': ['备份临时文件', 'Temporary backup files', 'バックアップの一時ファイル'],
  'cacheHint': [
    '仅清理本应用生成的备份缓存，不删除原附件或还原后的文件。',
    'Clean only generated backup cache; original attachments and restored files remain.',
    'このアプリが生成したバックアップのキャッシュのみを削除します。元の添付と復元済みファイルは保持します。',
  ],
  'cacheCheck': ['查看备份缓存', 'Inspect backup cache', 'バックアップのキャッシュを確認'],
  'cacheClear': ['清理选中缓存', 'Clean selected cache', '選択したキャッシュを削除'],
  'cacheConfirm': [
    '清理这些已生成的备份临时文件？',
    'Delete these generated temporary backups?',
    'これらのバックアップ一時ファイルを削除しますか？',
  ],
  'cacheEmpty': ['没有可清理的备份缓存', 'No backup cache to clean', '削除できるキャッシュはありません'],
  'cacheChanged': [
    '缓存已变化，请重新检查。',
    'Cache changed; inspect it again.',
    'キャッシュが変わりました。再確認してください。',
  ],
};
