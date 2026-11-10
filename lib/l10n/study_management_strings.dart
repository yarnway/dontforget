String studyManagementText(String language, String key) {
  const labels = {
    'title': ['学习计划', 'Study plans', '学習プラン'],
    'actions': ['管理计划', 'Manage plan', 'プランを管理'],
    'empty': ['暂无学习计划', 'No study plans yet', '学習プランはありません'],
    'batches': ['批次', 'batches', 'セット'],
    'pending': ['待学习', 'pending', '未完了'],
    'paused': ['已暂停', 'Paused', '一時停止中'],
    'completed': ['已完成', 'Completed', '完了'],
    'archived': ['已归档', 'Archived', 'アーカイブ済み'],
    'pause': ['暂停计划', 'Pause plan', 'プランを一時停止'],
    'resume': ['继续计划', 'Resume plan', 'プランを再開'],
    'trash': ['移至回收站', 'Move to trash', 'ゴミ箱に移動'],
    'confirm': [
      '将以下批次移至回收站？',
      'Move these batches to trash?',
      '次のセットをゴミ箱に移動しますか？',
    ],
    'stale': [
      '计划已变更，请重新操作',
      'The plan changed. Try again.',
      'プランが変更されました。再試行してください。',
    ],
    'failed': ['暂时无法更新计划', 'Could not update this plan', 'プランを更新できませんでした'],
  };
  return (labels[key] ?? labels['title']!)[switch (language) {
    'zh' => 0,
    'ja' => 2,
    _ => 1,
  }];
}
