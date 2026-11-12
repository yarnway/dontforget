String studyManagementText(String language, String key) {
  const labels = {
    'workload': ['未来7天', 'Next 7 days', '今後7日間'],
    'scheduledWords': ['词已排期', 'words scheduled', '語が予定済み'],
    'dailyLimit': ['每日上限', 'Daily limit', '1日の上限'],
    'newWords': ['新词', 'New', '新出'],
    'reviewWords': ['复习', 'Review', '復習'],
    'overLimit': ['超出上限', 'Over limit', '上限超過'],
    'workloadScope': [
      '按当前排期，未计后续复习',
      'Current schedule; future repeat reviews excluded',
      '現在の予定。今後の反復復習は含みません',
    ],
    'selectPlans': ['选择计划', 'Select plans', 'プランを選択'],
    'cancelSelection': ['取消选择', 'Cancel selection', '選択を解除'],
    'selectedPlans': ['已选计划', 'Selected plans', '選択したプラン'],
    'selectionLimit': [
      '所选计划过多，请分批操作',
      'Select fewer plans per operation',
      'プランを分けて選択してください',
    ],
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
