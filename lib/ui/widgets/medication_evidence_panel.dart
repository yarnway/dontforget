import 'package:flutter/material.dart';
import '../../l10n/planning_strings.dart';
import '../../models/medication_evidence.dart';

class MedicationEvidencePanel extends StatelessWidget {
  const MedicationEvidencePanel({
    super.key,
    required this.values,
    required this.sources,
    required this.citations,
    required this.resolutions,
    required this.onChoose,
    required this.onSource,
    this.requiredFields = const {},
    this.enabled = true,
  });
  final Map<String, dynamic> values;
  final List<MedicationSource> sources;
  final List<MedicationCitation> citations;
  final Map<String, String> resolutions;
  final Set<String> requiredFields;
  final bool enabled;
  final void Function(String field, String? value) onChoose;
  final void Function(MedicationSource source) onSource;
  @override
  Widget build(BuildContext context) {
    String t(String key) => planningText(context, key);
    final pending = MedicationFacts.conflicts(
      values,
      citations,
      resolutions,
      requiredFields: requiredFields,
    );
    final fields = {...citations.map((e) => e.field), ...pending};
    if (fields.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      key: const ValueKey('medication-evidence'),
      initiallyExpanded: pending.isNotEmpty,
      title: Text(
        '${t('sourceReview')} · ${pending.length} ${t('sourcePending')}',
      ),
      children: [
        for (final field in fields)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${t(field)} · ${t('currentValue')}: ${MedicationFacts.canonical(field, values[field])}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (pending.contains(field))
                    Text(
                      t('sourceConflict'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (!citations.any((e) => e.field == field))
                    Text(t('sourceNoEvidence')),
                  for (final citation in citations.where(
                    (e) => e.field == field,
                  )) ...[
                    Text(
                      '${sources.where((s) => s.id == citation.sourceId).firstOrNull?.label ?? citation.sourceId}: ${citation.value}\n“${citation.quote}”',
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        TextButton(
                          onPressed: !enabled
                              ? null
                              : () => onChoose(field, citation.value),
                          child: Text(t('useSourceValue')),
                        ),
                        TextButton(
                          onPressed: !enabled
                              ? null
                              : () {
                                  final source = sources
                                      .where((s) => s.id == citation.sourceId)
                                      .firstOrNull;
                                  if (source != null) onSource(source);
                                },
                          child: Text(t('viewSource')),
                        ),
                      ],
                    ),
                  ],
                  if (pending.contains(field))
                    TextButton(
                      key: ValueKey('review-current:$field'),
                      onPressed: enabled ? () => onChoose(field, null) : null,
                      child: Text(t('confirmCurrentValue')),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
