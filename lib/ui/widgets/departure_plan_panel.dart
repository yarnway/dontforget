import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/departure_plan.dart';
import '../../models/reminder.dart';
import '../../models/task_details.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/departure_weather_service.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import 'inline_feedback.dart';
import 'routine_coverage_panel.dart';

class DeparturePlanPanel extends ConsumerStatefulWidget {
  const DeparturePlanPanel({super.key, this.initialPlanId});
  final String? initialPlanId;
  @override
  ConsumerState<DeparturePlanPanel> createState() => _DeparturePlanPanelState();
}

class _DeparturePlanPanelState extends ConsumerState<DeparturePlanPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  Map<String, dynamic> _draft = DeparturePlan().toJson();
  Reminder? _baseline;
  bool _loaded = false, _busy = false, _preview = false;
  int _revision = 0;
  final _invalid = <String>{};
  final _city = TextEditingController();
  final _cancel = CancelToken();
  List<WeatherCity> _cities = [];
  ({int minute, String reason})? _aiSuggestion;
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
    unawaited(_restore());
  }

  @override
  void dispose() {
    _cancel.cancel('Departure editor closed');
    _city.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      await ref.read(workspaceDraftsProvider.notifier).ready;
      if (!mounted || !context.mounted || !_current) return;
      final data = ref.read(workspaceDraftsProvider)['departureDraft'];
      if (data is Map) {
        {
          final candidate = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(data)),
          );
          DeparturePlan.fromJson(candidate);
          _draft = candidate;
        }
      }
      final initial = ref
          .read(remindersProvider)
          .where(
            (r) =>
                r.id == widget.initialPlanId &&
                r.details.kind == 'departure' &&
                r.isVisible &&
                r.details.planId == null,
          )
          .firstOrNull;
      if (initial != null) _load(initial);
      setState(() => _loaded = true);
    } catch (_) {
      if (mounted && context.mounted && _current) {
        setState(() => _loaded = true);
      }
    }
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

  void _change(VoidCallback edit) {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() {
      edit();
      _preview = false;
      _aiSuggestion = null;
      _revision++;
    });
    unawaited(
      ref
          .read(workspaceDraftsProvider.notifier)
          .put('departureDraft', _draft)
          .catchError((Object _) {
            if (mounted && context.mounted && _current) _feedback(t('failed'));
          }),
    );
  }

  Widget _field(String key, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('${_draft['id']}:$key'),
      initialValue: _draft[key]?.toString() ?? '',
      enabled: !_busy,
      maxLength: key == 'return_minutes'
          ? 4
          : key == 'lead' ||
                key == 'retention_days' ||
                key == 'rain_threshold' ||
                key == 'return_minutes'
          ? 3
          : 160,
      decoration: InputDecoration(
        labelText: label,
        errorText: _invalid.contains(key) ? t('failed') : null,
      ),
      onChanged: (v) => _change(() {
        if (key == 'lead' ||
            key == 'retention_days' ||
            key == 'rain_threshold' ||
            key == 'return_minutes') {
          final n = int.tryParse(v);
          final valid =
              n != null &&
              (key == 'lead'
                  ? n >= 0 && n <= 180
                  : n >= 1 &&
                        n <=
                            (key == 'rain_threshold'
                                ? 100
                                : key == 'return_minutes'
                                ? 1440
                                : 365));
          if (valid) {
            _invalid.remove(key);
            _draft[key] = n;
          } else {
            _invalid.add(key);
          }
        } else {
          _draft[key] = v;
        }
      }),
    ),
  );
  Widget _items(String condition, bool once, String label) {
    final values = (_draft['items'] as List)
        .where((r) => r['condition'] == condition && r['once'] == once)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey('${_draft['id']}:$condition:$once'),
        initialValue: values.map((r) => r['label']).join('\n'),
        enabled: !_busy,
        maxLines: 3,
        decoration: InputDecoration(labelText: label),
        onChanged: (v) => _change(() {
          final others = (_draft['items'] as List)
              .where((r) => r['condition'] != condition || r['once'] != once)
              .toList();
          final labels = v
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toSet();
          if (labels.length + others.length > 64 ||
              labels.any((e) => e.length > 512)) {
            _invalid.add('$condition:$once');
            return;
          }
          _invalid.remove('$condition:$once');
          _draft['items'] = [
            ...others,
            for (final label in labels)
              values.where((r) => r['label'] == label).firstOrNull ??
                  ChecklistItem(
                    const Uuid().v4(),
                    label,
                    once: once,
                    condition: condition,
                  ).toJson(),
          ];
        }),
      ),
    );
  }

  DeparturePlan get _plan => DeparturePlan.fromJson(_draft);
  String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  Future<void> _save() async {
    if (!mounted || !context.mounted || !_current || _busy || !_preview) return;
    setState(() => _busy = true);
    try {
      final schedule = _plan.schedule(
        DateTime.now(),
        language: AppLocalizations.of(context).locale.languageCode,
      );
      final row = schedule.owner;
      final result = await ref
          .read(remindersProvider.notifier)
          .saveRoutine(
            row,
            schedule.occurrences,
            _generation,
            baseline: _baseline,
          );
      if (!mounted || !context.mounted || !_current) return;
      _baseline = ref
          .read(remindersProvider)
          .where((r) => r.id == row.id)
          .firstOrNull;
      _feedback(
        result.nativeSyncFailures > 0
            ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
            : t('saved'),
        repair: result.nativeSyncFailures > 0,
      );
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('departureDraft', null);
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  void _load(Reminder row) {
    if (_busy) return;
    setState(() {
      _baseline = row;
      _draft = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(row.details.data)),
      );
      _draft['items'] = row.details.checklist.map((e) => e.toJson()).toList();
      _preview = false;
      _aiSuggestion = null;
      _revision++;
    });
  }

  Future<void> _updateSaved(DeparturePlan plan, {bool complete = false}) async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        _baseline == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final row = _baseline!;
      final result = await ref
          .read(remindersProvider.notifier)
          .updateDepartureRecords(
            row,
            plan,
            _generation,
            departedAt: complete ? plan.records.last.at : null,
          );
      final failed = result.nativeSyncFailures > 0;
      if (!mounted || !context.mounted || !_current) return;
      final latest = ref
          .read(remindersProvider)
          .where((r) => r.id == row.id)
          .first;
      setState(() {
        _baseline = latest;
        _draft = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(latest.details.data)),
        );
        _draft['items'] = latest.details.checklist
            .map((e) => e.toJson())
            .toList();
        _revision++;
      });
      _feedback(
        failed
            ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
            : t('saved'),
        repair: failed,
      );
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _searchCity() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        _draft['weather_enabled'] != true) {
      return;
    }
    setState(() => _busy = true);
    final revision = _revision;
    try {
      final results = await ref
          .read(departureWeatherProvider)
          .cities(_city.text, cancelToken: _cancel);
      if (mounted && context.mounted && _current && revision == _revision) {
        setState(() => _cities = results);
      }
    } catch (_) {
      if (mounted && context.mounted && _current) {
        _feedback(t('weatherUnknown'));
      }
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _weather() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        _draft['weather_enabled'] != true) {
      return;
    }
    final revision = _revision;
    try {
      final plan = _plan;
      if (plan.latitude == null || plan.longitude == null) {
        throw const FormatException('City required');
      }
      if (plan.weather != null) {
        final cached = WeatherForecast.fromJson(plan.weather!);
        if (DateTime.now().difference(cached.fetchedAt).abs() <
            const Duration(minutes: 10)) {
          setState(() => _preview = false);
          return;
        }
      }
      setState(() => _busy = true);
      final weather = await ref
          .read(departureWeatherProvider)
          .fetch(
            plan.latitude!,
            plan.longitude!,
            now: DateTime.now(),
            cancelToken: _cancel,
          );
      if (!mounted ||
          !_current ||
          revision != _revision ||
          _draft['weather_enabled'] != true) {
        return;
      }
      setState(() {
        _draft['weather'] = weather.toJson();
        _preview = false;
      });
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('departureDraft', _draft);
    } catch (_) {
      if (mounted && context.mounted && _current) {
        _feedback(t('weatherUnknown'));
      }
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _recordWeather(DeparturePlan plan, DateTime at) {
    if (!plan.weatherEnabled || plan.weather == null) return null;
    try {
      final forecast = WeatherForecast.fromJson(plan.weather!);
      final rain =
          forecast.latitude == plan.latitude &&
              forecast.longitude == plan.longitude
          ? forecast.rainDuring(
              at,
              at.add(Duration(minutes: plan.returnMinutes)),
              now: at,
              threshold: plan.rainThreshold,
            )
          : null;
      return {
        'source': WeatherForecast.source,
        'fetched': forecast.fetchedAt.toIso8601String(),
        'city': plan.city,
        'rain': rain,
        'threshold': plan.rainThreshold,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _askAi() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        _draft['learning'] != true) {
      return;
    }
    final plan = _plan, suggestion = _plan.suggestion();
    if (suggestion == null) {
      _feedback(t('notEnough'));
      return;
    }
    final revision = _revision;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(llmServiceProvider)
          .structuredProposal(
            '''Return JSON {"minute":integer,"reason":"short explanation"}. Analyze this aggregate departure-time summary, not location history. Suggest the provided observed median, or a time within 30 minutes of it. Do not infer weather, locations, trips, medical facts or new tasks. The user must confirm any schedule change. Explain in ${AppLocalizations.of(context).locale.languageCode}.''',
            jsonEncode({
              'median_minute': suggestion.minute,
              'samples': suggestion.samples,
              'selected_weekdays': plan.weekdays,
            }),
            ref.read(settingsProvider),
            cancelToken: _cancel,
          );
      if (!mounted ||
          !_current ||
          revision != _revision ||
          _draft['learning'] != true) {
        return;
      }
      final minute = result['minute'], reason = result['reason'];
      if (minute is! int ||
          minute < 0 ||
          minute >= 1440 ||
          (minute - suggestion.minute).abs() > 30 ||
          reason is! String ||
          reason.length > 500) {
        throw const FormatException('Invalid departure suggestion');
      }
      setState(() => _aiSuggestion = (minute: minute, reason: reason));
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final all = ref.watch(remindersProvider);
    final currentOwner = all
        .where((r) => r.id == _baseline?.id && r.isVisible)
        .firstOrNull;
    final plans = all
        .where(
          (r) =>
              r.isVisible &&
              r.details.kind == 'departure' &&
              r.details.planId == null,
        )
        .toList();
    final plan = _plan;
    final suggestion = plan.learningEnabled ? plan.suggestion() : null;
    Reminder? preview;
    try {
      preview = plan.build(DateTime.now());
    } catch (_) {}
    bool? rain;
    WeatherForecast? weather;
    try {
      if (plan.weatherEnabled && plan.weather != null && preview != null) {
        weather = WeatherForecast.fromJson(plan.weather!);
        if (weather.latitude == plan.latitude &&
            weather.longitude == plan.longitude) {
          rain = weather.rainDuring(
            preview.eventTime!,
            preview.eventTime!.add(Duration(minutes: plan.returnMinutes)),
            now: preview.triggerTime!,
            threshold: plan.rainThreshold,
          );
        }
      }
    } catch (_) {
      rain = null;
    }
    final dates =
        all
            .where(
              (r) =>
                  currentOwner != null &&
                  r.details.planId == currentOwner.id &&
                  r.details.kind == 'departure' &&
                  r.isVisible,
            )
            .toList()
          ..sort((a, b) => a.eventTime!.compareTo(b.eventTime!));
    final today = DateTime.now();
    final focusDate =
        dates
            .where(
              (r) =>
                  !r.isCompleted &&
                  r.eventTime!.year == today.year &&
                  r.eventTime!.month == today.month &&
                  r.eventTime!.day == today.day,
            )
            .firstOrNull ??
        dates
            .where((r) => !r.isCompleted && r.triggerTime!.isAfter(today))
            .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final row in plans)
              ActionChip(
                label: Text(
                  '${row.taskTitle}${row.details.paused ? ' · ${t('pause')}' : ''}',
                ),
                onPressed: _busy ? null : () => _load(row),
              ),
          ],
        ),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: Text(t('newPlan')),
          onPressed: _busy
              ? null
              : () => _change(() {
                  _baseline = null;
                  _draft = DeparturePlan().toJson();
                }),
        ),
        _field('title', t('title')),
        _field('place', t('place')),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('departureTime')),
          subtitle: Text(_clock(plan.departureMinute)),
          trailing: const Icon(Icons.schedule),
          onTap: _busy
              ? null
              : () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                      hour: plan.departureMinute ~/ 60,
                      minute: plan.departureMinute % 60,
                    ),
                  );
                  if (mounted && context.mounted && _current && time != null) {
                    _change(
                      () => _draft['minute'] = time.hour * 60 + time.minute,
                    );
                  }
                },
        ),
        _field('lead', t('lead')),
        Text(t('weekdays')),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (var day = 1; day <= 7; day++)
              FilterChip(
                label: Text('$day'),
                selected: plan.weekdays.contains(day),
                onSelected: _busy
                    ? null
                    : (selected) => _change(() {
                        final days = List<int>.from(_draft['weekdays']);
                        if (selected) {
                          days.add(day);
                        } else if (days.length > 1) {
                          days.remove(day);
                        }
                        _draft['weekdays'] = days..sort();
                      }),
              ),
          ],
        ),
        Text(t('calendarHint')),
        _items('always', false, t('items')),
        _items('always', true, t('onceItems')),
        _items('rain', false, t('rainItems')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: plan.weatherEnabled,
          title: Text(t('weatherEnabled')),
          onChanged: _busy
              ? null
              : (v) => _change(() {
                  _draft['weather_enabled'] = v;
                  if (!v) _draft['weather'] = null;
                }),
        ),
        if (plan.weatherEnabled) ...[
          Text(t('weatherConsent')),
          _field('rain_threshold', t('rainThreshold')),
          _field('return_minutes', t('returnWindow')),
          TextField(
            controller: _city,
            enabled: !_busy,
            decoration: InputDecoration(labelText: t('city')),
          ),
          TextButton(
            onPressed: _busy ? null : _searchCity,
            child: Text(t('search')),
          ),
          for (final city in _cities)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _change(() {
                      _draft['city'] = city.name;
                      _draft['latitude'] = city.latitude;
                      _draft['longitude'] = city.longitude;
                      _draft['weather'] = null;
                      _cities = [];
                    }),
              child: Text(city.name),
            ),
          Text(plan.city),
          TextButton.icon(
            onPressed: _busy ? null : _weather,
            icon: const Icon(Icons.cloud_outlined),
            label: Text(t('refreshWeather')),
          ),
          Text(
            rain == null
                ? t('weatherUnknown')
                : rain
                ? t('rain')
                : t('noRain'),
          ),
          if (weather != null)
            Text(
              '${WeatherForecast.source} · ${formatLocalDateTime(weather.fetchedAt)}',
            ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: plan.learningEnabled,
          title: Text(t('learning')),
          onChanged: _busy
              ? null
              : (v) => _change(() => _draft['learning'] = v),
        ),
        Text(t('learningHint')),
        _field('retention_days', t('retention')),
        if (plan.learningEnabled) ...[
          if (_baseline != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _updateSaved(
                      plan.record(
                        DateTime.now(),
                        weather: _recordWeather(plan, DateTime.now()),
                      ),
                      complete: true,
                    ),
              child: Text(t('leaveNow')),
            ),
          Text(
            suggestion == null
                ? t('notEnough')
                : '${t('suggest')}: ${_clock(suggestion.minute)} (${suggestion.samples})',
          ),
          if (suggestion != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _change(() => _draft['minute'] = suggestion.minute),
              child: Text(t('adopt')),
            ),
          TextButton(
            onPressed:
                _busy || !ref.watch(settingsProvider).hasConfiguredExtraction
                ? null
                : _askAi,
            child: Text(t('aiSuggest')),
          ),
          if (_aiSuggestion != null) ...[
            Text(_aiSuggestion!.reason),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      final minute = _aiSuggestion!.minute;
                      _change(() => _draft['minute'] = minute);
                    },
              child: Text('${t('adopt')} ${_clock(_aiSuggestion!.minute)}'),
            ),
          ],
        ],
        if (plan.records.isNotEmpty) ...[
          Text(t('history')),
          for (final record in plan.records.reversed.take(30))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(formatLocalDateTime(record.at)),
              subtitle: Text(
                '${record.place}${record.weather == null ? '' : ' · ${record.weather!['rain'] == true
                          ? t('rain')
                          : record.weather!['rain'] == false
                          ? t('noRain')
                          : t('weatherUnknown')}'}',
              ),
              trailing: IconButton(
                tooltip: t('remove'),
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy
                    ? null
                    : () => _updateSaved(
                        plan.patch({
                          'records': plan.records
                              .where((r) => r.id != record.id)
                              .map((r) => r.toJson())
                              .toList(),
                        }),
                      ),
              ),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _updateSaved(plan.patch({'records': []})),
            child: Text(t('clearRecords')),
          ),
        ],
        FilledButton.tonal(
          onPressed: _busy || preview == null || _invalid.isNotEmpty
              ? null
              : () => setState(() => _preview = true),
          child: Text(t('preview')),
        ),
        if (_preview && preview != null) ...[
          Text(
            '${t('departureTime')}: ${formatLocalDateTime(preview.eventTime!)}\n${formatLocalDateTime(preview.triggerTime!)}',
          ),
          for (final item in plan.items.where(
            (item) =>
                !(item.once && item.done) &&
                (item.condition != 'rain' || rain != false),
          ))
            ListTile(
              dense: true,
              title: Text(item.label),
              subtitle: item.condition == 'rain'
                  ? Text(rain == null ? t('weatherUnknown') : t('rain'))
                  : null,
            ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(t('activate')),
          ),
        ],
        if (currentOwner != null) ...[
          const Divider(),
          RoutineCoveragePanel(planId: currentOwner.id),
          Text(t('independentDates')),
          Text(
            '${dates.length} · ${dates.isEmpty ? '' : formatLocalDateTime(dates.last.eventTime!)}',
          ),
          TextButton(
            onPressed: _busy ? null : () => _load(currentOwner),
            child: Text(t('reloadPlan')),
          ),
          if (focusDate != null)
            Text(formatLocalDateTime(focusDate.eventTime!)),
          for (final item
              in (focusDate?.details.checklist ?? const <ChecklistItem>[])
                  .where(
                    (e) =>
                        !(e.once && e.done) &&
                        (e.condition != 'rain' || rain != false),
                  ))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: item.done,
              title: Text(item.label),
              onChanged: _busy
                  ? null
                  : (v) async {
                      if (!mounted || !context.mounted || !_current) return;
                      setState(() => _busy = true);
                      try {
                        final result = await ref
                            .read(remindersProvider.notifier)
                            .setChecklistItem(
                              focusDate!,
                              item.id,
                              v ?? false,
                              _generation,
                            );
                        if (mounted && context.mounted && _current) {
                          final owner = ref
                              .read(remindersProvider)
                              .where((r) => r.id == currentOwner.id)
                              .firstOrNull;
                          if (owner != null) _load(owner);
                          _feedback(
                            result.nativeSyncFailed
                                ? AppLocalizations.of(
                                    context,
                                  ).get('reminderNativeSyncFailed')
                                : t('saved'),
                            repair: result.nativeSyncFailed,
                          );
                        }
                      } catch (_) {
                        if (mounted && context.mounted && _current) {
                          _feedback(t('failed'));
                        }
                      } finally {
                        if (mounted && context.mounted && _current) {
                          setState(() => _busy = false);
                        }
                      }
                    },
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    if (!mounted || !context.mounted || !_current) return;
                    setState(() => _busy = true);
                    try {
                      final result = await ref
                          .read(remindersProvider.notifier)
                          .changeLifecycle(
                            currentOwner,
                            currentOwner.details.paused ? 'resume' : 'pause',
                            _generation,
                          );
                      if (mounted && context.mounted && _current) {
                        _feedback(
                          result.nativeSyncFailures > 0
                              ? AppLocalizations.of(
                                  context,
                                ).get('reminderNativeSyncFailed')
                              : t('saved'),
                          repair: result.nativeSyncFailures > 0,
                        );
                      }
                    } catch (_) {
                      if (mounted && context.mounted && _current) {
                        _feedback(t('failed'));
                      }
                    } finally {
                      if (mounted && context.mounted && _current) {
                        setState(() => _busy = false);
                      }
                    }
                  },
            child: Text(t(currentOwner.details.paused ? 'resume' : 'pause')),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
