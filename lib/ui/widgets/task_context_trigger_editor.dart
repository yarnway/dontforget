import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'editable_text_menu.dart';

class TaskContextTriggerEditor extends StatelessWidget {
  const TaskContextTriggerEditor({
    super.key,
    required this.type,
    required this.profileValue,
    required this.wifiSsidController,
    required this.promptController,
    required this.onTypeChanged,
    required this.onProfileChanged,
  });

  final String type;
  final String profileValue;
  final TextEditingController wifiSsidController;
  final TextEditingController promptController;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onProfileChanged;

  Widget _buildTriggerTypeRadio(String option, String label) {
    final isSelected = type == option;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: isSelected,
      child: ChoiceChip(
        selected: isSelected,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) => onTypeChanged(option),
        label: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            Icon(Icons.near_me_outlined, size: 16, color: colors.primary),
            const SizedBox(width: 6),
            Text(
              l10n.get('contextTriggerTitle'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _buildTriggerTypeRadio('none', l10n.get('triggerNone')),
            _buildTriggerTypeRadio('wifi', l10n.get('triggerWifi')),
            _buildTriggerTypeRadio('profile', l10n.get('triggerProfile')),
          ],
        ),
        if (type == 'wifi') ...[
          const SizedBox(height: 10),
          TextField(
            controller: wifiSsidController,
            contextMenuBuilder: buildEditableTextMenu,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: l10n.get('wifiSsidLabel'),
              hintText: l10n.get('wifiSsidHint'),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        ] else if (type == 'profile') ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: profileValue,
            decoration: InputDecoration(
              labelText: l10n.get('profileSelectLabel'),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            items: [
              DropdownMenuItem(
                value: 'general',
                child: Text(l10n.get('profileGeneral')),
              ),
              DropdownMenuItem(
                value: 'commute',
                child: Text(l10n.get('profileCommute')),
              ),
              if (!{
                'general',
                'office',
                'deepWork',
                'home',
                'commute',
              }.contains(profileValue))
                DropdownMenuItem(
                  value: profileValue,
                  child: Text(profileValue),
                ),
              DropdownMenuItem(
                value: 'office',
                child: Text(
                  l10n.get('profileOffice'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              DropdownMenuItem(
                value: 'deepWork',
                child: Text(
                  l10n.get('profileDeepWork'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              DropdownMenuItem(
                value: 'home',
                child: Text(
                  l10n.get('profileHome'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
            onChanged: (val) {
              if (val != null) onProfileChanged(val);
            },
          ),
        ],
        if (type != 'none') ...[
          const SizedBox(height: 10),
          TextField(
            controller: promptController,
            contextMenuBuilder: buildEditableTextMenu,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: l10n.get('contextPromptLabel'),
              hintText: l10n.get('contextPromptHint'),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
