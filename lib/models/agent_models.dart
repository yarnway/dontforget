import 'reminder.dart';

enum AgentRole {
  manager,
  decomposer,
  scheduler,
}

class AgentStep {
  final AgentRole role;
  final String title;
  final String detail;
  final bool isCompleted;
  final DateTime timestamp;

  AgentStep({
    required this.role,
    required this.title,
    required this.detail,
    this.isCompleted = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get roleName {
    switch (role) {
      case AgentRole.manager:
        return '👔 Manager Agent (管理总控)';
      case AgentRole.decomposer:
        return '🔨 Decomposer Agent (目标拆解)';
      case AgentRole.scheduler:
        return '⏱️ Scheduler Agent (算法排程)';
    }
  }
}

class MultiAgentExecutionResult {
  final String originalInput;
  final String macroGoalTitle;
  final int overallPriorityQuadrant;
  final List<String> decomposedMilestones;
  final List<Reminder> scheduledTasks;
  final List<AgentStep> executionTrace;

  MultiAgentExecutionResult({
    required this.originalInput,
    required this.macroGoalTitle,
    required this.overallPriorityQuadrant,
    required this.decomposedMilestones,
    required this.scheduledTasks,
    required this.executionTrace,
  });
}
