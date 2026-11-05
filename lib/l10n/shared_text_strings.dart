String sharedTextLabel(String language, String key) {
  final index = language == 'en'
      ? 1
      : language == 'ja'
      ? 2
      : 0;
  const labels = {
    'title': ['分享草稿', 'Shared drafts', '共有下書き'],
    'hint': [
      '接收分享的文字或链接，确认后保存为备忘。',
      'Review shared text or links, then save a memo.',
      '共有テキストやリンクを確認し、メモとして保存します。',
    ],
    'empty': ['暂时没有分享草稿', 'No shared drafts', '共有下書きはありません'],
    'emptyDraft': ['空草稿', 'Empty draft', '空の下書き'],
    'failed': [
      '分享草稿暂时无法保存，请重试。',
      'Could not save the shared draft. Try again.',
      '共有下書きを保存できません。再試行してください。',
    ],
    'readFailed': [
      '无法读取分享草稿，请稍后重新打开。',
      'Could not read shared drafts. Reopen this page later.',
      '共有下書きを読み込めません。後で開き直してください。',
    ],
    'full': [
      '分享草稿已满，请先处理一些草稿，再重试分享。',
      'Shared drafts are full. Handle some drafts, then retry sharing.',
      '共有下書きがいっぱいです。整理してから再共有してください。',
    ],
    'save': ['保存为备忘', 'Save memo', 'メモとして保存'],
    'retry': ['重试保存草稿', 'Retry saving draft', '下書き保存を再試行'],
    'saved': ['此分享已保存为事项', 'This share was already saved', 'この共有内容は保存済みです'],
    'done': ['完成', 'Done', '完了'],
    'delete': ['删除分享草稿', 'Delete shared draft', '共有下書きを削除'],
    'deleteConfirm': [
      '删除这条分享草稿？',
      'Delete this shared draft?',
      'この共有下書きを削除しますか？',
    ],
    'cancel': ['取消', 'Cancel', 'キャンセル'],
    'continue': ['继续编辑', 'Keep editing', '編集を続ける'],
    'discard': ['放弃未保存修改', 'Discard unsaved edits', '未保存の変更を破棄'],
    'discardHint': [
      '修改尚未保存，仍保留上次成功保存的分享草稿。',
      'Your edits are not saved. The last saved shared draft is retained.',
      '変更を保存できませんでした。前回保存した共有下書きは残ります。',
    ],
  };
  return labels[key]?[index] ?? key;
}
