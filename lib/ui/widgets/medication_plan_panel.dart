import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/medication_plan.dart';
import '../../models/reminder.dart';
import '../../models/medication_evidence.dart';
import '../../services/medication_review_service.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/local_media_store.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import 'inline_feedback.dart';
import 'routine_coverage_panel.dart';
import 'dose_taken_time_dialog.dart';
import 'medication_evidence_panel.dart';

class MedicationPlanPanel extends ConsumerStatefulWidget {
  const MedicationPlanPanel({super.key, this.initialPlanId});
  final String? initialPlanId;
  @override
  ConsumerState<MedicationPlanPanel> createState() =>
      _MedicationPlanPanelState();
}

class _MedicationPlanPanelState extends ConsumerState<MedicationPlanPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  late Map<String, dynamic> _draft;
  Reminder? _baseline;
  String? _record;
  int _formRevision = 0;
  bool _loaded = false, _busy = false, _confirmed = false;
  bool _promptOpen = false;
  List<Reminder>? _preview;
  DateTime _day = DateTime.now();
  final _cancel = CancelToken();
  bool get _current =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(_generation);
  String t(String key) => planningText(context, key);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
    _draft = MedicationPlan().toJson();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      await ref.read(workspaceDraftsProvider.notifier).ready;
      if (!mounted || !context.mounted || !_current) return;
      final raw = ref.read(workspaceDraftsProvider)['medicationDraft'];
      if (raw is Map) {
        final candidate = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(raw)),
        );
        final medicines = candidate['medicines'];
        if (candidate['id'] is! String ||
            medicines is! List ||
            medicines.length > 32 ||
            medicines.any(
              (m) =>
                  m is! Map ||
                  m['id'] is! String ||
                  m['times'] is! List ||
                  m['unresolved'] is! List,
            )) {
          throw const FormatException('Invalid medication draft');
        }
        final sources = candidate['sources'] ?? [];
        final meals = candidate['meals'] ?? [];
        if (sources is! List ||
            sources.length > 8 ||
            meals is! List ||
            meals.length > 8 ||
            meals.any(
              (m) =>
                  m is! Map ||
                  m['id'] is! String ||
                  m['label'] is! String ||
                  m['time'] is! String,
            )) {
          throw const FormatException('Invalid medication draft context');
        }
        sources.map(MedicationSource.fromJson).toList();
        MedicationFacts.citations(
          candidate['provenance'],
          MedicationFacts.planFields,
        );
        MedicationFacts.resolutions(
          candidate['resolved_fields'],
          MedicationFacts.planFields,
        );
        for (final medicine in medicines) {
          Medicine.fromJson(medicine);
          final links = medicine['meal_links'] ?? [];
          if (links is! List ||
              links.any(
                (l) =>
                    l is! Map ||
                    (l['side'] != null &&
                        l['side'] != 'before' &&
                        l['side'] != 'after') ||
                    (l['minutes'] != null && l['minutes'] is! String),
              )) {
            throw const FormatException('Invalid meal draft');
          }
        }
        _draft = candidate;
        _formRevision++;
      }
      if (widget.initialPlanId != null) {
        await ref.read(remindersProvider.notifier).ready;
        if (!_current) return;
        final existing = ref
            .read(remindersProvider)
            .where(
              (r) =>
                  r.id == widget.initialPlanId &&
                  r.details.kind == 'medicationPlan',
            )
            .firstOrNull;
        if (existing != null) {
          _baseline = existing;
          _draft = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(existing.details.data)),
          );
          _formRevision++;
        }
      }
      _record = _draft['record_id'] as String?;
      setState(() => _loaded = true);
    } catch (_) {
      if (mounted && context.mounted && _current) {
        setState(() => _loaded = true);
      }
    }
  }

  @override
  void dispose() {
    _cancel.cancel('Medication editor closed');
    super.dispose();
  }

  Future<void> _persist() async {
    await ref
        .read(workspaceDraftsProvider.notifier)
        .put('medicationDraft', _draft);
  }

  void _change(VoidCallback edit) {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() {
      edit();
      _preview = null;
      _confirmed = false;
    });
    unawaited(
      _persist().catchError((Object _) {
        if (mounted && context.mounted && _current) _feedback(t('failed'));
      }),
    );
  }

  void _feedback(String message, {bool repair = false}) {
    if (!mounted || !context.mounted || !_current) return;
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: repair
            ? SnackBarAction(
                label: AppLocalizations.of(context).get('repairNotifications'),
                onPressed: notificationRepairAction(context).onPressed,
              )
            : null,
      ),
    );
  }

  Widget _field(
    String key,
    String label, {
    Map<String, dynamic>? target,
    int lines = 1,
  }) {
    final data = target ?? _draft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        key: ValueKey(
          '${_draft['id']}:$_formRevision:${target?['id'] ?? 'plan'}:$key',
        ),
        initialValue: data[key]?.toString() ?? '',
        enabled: !_busy,
        maxLines: lines,
        maxLength: key == 'source' ? 16000 : null,
        decoration: InputDecoration(labelText: label),
        onChanged: (value) => _change(() {
          data[key] = value;
          if (key == 'source' && target == null) {
            // Editing the original text invalidates decisions based on it.
            for (final item in [_draft, ...(_draft['medicines'] as List)]) {
              item.remove('resolved_fields');
              item['provenance'] = [
                for (final citation in item['provenance'] as List? ?? [])
                  if (citation['source_id'] != 'manual') citation,
              ];
            }
            final sources = _sources;
            _draft['sources'] = [
              for (final source in sources)
                if (source.id != 'manual') source.toJson(),
              if (value.trim().isNotEmpty)
                MedicationSource(
                  id: 'manual',
                  kind: 'manual',
                  label: t('source'),
                  text: value,
                ).toJson(),
            ];
          }
        }),
      ),
    );
  }

  Future<void> _extract() async {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      await _persist();
      if (!mounted || !context.mounted || !_current) return;
      final records = List.of(ref.read(mediaRecordsProvider));
      final plan = await MedicationReviewService().extract(
        draft: Map<String, dynamic>.from(jsonDecode(jsonEncode(_draft))),
        records: records,
        model: ref.read(llmServiceProvider),
        settings: ref.read(settingsProvider),
        cancelToken: _cancel,
        isCurrent: () => _current,
      );
      if (!mounted || !context.mounted || !_current) return;
      final current = {
        for (final record in ref.read(mediaRecordsProvider))
          record.id: jsonEncode(record.toJson()),
      };
      for (final source in plan.sources.where((s) => s.recordId != null)) {
        final original = records
            .where((r) => r.id == source.recordId)
            .firstOrNull;
        if (original == null ||
            current[source.recordId] != jsonEncode(original.toJson())) {
          throw StateError('Source changed');
        }
      }
      setState(() {
        _draft = plan.toJson();
        _formRevision++;
        _preview = null;
        _confirmed = false;
      });
      await _persist();
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  void _makePreview() {
    try {
      final plan = MedicationPlan.fromJson(_draft);
      _validateCurrentSources(plan);
      if (plan.issues.any((e) => e.contains('Sources'))) {
        _feedback(t('sourceReviewNeeded'));
        return;
      }
      final built = plan.build(now: DateTime.now());
      setState(() => _preview = built.doses);
    } catch (_) {
      _feedback(t('incomplete'));
    }
  }

  void _validateCurrentSources(MedicationPlan plan) {
    final records = {
      for (final record in ref.read(mediaRecordsProvider)) record.id: record,
    };
    for (final source in plan.sources.where((s) => s.recordId != null)) {
      final record = records[source.recordId];
      if (record == null ||
          record.type != source.kind ||
          (source.kind == 'text' &&
              source.text.isNotEmpty &&
              record.contentOrPath != source.text)) {
        throw const FormatException('Medication source changed');
      }
    }
  }

  Future<void> _activate() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        !_confirmed ||
        _preview == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final plan = MedicationPlan.fromJson(_draft);
      _validateCurrentSources(plan);
      final built = plan.build(now: DateTime.now());
      if (_preview!.length != built.doses.length ||
          !List.generate(
            built.doses.length,
            (i) => built.doses[i].id == _preview![i].id,
          ).every((same) => same)) {
        setState(() {
          _preview = built.doses;
          _confirmed = false;
        });
        _feedback(t('previewChanged'));
        return;
      }
      final result = await ref
          .read(remindersProvider.notifier)
          .saveRoutine(
            built.owner,
            built.doses,
            _generation,
            baseline: _baseline,
          );
      if (!mounted || !context.mounted || !_current) return;
      _baseline = ref
          .read(remindersProvider)
          .where((r) => r.id == built.owner.id)
          .firstOrNull;
      _feedback(
        result.nativeSyncFailures > 0
            ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
            : t('saved'),
        repair: result.nativeSyncFailures > 0,
      );
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('medicationDraft', null);
      if (mounted && context.mounted && _current) {
        setState(() => _confirmed = false);
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  void _load(Reminder plan) {
    if (_busy) return;
    setState(() {
      _baseline = plan;
      _formRevision++;
      _draft = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(plan.details.data)),
      );
      _record = plan.recordId;
      _preview = null;
      _confirmed = false;
    });
  }

  Future<void> _lifecycle(Reminder plan, String action) async {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .changeLifecycle(plan, action, _generation);
      if (mounted && context.mounted && _current) {
        _feedback(
          result.nativeSyncFailures > 0
              ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
              : t('saved'),
          repair: result.nativeSyncFailures > 0,
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _dose(Reminder dose, bool taken) async {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      final notifier = ref.read(remindersProvider.notifier);
      final result = taken
          ? await notifier.recordDoseTakenAt(dose, DateTime.now(), _generation)
          : await notifier.markNotTaken(dose, _generation);
      if (mounted && context.mounted && _current) {
        _feedback(
          result.nativeSyncFailed
              ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
              : t('saved'),
          repair: result.nativeSyncFailed,
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _recordDoseTime(Reminder dose) async {
    if (!_current || _busy || _promptOpen) return;
    _promptOpen = true;
    try {
      final actual = await showDialog<DateTime>(
        context: context,
        builder: (_) =>
            DoseTakenTimeDialog(initialTime: dose.details.actualDoseTakenAt),
      );
      if (!mounted || !context.mounted || !_current || actual == null) return;
      setState(() => _busy = true);
      final result = await ref
          .read(remindersProvider.notifier)
          .recordDoseTakenAt(dose, actual, _generation);
      if (mounted && context.mounted && _current) {
        _feedback(
          result.nativeSyncFailed
              ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
              : t('saved'),
          repair: result.nativeSyncFailed,
        );
      }
    } catch (_) {
      if (_current) _feedback(t('failed'));
    } finally {
      _promptOpen = false;
      if (_current) setState(() => _busy = false);
    }
  }

  List<MedicationSource> get _sources {
    final rows = _draft['sources'];
    if (rows is List) return rows.map(MedicationSource.fromJson).toList();
    final record = ref
        .read(mediaRecordsProvider)
        .where((r) => r.id == _record)
        .firstOrNull;
    return record == null
        ? []
        : [
            MedicationSource(
              id: 'record-${record.id}',
              kind: record.type,
              label: '${record.type} · ${record.contentOrPath.split('/').last}',
              recordId: record.id,
            ),
          ];
  }

  List<dynamic> get _meals => _draft['meals'] as List? ?? [];
  Map<String, dynamic> _evidenceValues(Map<String, dynamic> value) {
    if (identical(value, _draft)) return value;
    try {
      final medicine = Medicine.fromJson(value);
      return {
        ...value,
        'times': medicine
            .resolvedMinutes(_meals.map(MealTime.fromJson).toList())
            .map(Medicine.clockText)
            .toList(),
      };
    } on FormatException {
      return value;
    }
  }

  void _chooseFact(Map<String, dynamic> target, String field, String? value) {
    if (_busy || !_current) return;
    try {
      final candidate = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(target)),
      );
      if (value != null) {
        if (field == 'times') {
          candidate[field] = value
              .split(RegExp('[,，、\\s]+'))
              .where((e) => e.isNotEmpty)
              .map((e) => e.replaceAll('：', ':'))
              .toList();
          candidate.remove('meal_links');
        } else {
          if (field == 'start' || field == 'end') MedicationPlan.day(value);
          candidate[field] = value;
        }
      }
      final citations = MedicationFacts.citations(
        candidate['provenance'],
        identical(target, _draft)
            ? MedicationFacts.planFields
            : MedicationFacts.medicineFields,
      );
      candidate['resolved_fields'] = {
        ...?candidate['resolved_fields'] as Map?,
        field: MedicationFacts.fingerprint(
          field,
          (identical(target, _draft)
              ? candidate
              : _evidenceValues(candidate))[field],
          citations,
        ),
      };
      _change(() {
        target
          ..clear()
          ..addAll(candidate);
        if (value != null) _formRevision++;
      });
    } on FormatException {
      _feedback(t('failed'));
    }
  }

  Widget _evidence(Map<String, dynamic> target) => MedicationEvidencePanel(
    values: _evidenceValues(target),
    sources: _sources,
    citations: MedicationFacts.citations(
      target['provenance'],
      identical(target, _draft)
          ? MedicationFacts.planFields
          : MedicationFacts.medicineFields,
    ),
    resolutions: MedicationFacts.resolutions(
      target['resolved_fields'],
      identical(target, _draft)
          ? MedicationFacts.planFields
          : MedicationFacts.medicineFields,
    ),
    requiredFields: _draft['review_sources'] == true
        ? (identical(target, _draft)
              ? MedicationFacts.planFields
              : MedicationFacts.requiredMedicineFields)
        : const {},
    enabled: !_busy,
    onChoose: (field, value) => _chooseFact(target, field, value),
    onSource: _viewSource,
  );
  Future<void> _viewSource(MedicationSource source) async {
    final record = ref
        .read(mediaRecordsProvider)
        .where((r) => r.id == source.recordId)
        .firstOrNull;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.label),
        content: SizedBox(
          width: 600,
          height: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  source.text.isEmpty ? t('sourceAttachmentHint') : source.text,
                ),
                if (source.kind == 'image' && record != null)
                  FutureBuilder<String>(
                    future: LocalMediaStore().resolvePath(record.contentOrPath),
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.file(
                            File(snapshot.data!),
                            cacheWidth: 1024,
                            fit: BoxFit.contain,
                            errorBuilder: (_, e, stack) =>
                                Text(t('sourceMissing')),
                          )
                        : snapshot.hasError
                        ? Text(t('sourceMissing'))
                        : const LinearProgressIndicator(),
                  ),
                if (source.recordId != null && record == null)
                  Text(t('sourceMissing')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).get('cancel')),
          ),
        ],
      ),
    );
  }

  void _removeSource(MedicationSource source) => _change(() {
    final kept = _sources.where((s) => s.id != source.id).toList();
    _draft['sources'] = kept.map((s) => s.toJson()).toList();
    if (source.id == 'manual') _draft['source'] = '';
    _record = kept.map((s) => s.recordId).whereType<String>().firstOrNull;
    _draft['record_id'] = _record;
    for (final target in [
      _draft,
      ...(_draft['medicines'] as List).cast<Map<String, dynamic>>(),
    ]) {
      target['provenance'] = [
        for (final e in target['provenance'] as List? ?? [])
          if (e['source_id'] != source.id) e,
      ];
      target.remove('resolved_fields');
    }
    _formRevision++;
  });
  Widget _mealSettings() => ExpansionTile(
    title: Text(t('mealSettings')),
    children: [
      Text(t('mealSettingsHint')),
      for (final raw in _meals)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                _field(
                  'label',
                  t('mealLabel'),
                  target: raw as Map<String, dynamic>,
                ),
                TextFormField(
                  key: ValueKey('meal-clock:${raw['id']}:$_formRevision'),
                  initialValue: raw['time']?.toString() ?? '',
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: t('mealClock'),
                    hintText: 'HH:mm',
                  ),
                  onChanged: (v) => _change(
                    () => raw['time'] = v.trim().replaceAll('：', ':'),
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _change(() => _meals.remove(raw)),
                  child: Text(t('remove')),
                ),
              ],
            ),
          ),
        ),
      TextButton.icon(
        key: const ValueKey('add-meal'),
        onPressed: _busy || _meals.length >= 8
            ? null
            : () => _change(
                () => (_draft['meals'] ??= <dynamic>[]).add({
                  'id': DateTime.now().microsecondsSinceEpoch.toString(),
                  'label': '',
                  'time': '',
                }),
              ),
        icon: const Icon(Icons.add),
        label: Text(t('addMeal')),
      ),
    ],
  );
  Widget _mealLinks(Map<String, dynamic> medicine) {
    final links = medicine['meal_links'] as List? ?? [];
    return ExpansionTile(
      title: Text(t('mealLink')),
      children: [
        Text(t('mealOffsetHint')),
        for (var i = 0; i < links.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'meal-choice:${medicine['id']}:$i:${_meals.map((m) => m['id']).join(',')}:$_formRevision',
                    ),
                    initialValue:
                        _meals.any((m) => m['id'] == links[i]['meal_id'])
                        ? links[i]['meal_id']
                        : null,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: t('mealLabel')),
                    items: [
                      for (final meal in _meals)
                        DropdownMenuItem(
                          value: meal['id'] as String,
                          child: Text(
                            meal['label']?.toString().isNotEmpty == true
                                ? meal['label'].toString()
                                : t('mealLabel'),
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => _change(() => links[i]['meal_id'] = v ?? ''),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'meal-side:${medicine['id']}:$i:$_formRevision',
                    ),
                    initialValue:
                        links[i]['side'] as String? ??
                        (links[i]['offset'] == null
                            ? null
                            : (links[i]['offset'] as int) < 0
                            ? 'before'
                            : 'after'),
                    isExpanded: true,
                    decoration: InputDecoration(labelText: t('mealSide')),
                    items: [
                      DropdownMenuItem(
                        value: 'before',
                        child: Text(t('beforeMeal')),
                      ),
                      DropdownMenuItem(
                        value: 'after',
                        child: Text(t('afterMeal')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => _change(
                            () => _updateMealOffset(
                              links[i] as Map<String, dynamic>,
                              side: v,
                            ),
                          ),
                  ),
                  TextFormField(
                    key: ValueKey(
                      'meal-offset:${medicine['id']}:$i:$_formRevision',
                    ),
                    initialValue:
                        links[i]['minutes']?.toString() ??
                        (links[i]['offset'] as int?)?.abs().toString() ??
                        '',
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: t('mealOffset')),
                    onChanged: (v) => _change(
                      () => _updateMealOffset(
                        links[i] as Map<String, dynamic>,
                        minutes: v,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _change(() {
                            links.removeAt(i);
                            _formRevision++;
                          }),
                    child: Text(t('remove')),
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          key: ValueKey('add-meal-link:${medicine['id']}'),
          onPressed:
              _busy || links.length + (medicine['times'] as List).length >= 8
              ? null
              : () => _change(
                  () => (medicine['meal_links'] ??= <dynamic>[]).add({
                    'meal_id': '',
                    'offset': null,
                  }),
                ),
          icon: const Icon(Icons.add),
          label: Text(t('addMealLink')),
        ),
      ],
    );
  }

  void _updateMealOffset(
    Map<String, dynamic> link, {
    String? side,
    String? minutes,
  }) {
    link['side'] =
        side ??
        link['side'] ??
        (link['offset'] == null
            ? null
            : (link['offset'] as int) < 0
            ? 'before'
            : 'after');
    link['minutes'] =
        minutes ??
        link['minutes'] ??
        (link['offset'] as int?)?.abs().toString() ??
        '';
    final value = int.tryParse(link['minutes'].toString());
    link['offset'] =
        value == null || value < 0 || value > 180 || link['side'] == null
        ? null
        : link['side'] == 'before'
        ? -value
        : value;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final all = ref.watch(remindersProvider);
    if (_baseline != null) {
      _baseline = all.where((r) => r.id == _baseline!.id).firstOrNull;
    }
    final plans = all
        .where((r) => r.isVisible && r.details.kind == 'medicationPlan')
        .toList();
    final media = ref
        .watch(mediaRecordsProvider)
        .where((r) => const ['image', 'audio', 'text'].contains(r.type))
        .take(200)
        .toList();
    final medicines = _draft['medicines'] as List;
    final daily =
        all
            .where(
              (r) =>
                  r.isVisible &&
                  r.details.kind == 'medication' &&
                  r.details.planId == (_baseline?.id ?? _draft['id']) &&
                  (r.eventTime ?? r.triggerTime)!.year == _day.year &&
                  (r.eventTime ?? r.triggerTime)!.month == _day.month &&
                  (r.eventTime ?? r.triggerTime)!.day == _day.day,
            )
            .toList()
          ..sort((a, b) => a.eventTime!.compareTo(b.eventTime!));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(t('medHint')),
        const SizedBox(height: 12),
        if (plans.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final plan in plans)
                ActionChip(
                  label: Text(
                    '${plan.taskTitle}${plan.details.paused ? ' · ${t('pause')}' : ''}',
                  ),
                  onPressed: _busy ? null : () => _load(plan),
                ),
            ],
          ),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () => _change(() {
                  _baseline = null;
                  _draft = MedicationPlan().toJson();
                  _record = null;
                }),
          icon: const Icon(Icons.add),
          label: Text(t('newPlan')),
        ),
        _field('title', t('title')),
        _field('person', t('person')),
        _field('start', '${t('start')} · YYYY-MM-DD'),
        _field('end', '${t('end')} · YYYY-MM-DD'),
        Text(t('courseRange')),
        const SizedBox(height: 12),
        _field('source', t('source'), lines: 3),
        Text(t('multiSourceHint')),
        for (final source in _sources)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              source.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(source.kind),
            onTap: () => _viewSource(source),
            trailing: IconButton(
              tooltip: t('remove'),
              onPressed: _busy ? null : () => _removeSource(source),
              icon: const Icon(Icons.close),
            ),
          ),
        DropdownButtonFormField<String>(
          key: ValueKey(
            'source:${_sources.map((s) => s.id).join(',')}:${media.length}',
          ),
          isExpanded: true,
          decoration: InputDecoration(labelText: t('addSavedSource')),
          items: [
            for (final record in media.where(
              (r) => !_sources.any((s) => s.recordId == r.id),
            ))
              DropdownMenuItem(
                value: record.id,
                child: Text(
                  '${record.type} · ${record.type == 'text' ? record.contentOrPath : record.contentOrPath.split('/').last}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged:
              _busy ||
                  _sources.length +
                          ((_draft['source']?.toString().trim().isNotEmpty ==
                                      true &&
                                  !_sources.any((s) => s.id == 'manual'))
                              ? 1
                              : 0) >=
                      8
              ? null
              : (value) {
                  final record = media.where((r) => r.id == value).firstOrNull;
                  if (record == null) return;
                  _change(() {
                    _draft['sources'] = [
                      ..._sources.map((s) => s.toJson()),
                      MedicationSource(
                        id: 'record-${record.id}',
                        kind: record.type,
                        label:
                            '${record.type} · ${record.type == 'text' ? record.contentOrPath.substring(0, record.contentOrPath.length.clamp(0, 40)) : record.contentOrPath.split('/').last}',
                        recordId: record.id,
                      ).toJson(),
                    ];
                    _record ??= record.id;
                    _draft['record_id'] = _record;
                  });
                },
        ),
        TextButton.icon(
          onPressed:
              _busy || !ref.watch(settingsProvider).hasConfiguredExtraction
              ? null
              : _extract,
          icon: const Icon(Icons.auto_awesome),
          label: Text(t('extract')),
        ),
        _evidence(_draft),
        _mealSettings(),
        for (var i = 0; i < medicines.length; i++)
          Card(
            key: ValueKey('medicine-form:${medicines[i]['id']}:$_formRevision'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${t('medication')} ${i + 1}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final key in [
                    'name',
                    'strength',
                    'amount',
                    'unit',
                    'meal',
                    'start',
                    'end',
                    'notes',
                    'evidence',
                  ])
                    _field(
                      key,
                      t(key),
                      target: medicines[i] as Map<String, dynamic>,
                      lines: key == 'notes' || key == 'evidence' ? 2 : 1,
                    ),
                  Text(t('medicineDates')),
                  TextFormField(
                    key: ValueKey('${medicines[i]['id']}:times'),
                    initialValue: (medicines[i]['times'] as List).join(', '),
                    enabled: !_busy,
                    decoration: InputDecoration(labelText: t('times')),
                    onChanged: (v) => _change(
                      () => medicines[i]['times'] = v
                          .split(RegExp('[,，、]'))
                          .map((e) => e.trim().replaceAll('：', ':'))
                          .where((e) => e.isNotEmpty)
                          .toList(),
                    ),
                  ),
                  _mealLinks(medicines[i] as Map<String, dynamic>),
                  _evidence(medicines[i] as Map<String, dynamic>),
                  if ((medicines[i]['unresolved'] as List).isNotEmpty) ...[
                    Text(
                      '${t('unresolved')}${(medicines[i]['unresolved'] as List).join('；')}',
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () =>
                                _change(() => medicines[i]['unresolved'] = []),
                      child: Text(t('reviewed')),
                    ),
                  ],
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _change(() => medicines.removeAt(i)),
                    child: Text(t('remove')),
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          onPressed: _busy || medicines.length >= 32
              ? null
              : () => _change(() => medicines.add(Medicine().toJson())),
          icon: const Icon(Icons.add),
          label: Text(t('addMedicine')),
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      try {
                        await _persist();
                        if (mounted && context.mounted && _current) {
                          _feedback(t('draftSaved'));
                        }
                      } catch (_) {
                        if (mounted && context.mounted && _current) {
                          _feedback(t('failed'));
                        }
                      }
                    },
              child: Text(t('saveDraft')),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : _makePreview,
              child: Text(t('preview')),
            ),
          ],
        ),
        if (_preview != null) ...[
          Text('${t('doses')}: ${_preview!.length}'),
          for (final dose in [
            ..._preview!.take(4),
            if (_preview!.length > 4) _preview!.last,
          ])
            ListTile(
              dense: true,
              title: Text(dose.taskTitle),
              subtitle: Text(
                '${formatLocalDateTime(dose.eventTime!)}\n${dose.taskSummary}',
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: _busy
                ? null
                : (v) => setState(() => _confirmed = v ?? false),
            title: Text(t('confirmMedication')),
          ),
          FilledButton(
            onPressed: _busy || !_confirmed ? null : _activate,
            child: Text(t('activate')),
          ),
        ],
        if (_baseline != null) ...[
          RoutineCoveragePanel(planId: _baseline!.id),
          const Divider(),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _lifecycle(
                        _baseline!,
                        _baseline!.details.paused ? 'resume' : 'pause',
                      ),
                child: Text(t(_baseline!.details.paused ? 'resume' : 'pause')),
              ),
              TextButton(
                onPressed: _busy ? null : () => _lifecycle(_baseline!, 'trash'),
                child: Text(t('moveTrash')),
              ),
            ],
          ),
        ],
        const Divider(),
        TextButton.icon(
          icon: const Icon(Icons.calendar_today),
          label: Text('${t('doseRange')} · ${MedicationPlan.dateKey(_day)}'),
          onPressed: _busy
              ? null
              : () async {
                  final day = await showDatePicker(
                    context: context,
                    initialDate: _day,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (mounted && context.mounted && _current && day != null) {
                    setState(() => _day = day);
                  }
                },
        ),
        for (final dose in daily)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${formatLocalDateTime(dose.eventTime!)} · ${dose.taskTitle}',
                  ),
                  Text(dose.taskSummary ?? ''),
                  if (dose.isCompleted)
                    Text(
                      dose.details.effectiveDoseOutcome == 'not_taken'
                          ? t('notTaken')
                          : dose.details.effectiveDoseOutcome == 'taken'
                          ? t('taken')
                          : t('pending'),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy || dose.details.paused
                              ? null
                              : () => _dose(dose, true),
                          child: Text(t('taken')),
                        ),
                        TextButton(
                          onPressed: _busy || dose.details.paused
                              ? null
                              : () => _dose(dose, false),
                          child: Text(t('notTaken')),
                        ),
                      ],
                    ),
                  if (dose.details.actualDoseTakenAt != null)
                    Text(
                      '${t('actualDoseTime')}: ${formatLocalDateTime(dose.details.actualDoseTakenAt!)}',
                    )
                  else if (dose.isCompleted && dose.details.completedAt != null)
                    Text(
                      '${t('recordedDoseTime')}: ${formatLocalDateTime(dose.details.completedAt!)}',
                    ),
                  TextButton.icon(
                    key: ValueKey('dose-time:${dose.id}'),
                    onPressed: _busy || dose.details.paused
                        ? null
                        : () => _recordDoseTime(dose),
                    icon: const Icon(Icons.edit_calendar),
                    label: Text(
                      t(
                        dose.details.actualDoseTakenAt == null
                            ? 'recordDoseTime'
                            : 'correctDoseTime',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
