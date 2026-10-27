part of 'providers.dart';

extension DepartureRoutines on RemindersNotifier {
  DeparturePlan _departurePlan(Reminder owner) => DeparturePlan.fromJson({
    ...owner.details.data,
    'items': owner.details.checklist.map((e) => e.toJson()).toList(),
  });

  /// Runs in the shared mutation queue. A restart retains completed, skipped,
  /// snoozed and unconfirmed dates, and only inserts missing future dates.
  Future<List<Reminder>> _reconcileDepartures(
    DataGeneration generation,
    DateTime now,
  ) async {
    final saved = await _dbHelper.writeTransaction(generation, (db) async {
      final all = (await db.query('Reminders')).map(Reminder.fromJson).toList();
      final byId = {for (final row in all) row.id: row};
      final changes = <Reminder>[];
      for (final owner in all.where(
        (r) => r.details.kind == 'departure' && r.details.planId == null,
      )) {
        final plan = _departurePlan(owner).retained(now);
        final data = {...owner.details.data, ...plan.toJson()};
        var updated = owner;
        if (owner.isVisible && !owner.details.paused) {
          final language = data['notification_language'] as String? ?? 'zh';
          final generated = plan.schedule(now, language: language);
          // Preserve the legacy current date before removing its owner alarm.
          if (owner.triggerTime != null) {
            final event = owner.eventTime ?? owner.triggerTime!;
            final dateKey =
                '${event.year.toString().padLeft(4, '0')}-'
                '${event.month.toString().padLeft(2, '0')}-'
                '${event.day.toString().padLeft(2, '0')}';
            final id = '${owner.id}:departure:$dateKey';
            if (!byId.containsKey(id)) {
              final occurrence =
                  Reminder.fromJson({...owner.toJson(), 'id': id}).copyWith(
                    isRecurring: false,
                    recurrenceRule: 'none',
                    noticeRevision: 0,
                    detailsJson: owner.details.patch({
                      'plan_id': owner.id,
                      'repeat': null,
                      'data': {
                        ...plan.toJson(),
                        'records': [],
                        'weather': null,
                        'departure_occurrence': true,
                        'notification_language': language,
                      },
                    }).encode(),
                  );
              changes.add(occurrence);
              byId[id] = occurrence;
            }
          }
          data['_departure_rolling'] = DeparturePlan.rollingDays;
          data['notification_language'] = language;
          updated = owner.copyWith(
            triggerTime: null,
            eventTime: null,
            recurrenceAnchorTime: null,
            recurrenceEventAnchorTime: null,
            snoozedAt: null,
            isCompleted: false,
            isRecurring: false,
            recurrenceRule: 'none',
            noticeAcknowledgedAt: null,
            upcomingDismissedAt: null,
            noticeRevision:
                owner.noticeRevision + (owner.triggerTime == null ? 0 : 1),
            detailsJson: owner.details.patch({
              'repeat': null,
              'completed_at': null,
              'data': data,
            }).encode(),
          );
          for (final next in generated.occurrences) {
            final previous = byId[next.id];
            if (previous != null) {
              if (previous.details.planId != owner.id) {
                throw StateError('Departure date ID collision');
              }
              continue;
            }
            changes.add(next);
            byId[next.id] = next;
          }
        } else {
          updated = owner.copyWith(
            detailsJson: owner.details.patch({'data': data}).encode(),
          );
        }
        if (!mapEquals(owner.toJson(), updated.toJson())) changes.add(updated);
      }
      for (final row in changes) {
        if (all.any((old) => old.id == row.id)) {
          await db.update(
            'Reminders',
            row.toJson(),
            where: 'id = ?',
            whereArgs: [row.id],
          );
        } else {
          await db.insert('Reminders', row.toJson());
        }
      }
      return changes;
    });
    _dbHelper.checkGeneration(generation);
    if (!mounted) throw StateError('Reminder state is no longer active.');
    _publishManaged(saved);
    return saved;
  }

  Future<ReminderBatchResult> refreshDepartureSchedules({DateTime? now}) =>
      _enqueue(
        (generation) => _dbHelper.runOperation(generation, () async {
          final changed = await _reconcileDepartures(
            generation,
            now ?? DateTime.now(),
          );
          var failures = 0;
          for (final row in changed) {
            if (await _synchronizeReminder(
              row,
              generation,
              cancelOverdue: true,
            )) {
              failures++;
            }
          }
          return ReminderBatchResult(
            changed: changed.length,
            nativeSyncFailures: failures,
          );
        }),
      );

