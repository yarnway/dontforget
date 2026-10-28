part of 'providers.dart';

extension OrdinaryRoutines on RemindersNotifier {
  Future<List<Reminder>> _reconcileOrdinary(
    DataGeneration generation,
    DateTime now,
  ) async {
    final changed = await _dbHelper.writeTransaction(generation, (db) async {
      final all = (await db.query('Reminders')).map(Reminder.fromJson).toList();
      final byId = {for (final r in all) r.id: r};
      final changes = <Reminder>[];
      for (final owner in all.where(
        (e) => OrdinarySeries.isOwner(e) && e.isVisible && !e.details.paused,
      )) {
        final generated = OrdinarySeries.schedule(
          OrdinarySeries.template(owner),
          now,
        );
        for (final child in generated.occurrences) {
          final old = byId[child.id];
          if (old != null) {
            if (old.details.planId != owner.id ||
                !OrdinarySeries.isOccurrence(old)) {
              throw StateError('Independent occurrence ID collision');
            }
            continue;
          }
          await db.insert('Reminders', child.toJson());
          changes.add(child);
          byId[child.id] = child;
        }
      }
      return changes;
    });
    _dbHelper.checkGeneration(generation);
    _publishManaged(changed);
    return changed;
  }

  Future<ReminderBatchResult> refreshOrdinarySchedules({DateTime? now}) {
    if (!_managedReminders.any(OrdinarySeries.isOwner)) {
      return Future.value(
        const ReminderBatchResult(changed: 0, nativeSyncFailures: 0),
      );
    }
    return _enqueue(
      (generation) => _dbHelper.runOperation(generation, () async {
        final changed = await _reconcileOrdinary(
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
  }

  Future<ReminderBatchResult> saveOrdinarySeries(
    Reminder template,
    DataGeneration generation, {
    Reminder? baseline,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    // A legacy current date has no stable dated child yet. Do not discard an
    // overdue, snoozed or acknowledged occurrence during explicit conversion.
    if (baseline != null &&
        !OrdinarySeries.isOwner(baseline) &&
        (baseline.snoozedAt != null ||
            baseline.noticeAcknowledgedAt != null ||
            baseline.triggerTime == null ||
            !baseline.triggerTime!.isAfter(at))) {
      throw const FormatException(
        'Resolve the current occurrence before converting',
      );
    }
    final schedule = OrdinarySeries.schedule(template, at);
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final all = (await db.query(
            'Reminders',
          )).map(Reminder.fromJson).toList();
          final old = all.where((e) => e.id == template.id).firstOrNull;
          if (baseline == null
              ? old != null
              : old == null || !mapEquals(old.toJson(), baseline.toJson())) {
            throw const StaleReminderOccurrenceException();
          }
          final changes = <Reminder>[
            schedule.owner.copyWith(
              noticeRevision: (old?.noticeRevision ?? 0) + 1,
            ),
          ];
          final fresh = {for (final row in schedule.occurrences) row.id: row};
          bool inheritedLifecycle(TaskEvent event) =>
              const [
                'pause',
                'resume',
                'trash',
                'restore',
                'archive',
                'unarchive',
              ].contains(event.action) &&
              old?.details.history.any(
                    (e) => e.action == event.action && e.at == event.at,
                  ) ==
                  true;
          for (final child in all.where(
            (e) => e.details.planId == template.id,
          )) {
            if (!OrdinarySeries.isOccurrence(child)) {
              throw StateError('Unexpected ordinary plan member');
            }
            final touched =
                child.isCompleted ||
                child.details.archivedAt != null ||
                (child.details.deletedAt != null &&
                    child.details.history.lastOrNull?.action !=
                        'schedule_replaced') ||
                (child.details.paused &&
                    (!template.details.paused ||
                        child.details.history.lastOrNull?.action != 'pause' ||
                        !inheritedLifecycle(child.details.history.last))) ||
                child.snoozedAt != null ||
                child.noticeAcknowledgedAt != null ||
                child.upcomingDismissedAt != null ||
                child.details.checklist.any((e) => e.done && !e.once) ||
                child.details.history.any(
                  (e) =>
                      !const [
                        'created',
                        'plan_changed',
                        'schedule_replaced',
                      ].contains(e.action) &&
                      !inheritedLifecycle(e),
                ) ||
                child.triggerTime == null ||
                !child.triggerTime!.isAfter(at);
            final next = fresh.remove(child.id);
            if (touched) continue;
            if (next == null) {
              if (child.details.deletedAt != null) continue;
              changes.add(
                child.copyWith(
                  detailsJson: child.details
                      .patch({'deleted_at': at.toIso8601String()})
                      .record('schedule_replaced', at)
                      .encode(),
                  noticeRevision: child.noticeRevision + 1,
                ),
              );
            } else {
              changes.add(
                next.copyWith(
                  noticeRevision: child.noticeRevision + 1,
                  detailsJson: next.details
                      .patch({
                        'history': child.details.history
                            .map((e) => e.toJson())
                            .toList(),
                      })
                      .record('plan_changed', at)
                      .encode(),
                ),
              );
            }
          }
          for (final child in fresh.values) {
            if (all.any((e) => e.id == child.id)) {
              throw StateError('Ordinary occurrence ID collision');
            }
            changes.add(child);
          }
          for (final row in changes) {
            if (all.any((e) => e.id == row.id)) {
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
        _dbHelper.checkGeneration(ticket);
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
  }
}
