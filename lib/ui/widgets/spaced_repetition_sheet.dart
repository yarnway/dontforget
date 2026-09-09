import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';

class SpacedRepetitionSheet extends ConsumerStatefulWidget {
  const SpacedRepetitionSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const SpacedRepetitionSheet(),
    );
  }

  @override
  ConsumerState<SpacedRepetitionSheet> createState() => _SpacedRepetitionSheetState();
}

class _SpacedRepetitionSheetState extends ConsumerState<SpacedRepetitionSheet> {
  int _currentIndex = 0;
  bool _isFlipped = false;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final allTasks = ref.watch(remindersProvider);
    final spacedService = ref.watch(spacedRepetitionServiceProvider);

    final dueCards = spacedService.getDueCards(allTasks);

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16181D) : const Color(0xFFF8FAFC),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 28,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.school,
                    color: Colors.amber,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.translate('spacedRepetitionTitle'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        loc.translate('spacedRepetitionSubtitle'),
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(),

          // Body Content
          Expanded(
            child: dueCards.isEmpty
                ? _buildEmptyState(context, loc, isDark)
                : _buildCardReviewView(context, loc, isDark, dueCards, spacedService),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppLocalizations loc, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline,
                color: Colors.green,
                size: 64,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              loc.translate('noReviewsToday'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              '艾宾浩斯记忆曲线将会在下个遗忘临界点自动提醒您复习。',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardReviewView(
    BuildContext context,
    AppLocalizations loc,
    bool isDark,
    List<Reminder> dueCards,
    dynamic spacedService,
  ) {
    if (_currentIndex >= dueCards.length) {
      _currentIndex = 0;
    }
    final currentTask = dueCards[_currentIndex];
    final currentLevel = currentTask.spacedRepetitionLevel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        children: [
          // Progress Indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${loc.translate('reviewToday')}: ${_currentIndex + 1} / ${dueCards.length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              Row(
                children: List.generate(5, (index) {
                  final filled = index < currentLevel;
                  return Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Icon(
                      filled ? Icons.star : Icons.star_border,
                      size: 16,
                      color: filled ? Colors.amber : (isDark ? Colors.white24 : Colors.black26),
                    ),
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Flip Flashcard
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _isFlipped = !_isFlipped;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF22252F) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isFlipped
                        ? Colors.amber.withValues(alpha: 0.5)
                        : (isDark ? const Color(0xFF383B4A) : const Color(0xFFE2E8F0)),
                    width: _isFlipped ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Tag header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _getQuadrantColor(currentTask.quadrantLevel).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Q${currentTask.quadrantLevel}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: _getQuadrantColor(currentTask.quadrantLevel),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${loc.translate('stageLevel')}$currentLevel (Level $currentLevel)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.amber.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            _isFlipped ? Icons.flip_to_back : Icons.flip_to_front,
                            size: 18,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Front (Title & Basic Info)
                      Text(
                        currentTask.taskTitle,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          height: 1.3,
                        ),
                      ),

                      if (!_isFlipped) ...[
                        const SizedBox(height: 32),
                        Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.touch_app_outlined,
                                size: 36,
                                color: isDark ? Colors.white24 : Colors.black26,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                loc.translate('flipCard'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark ? Colors.white38 : Colors.black45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const Divider(height: 32),
                        // Back (Detailed Answer / Micro Habits / Notes)
                        if (currentTask.taskSummary != null &&
                            currentTask.taskSummary!.isNotEmpty) ...[
                          const Text(
                            '详情备忘 / 核心要点:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            currentTask.taskSummary!,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        if (currentTask.getSubTasksList().isNotEmpty) ...[
                          const Text(
                            '微习惯 / 关键步骤:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ...currentTask.getSubTasksList().map((sub) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
                                    Expanded(
                                      child: Text(
                                        sub,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                          const SizedBox(height: 16),
                        ],

                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                              const SizedBox(width: 8),
                              Text(
                                '提醒时间: ${currentTask.triggerTime != null ? DateFormat('yyyy-MM-dd HH:mm').format(currentTask.triggerTime!) : '未设置'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Action Buttons: Remembered vs Difficult
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent, width: 1.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.refresh, size: 20),
                  label: Text(
                    loc.translate('markDifficult'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _handleReviewResult(currentTask, false, dueCards.length),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle, size: 20),
                  label: Text(
                    loc.translate('markRemembered'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _handleReviewResult(currentTask, true, dueCards.length),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _handleReviewResult(Reminder task, bool remembered, int remainingCount) {
    final spacedService = ref.read(spacedRepetitionServiceProvider);
    final updatedTask = spacedService.reviewCard(task, remembered);

    ref.read(remindersProvider.notifier).updateReminder(updatedTask);

    setState(() {
      _isFlipped = false;
      if (_currentIndex >= remainingCount - 1) {
        _currentIndex = 0;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          remembered
              ? '已晋级到第 ${updatedTask.spacedRepetitionLevel} 记忆阶梯！下次复习: ${DateFormat('MM-dd').format(updatedTask.nextReviewAt!)}'
              : '已重置回第 1 阶梯，将在 24 小时后重新安排复习。',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Color _getQuadrantColor(int level) {
    switch (level) {
      case 1:
        return Colors.red;
      case 2:
        return Colors.blue;
      case 3:
        return Colors.orange;
      case 4:
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }
}