  Future<ReminderActionResult> _setDepartureChecklist(
    Reminder expected,
    String itemId,
    bool done,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (db) async {
        final all = (await db.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final current = all.where((r) => r.id == expected.id).firstOrNull;
        if (current == null ||
            current.detailsJson != expected.detailsJson ||
            current.occurrenceIdentity != expected.occurrenceIdentity) {
          throw const StaleReminderOccurrenceException();
        }
        final item = current.details.checklist
            .where((e) => e.id == itemId)
            .single;
        final ownerId = current.details.planId ?? current.id;
        final owner = all.where((r) => r.id == ownerId).firstOrNull;
        if (owner == null ||
            !owner.isVisible ||
            owner.details.paused ||
            !current.isVisible ||
            current.details.paused) {
          throw const StaleReminderOccurrenceException();
        }
        final plan = _departurePlan(owner);
        final now = DateTime.now();
        final changes = <Reminder>[];
        for (final row in all.where(
          (r) =>
              r.id == current.id ||
              (item.once &&
                  (r.id == ownerId ||
                      (r.details.planId == ownerId &&
                          !r.isCompleted &&
                          r.triggerTime != null &&
                          r.triggerTime!.isAfter(now)))),
        )) {
          final checklist = [
            for (final value in row.details.checklist)
              value.id == itemId ? value.copyWith(done: done) : value,
          ];
          final language =
              row.details.data['notification_language'] as String? ?? 'zh';
          final data = {
            ...row.details.data,
            'items': checklist.map((e) => e.toJson()).toList(),
          };
          changes.add(
            row.copyWith(
              taskSummary: row.eventTime == null
                  ? row.taskSummary
                  : plan.summaryFor(
                      row.eventTime!,
                      checklist,
                      language: language,
                      delivery: row.triggerTime,
                    ),
              detailsJson: row.details
                  .patch({
                    'checklist': checklist.map((e) => e.toJson()).toList(),
                    'data': data,
                  })
                  .record(
                    done ? 'item_done' : 'item_reopened',
                    now,
                    note: itemId,
                  )
                  .encode(),
              noticeRevision: row.noticeRevision + 1,
            ),
          );
        }
        for (final row in changes) {
          await db.update(
            'Reminders',
            row.toJson(),
            where: 'id = ?',
            whereArgs: [row.id],
          );
        }
        return changes;
      });
      _publishManaged(saved);
      var failed = false;
      for (final row in saved) {
        failed =
            await _synchronizeReminder(row, ticket, cancelOverdue: true) ||
            failed;
      }
      return ReminderActionResult(
        ReminderActionDisposition.applied,
        reminder: saved.where((r) => r.id == expected.id).single,
        nativeSyncFailed: failed,
      );
    }),
    generation: generation,
  );

  /// Record consented observations and complete only today's independent date.
  Future<ReminderBatchResult> updateDepartureRecords(
    Reminder expected,
    DeparturePlan plan,
    DataGeneration generation, {
    DateTime? departedAt,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (db) async {
        final all = (await db.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final owner = all.where((r) => r.id == expected.id).firstOrNull;
        if (owner == null ||
            owner.detailsJson != expected.detailsJson ||
            owner.occurrenceIdentity != expected.occurrenceIdentity ||
            owner.details.kind != 'departure' ||
            owner.details.planId != null ||
            plan.id != owner.id ||
            !owner.isVisible ||
            owner.details.paused) {
          throw const StaleReminderOccurrenceException();
        }
        if (departedAt != null && !plan.learningEnabled) {
          throw StateError('Recording disabled');
        }
        final now = DateTime.now();
        final changed = [
          owner.copyWith(
            detailsJson: owner.details
                .patch({
                  'data': {...owner.details.data, ...plan.toJson()},
                })
                .record('departure_record', now)
                .encode(),
          ),
        ];
        if (departedAt != null) {
          for (final row in all.where(
            (r) =>
                r.details.planId == owner.id &&
                r.isVisible &&
                !r.details.paused &&
                !r.isCompleted &&
                r.eventTime != null &&
                r.eventTime!.year == departedAt.year &&
                r.eventTime!.month == departedAt.month &&
                r.eventTime!.day == departedAt.day,
          )) {
            changed.add(
              row.copyWith(
                isCompleted: true,
                noticeRevision: row.noticeRevision + 1,
                detailsJson: row.details
                    .patch({'completed_at': departedAt.toIso8601String()})
                    .record(
                      'completed',
                      now,
                      scheduled: row.eventTime,
                      note: departedAt.toIso8601String(),
                    )
                    .encode(),
              ),
            );
          }
        }
        for (final row in changed) {
          await db.update(
            'Reminders',
            row.toJson(),
            where: 'id = ?',
            whereArgs: [row.id],
          );
        }
        return changed;
      });
      _publishManaged(saved);
      var failures = 0;
      for (final row in saved) {
        if (await _synchronizeReminder(row, ticket, cancelOverdue: true)) {
          failures++;
        }
      }
      return ReminderBatchResult(
        changed: saved.length,
        nativeSyncFailures: failures,
      );
    }),
    generation: generation,
  );

  /// Foreground prefetch only, with consent, per-plan cooldown and generation
  /// fencing. Network waits never hold the database admission or mutation queue.
  Future<void> refreshDepartureWeather(
    DepartureWeatherService service, {
    required bool Function() isActive,
    DateTime? now,
  }) async {
    final generation = _dbHelper.captureGeneration();
    final at = now ?? DateTime.now();
    bool current() => mounted && _dbHelper.isCurrent(generation) && isActive();
    if (!current()) return;
    final owners = _managedReminders
        .where(
          (r) =>
              r.details.kind == 'departure' &&
              r.details.planId == null &&
              r.isVisible &&
              !r.details.paused,
        )
        .toList();
    var requests = 0;
    for (final baseline in owners) {
      if (!current()) return;
      final plan = _departurePlan(baseline);
      if (!plan.weatherEnabled ||
          plan.latitude == null ||
          plan.longitude == null) {
        continue;
      }
      if (!_managedReminders.any(
        (r) =>
            r.details.planId == plan.id &&
            r.canNotify &&
            r.noticeAcknowledgedAt == null &&
            r.triggerTime!.isAfter(at) &&
            !r.triggerTime!.isAfter(at.add(const Duration(hours: 6))),
      )) {
        continue;
      }
      final attempted = _departureWeatherAttempts[plan.id];
      if (attempted != null &&
          at.difference(attempted).abs() < const Duration(minutes: 30)) {
        continue;
      }
      if (plan.weather != null) {
        try {
          final cached = WeatherForecast.fromJson(plan.weather!);
          if (cached.latitude == plan.latitude &&
              cached.longitude == plan.longitude &&
              at.difference(cached.fetchedAt).abs() <
                  const Duration(minutes: 30)) {
            continue;
          }
        } catch (_) {
          /* Replace a malformed snapshot with a fresh public forecast. */
        }
      }
      if (requests++ >= 3) break;
      _departureWeatherAttempts[plan.id] = at;
      try {
        final forecast = await service.fetch(
          plan.latitude!,
          plan.longitude!,
          now: at,
        );
        if (!current()) return;
        await _enqueue(
          (ticket) => _dbHelper.runOperation(ticket, () async {
            final changed = await _dbHelper.writeTransaction(ticket, (
              db,
            ) async {
              if (!current()) return <Reminder>[];
              final all = (await db.query(
                'Reminders',
              )).map(Reminder.fromJson).toList();
              final owner = all.where((r) => r.id == plan.id).firstOrNull;
              if (owner == null ||
                  !owner.isVisible ||
                  owner.details.paused ||
                  owner.detailsJson != baseline.detailsJson ||
                  !current()) {
                return <Reminder>[];
              }
              final latest = _departurePlan(owner);
              if (!latest.weatherEnabled ||
                  latest.latitude != forecast.latitude ||
                  latest.longitude != forecast.longitude) {
                return <Reminder>[];
              }
              final updated = latest.patch({'weather': forecast.toJson()});
              final changes = [
                owner.copyWith(
                  detailsJson: owner.details.patch({
                    'data': {...owner.details.data, ...updated.toJson()},
                  }).encode(),
                ),
              ];
              for (final row in all.where(
                (r) =>
                    r.details.planId == owner.id &&
                    r.canNotify &&
                    r.noticeAcknowledgedAt == null &&
                    r.triggerTime!.isAfter(at),
              )) {
                final summary = updated.summaryFor(
                  row.eventTime!,
                  row.details.checklist,
                  language:
                      row.details.data['notification_language'] as String? ??
                      'zh',
                  delivery: row.triggerTime,
                );
                if (summary != row.taskSummary) {
                  changes.add(
                    row.copyWith(
                      taskSummary: summary,
                      noticeRevision: row.noticeRevision + 1,
                    ),
                  );
                }
              }
              for (final row in changes) {
                await db.update(
                  'Reminders',
                  row.toJson(),
                  where: 'id = ?',
                  whereArgs: [row.id],
                );
              }
              return changes;
            });
            if (!current()) return;
            _publishManaged(changed);
            for (final row in changed) {
              if (!current()) return;
              await _synchronizeReminder(row, ticket);
            }
          }),
          generation: generation,
        );
      } catch (_) {
        _dbHelper.checkGeneration(generation);
        // Saved base items and the explicit unknown-weather fallback remain.
      }
    }
  }
}
