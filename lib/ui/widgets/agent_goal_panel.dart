import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'editable_text_menu.dart';
import 'workspace_tool_panel.dart';

/// The workspace owns the draft so navigation never silently discards it.
class AgentGoalPanel extends StatelessWidget {
  const AgentGoalPanel({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSubmit,
    required this.onClose,
    required this.onDiscard,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit, onClose, onDiscard;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return WorkspaceToolFrame(
      title: loc.get('multiAgentTitle'),
      icon: Icons.auto_awesome_outlined,
      embedded: true,
      onClose: onClose,
      children: [
        Text(loc.get('multiAgentDesc')),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('agent-goal-input'),
          controller: controller,
          contextMenuBuilder: buildEditableTextMenu,
          minLines: 3,
          maxLines: 6,
          readOnly: busy,
          decoration: InputDecoration(
            labelText: loc.get('agentGoalLabel'),
            hintText: loc.get('agentGoalHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          loc.get('agentDraftHint'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy || value.text.trim().isEmpty ? null : onSubmit,
                icon: const Icon(Icons.rocket_launch_outlined),
                label: Text(loc.get(busy ? 'agentProcessing' : 'agentStart')),
              ),
              if (value.text.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : onDiscard,
                  child: Text(loc.get('discardChanges')),
                ),
            ],
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}
