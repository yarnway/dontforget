import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/knowledge_graph_view.dart';
import 'task_detail_screen.dart';

/// 可视化知识图谱与双向网络界面 (Knowledge Graph Screen)
class KnowledgeGraphScreen extends ConsumerStatefulWidget {
  final String? initialFocusTaskId;

  const KnowledgeGraphScreen({
    super.key,
    this.initialFocusTaskId,
  });

  @override
  ConsumerState<KnowledgeGraphScreen> createState() => _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends ConsumerState<KnowledgeGraphScreen> {
  final TransformationController _transController = TransformationController();
  String? _selectedNodeId;
  int _quadrantFilter = 0; // 0: All, 1: Q1, 2: Q2, 3: Q3, 4: Q4
  String _searchQuery = '';
  late TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selectedNodeId = widget.initialFocusTaskId;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _transController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reminders = ref.watch(remindersProvider);
    final linkService = ref.watch(biDirectionalLinkServiceProvider);

    // 过滤任务
    final filteredReminders = reminders.where((r) {
      if (_quadrantFilter != 0 && r.quadrantLevel != _quadrantFilter) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchTitle = r.taskTitle.toLowerCase().contains(q);
        final matchSummary = (r.taskSummary ?? '').toLowerCase().contains(q);
        if (!matchTitle && !matchSummary) return false;
      }
      return true;
    }).toList();

    final graphData = linkService.buildGraphData(filteredReminders);

    final selectedReminder = _selectedNodeId != null
        ? reminders.where((r) => r.id == _selectedNodeId).firstOrNull
        : null;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF101216) : const Color(0xFFF6F8FA),
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.hub_outlined, size: 20),
            const SizedBox(width: 8),
            Text(
              l10n.get('knowledgeGraphTitle'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${graphData.nodes.length} ${l10n.get('graphNodes')} · ${graphData.edges.length} ${l10n.get('graphEdges')}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.center_focus_strong_outlined),
            tooltip: l10n.get('resetGraphView'),
            onPressed: _resetZoom,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          // 1. 力导向拓扑画布 (支持 0.2x ~ 3.5x 缩放与平移)
          InteractiveViewer(
            transformationController: _transController,
            minScale: 0.2,
            maxScale: 3.5,
            boundaryMargin: const EdgeInsets.all(1200),
            child: SizedBox(
              width: 2400,
              height: 2400,
              child: Center(
                child: KnowledgeGraphView(
                  graphData: graphData,
                  selectedNodeId: _selectedNodeId,
                  onNodeSelected: (node) {
                    setState(() {
                      _selectedNodeId = node?.id;
                    });
                  },
                  onNodeDoubleTap: (node) {
                    final target = reminders.where((r) => r.id == node.id).firstOrNull;
                    if (target != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TaskDetailScreen(task: target),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ),

          // 2. 顶部象限过滤与关键词搜索工具条
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Row(
              children: [
                // 象限筛选胶囊
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.black87 : Colors.white).withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.black12,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildFilterChip(0, l10n.get('all')),
                      _buildFilterChip(1, 'Q1', color: const Color(0xFFEF5350)),
                      _buildFilterChip(2, 'Q2', color: const Color(0xFFFFA726)),
                      _buildFilterChip(3, 'Q3', color: const Color(0xFF42A5F5)),
                      _buildFilterChip(4, 'Q4', color: const Color(0xFF66BB6A)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // 搜索输入框
                Expanded(
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black87 : Colors.white).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark ? Colors.white12 : Colors.black12,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        hintText: l10n.get('searchGraphHint'),
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.grey.shade500 : Colors.grey.shade400,
                        ),
                        prefixIcon: const Icon(Icons.search, size: 16),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 14),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      ),
                      onChanged: (val) {
                        setState(() => _searchQuery = val.trim());
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. 悬浮微卡 (选中节点时弹出)
          if (selectedReminder != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: _buildInspectorCard(context, selectedReminder, reminders, l10n, isDark),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(int level, String label, {Color? color}) {
    final isSelected = _quadrantFilter == level;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        setState(() => _quadrantFilter = level);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? (color ?? Theme.of(context).colorScheme.primary).withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? (color ?? Theme.of(context).colorScheme.primary)
                    : (isDark ? Colors.grey.shade400 : Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInspectorCard(
    BuildContext context,
    Reminder task,
    List<Reminder> allReminders,
    AppLocalizations l10n,
    bool isDark,
  ) {
    Color qColor;
    switch (task.quadrantLevel) {
      case 1:
        qColor = const Color(0xFFEF5350);
        break;
      case 2:
        qColor = const Color(0xFFFFA726);
        break;
      case 3:
        qColor = const Color(0xFF42A5F5);
        break;
      case 4:
      default:
        qColor = const Color(0xFF66BB6A);
        break;
    }

    // 查找已关联的任务对象
    final linkedTasks = allReminders.where((r) => task.linkedTaskIds.contains(r.id)).toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1E222B) : Colors.white).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: qColor.withValues(alpha: 0.4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: qColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: qColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  'Q${task.quadrantLevel}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: qColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (task.isDynamicallyPromoted)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                  ),
                  child: const Text(
                    '⚡ 跃迁',
                    style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                  ),
                ),
              Expanded(
                child: Text(
                  task.taskTitle,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _selectedNodeId = null),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (task.taskSummary != null && task.taskSummary!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              task.taskSummary!,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (linkedTasks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final lt in linkedTasks.take(4))
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() => _selectedNodeId = lt.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.link, size: 12, color: Colors.indigoAccent),
                          const SizedBox(width: 4),
                          Text(
                            lt.taskTitle.length > 8 ? '${lt.taskTitle.substring(0, 8)}...' : lt.taskTitle,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text(l10n.get('openTaskDetail'), style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TaskDetailScreen(task: task),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
