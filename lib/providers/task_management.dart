part of 'providers.dart';

/// Mutations share the reminder queue, recovery admission and notification journal.
extension TaskManagement on RemindersNotifier {
  Future<void> _archiveLearning(DatabaseExecutor db, Reminder source) async {
    final progress = LearningQueueService.decode(source.wordProgressJson);
    if (progress.isEmpty) return;
    final words = VocabularyEntry.parseNotes(source.taskSummary ?? '');
    for (final entry in progress.entries) {
      final word = words
          .where((w) => LearningQueueService.wordKey(w.word) == entry.key)
          .firstOrNull;
      if (word == null) continue;
      final id = 'word-history:${sha256.convert(utf8.encode(entry.key))}';
      final previous = await db.query(
        'Reminders',
        where: 'id = ?',
        whereArgs: [id],
      );
      final old = previous.isEmpty
          ? null
          : Reminder.fromJson(Map<String, dynamic>.from(previous.single));
      if (old != null && old.details.data['learning_archive'] != true) {
        throw StateError('Learning archive ID collision');
      }
      final oldProgress = old == null
          ? null
          : LearningQueueService.decode(old.wordProgressJson)[entry.key];
      if (oldProgress != null &&
          oldProgress.reviewed.isAfter(entry.value.reviewed)) {
        continue;
      }
      final events = <String, TaskEvent>{};
      for (final e in [
        ...?old?.details.history,
        ...source.details.history.where(
          (e) =>
              e.action == 'word_review' &&
              e.note?.startsWith('${entry.key}:') == true,
        ),
      ]) {
        events['${e.at.toIso8601String()}:${e.action}:${e.note}'] = e;
      }
      final history = events.values.toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      final at = DateTime.now();
      final archived = Reminder(
        id: id,
        taskTitle: word.word,
        taskSummary: word.toNotes(),
        quadrantLevel: 2,
        isCompleted: true,
        wordProgressJson: jsonEncode({entry.key: entry.value.toJson()}),
        createdAt: old?.createdAt ?? at,
        detailsJson: TaskDetails(
          kind: 'study',
          archivedAt: at,
          history: history
              .skip(history.length > 512 ? history.length - 512 : 0)
              .toList(),
          data: const {'learning_archive': true},
        ).encode(),
      );
      if (old == null) {
        await db.insert('Reminders', archived.toJson());
      } else {
        await db.update(
          'Reminders',
          archived.toJson(),
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  Future<ReminderActionResult> _lifecycleResult(
    Reminder expected,
    String action,
    DataGeneration generation,
  ) async {
    final result = await changeLifecycle(expected, action, generation);
    final rows = await _dbHelper.read(
      generation,
      (db) => db.query('Reminders', where: 'id = ?', whereArgs: [expected.id]),
    );
    return ReminderActionResult(
      ReminderActionDisposition.applied,
      reminder: Reminder.fromJson(rows.single),
      nativeSyncFailed: result.nativeSyncFailures > 0,
    );
  }

  Future<ReminderActionResult> markNotTaken(
    Reminder expected,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (db) async {
        final rows = await db.query(
          'Reminders',
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        if (rows.isEmpty) throw const StaleReminderOccurrenceException();
        final current = Reminder.fromJson(rows.single);
        if (current.details.kind != 'medication' ||
            current.isCompleted ||
            !current.isVisible ||
            current.details.paused ||
            current.occurrenceIdentity != expected.occurrenceIdentity) {
          throw const StaleReminderOccurrenceException();
        }
        final at = DateTime.now();
        final next = current.copyWith(
          isCompleted: true,
          noticeRevision: current.noticeRevision + 1,
          detailsJson: current.details
              .record(
                'not_taken',
                at,
                scheduled: current.eventTime ?? current.triggerTime,
              )
              .patch({
                'completed_at': at.toIso8601String(),
                'dose_outcome': 'not_taken',
                'data': {...current.details.data, 'dose_taken_at': null},
              })
              .encode(),
        );
        await db.update(
          'Reminders',
          next.toJson(),
          where: 'id = ?',
          whereArgs: [next.id],
        );
        return next;
      });
      _dbHelper.checkGeneration(ticket);
      _publishManaged([saved]);
      return ReminderActionResult(
        ReminderActionDisposition.applied,
        reminder: saved,
        nativeSyncFailed: await _synchronizeReminder(saved, ticket),
      );
    }),
    generation: generation,
  );

  Future<ReminderActionResult> recordDoseTakenAt(
    Reminder expected,
    DateTime actualAt,
    DataGeneration generation, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (actualAt.isAfter(at) || actualAt.year < 1900 || actualAt.year > 2200) {
      throw const FormatException('Actual dose time must not be in the future');
    }
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final rows = await db.query(
            'Reminders',
            where: 'id = ?',
            whereArgs: [expected.id],
          );
          if (rows.isEmpty) throw const StaleReminderOccurrenceException();
          final current = Reminder.fromJson(rows.single);
          if (current.details.kind != 'medication' ||
              !current.isVisible ||
              current.details.paused ||
              !mapEquals(current.toJson(), expected.toJson())) {
            throw const StaleReminderOccurrenceException();
          }
          final wasTaken =
              current.isCompleted &&
              current.details.effectiveDoseOutcome == 'taken';
          final next = current.copyWith(
            isCompleted: true,
            isPinned: false,
            noticeRevision: current.noticeRevision + 1,
            noticeAcknowledgedAt: null,
            upcomingDismissedAt: null,
            detailsJson: current.details
                .record(
                  wasTaken ? 'dose_time_corrected' : 'taken',
                  at,
                  scheduled: current.eventTime ?? current.triggerTime,
                  note: actualAt.toIso8601String(),
                )
                .patch({
                  'completed_at':
                      (wasTaken ? current.details.completedAt ?? at : at)
                          .toIso8601String(),
                  'dose_outcome': 'taken',
                  'data': {
                    ...current.details.data,
                    'dose_taken_at': actualAt.toIso8601String(),
                  },
                })
                .encode(),
          );
          await db.update(
            'Reminders',
            next.toJson(),
            where: 'id = ?',
            whereArgs: [next.id],
          );
          return next;
        });
        _dbHelper.checkGeneration(ticket);
        _publishManaged([saved]);
        return ReminderActionResult(
          ReminderActionDisposition.applied,
          reminder: saved,
          nativeSyncFailed: await _synchronizeReminder(saved, ticket),
        );
      }),
      generation: generation,
    );
  }

  Future<ReminderBatchResult> saveRoutine(
    Reminder owner,
    List<Reminder> children,
    DataGeneration generation, {
    Reminder? baseline,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final planned = List<Reminder>.unmodifiable([owner, ...children]);
    if (planned.length > 1001 ||
        planned.map((r) => r.id).toSet().length != planned.length ||
        children.any(
          (r) =>
              r.details.planId != owner.id ||
              r.triggerTime == null ||
              !r.triggerTime!.isAfter(at),
        )) {
      throw const FormatException('Invalid routine');
    }
    for (final row in planned) {
      TaskDetails.decode(row.detailsJson);
    }
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final all = (await db.query(
            'Reminders',
          )).map(Reminder.fromJson).toList();
          final current = all.where((r) => r.id == owner.id).firstOrNull;
          if (current != null && baseline == null) {
            if (current.details.patch({'history': []}).encode() ==
                    owner.details.patch({'history': []}).encode() &&
                current.taskTitle == owner.taskTitle) {
              return <Reminder>[];
            }
            throw const StaleReminderOccurrenceException();
          }
          if (baseline != null &&
              (current == null ||
                  !mapEquals(current.toJson(), baseline.toJson()))) {
            throw const StaleReminderOccurrenceException();
          }
          final changes = <Reminder>[];
          final ids = children.map((r) => r.id).toSet();
          // A changed meal clock changes the native/date ID. Match the dose's
          // ordinal within its medicine/day too, so a taken or historical dose
          // cannot be recreated as a new future dose on the same day.
          String? doseSlot(Reminder row) {
            if (row.details.kind != 'medication') return null;
            final at = row.eventTime ?? row.triggerTime;
            final data = row.details.data;
            final times = data['times'];
            if (at == null ||
                data['id'] is! String ||
                times is! List ||
                times.any((v) => v is! String)) {
              return null;
            }
            final sorted = List<String>.from(times)..sort();
            final index = sorted.indexOf(
              Medicine.clockText(at.hour * 60 + at.minute),
            );
            return index < 0
                ? null
                : '${data['id']}|${MedicationPlan.dateKey(at)}|$index';
          }

          final protectedDoseSlots = <String>{
            for (final row in all.where(
              (r) =>
                  r.details.planId == owner.id &&
                  (r.isCompleted ||
                      !(r.eventTime ?? r.triggerTime)!.isAfter(at)),
            ))
              if (doseSlot(row) != null) doseSlot(row)!,
          };
          for (final previous in all.where(
            (r) => r.details.planId == owner.id,
          )) {
            if (!ids.contains(previous.id) &&
                !previous.isCompleted &&
                (previous.eventTime ?? previous.triggerTime)!.isAfter(at)) {
              changes.add(
                previous.copyWith(
                  detailsJson: previous.details
                      .patch({'deleted_at': at.toIso8601String()})
                      .record(
                        'plan_changed',
                        at,
                        scheduled: previous.eventTime ?? previous.triggerTime,
                      )
                      .encode(),
                  noticeRevision: previous.noticeRevision + 1,
                ),
              );
            }
          }
          for (final proposed in planned) {
            if (proposed.id != owner.id &&
                protectedDoseSlots.contains(doseSlot(proposed))) {
              continue;
            }
            final old = all.where((r) => r.id == proposed.id).firstOrNull;
            if (old != null &&
                old.id != owner.id &&
                old.details.planId != owner.id) {
              throw StateError('Routine ID collision');
            }
            // Already acted or historical doses keep their original instructions.
            if (old != null &&
                old.id != owner.id &&
                (old.isCompleted ||
                    !(old.eventTime ?? old.triggerTime)!.isAfter(at))) {
              continue;
            }
            changes.add(
              proposed.copyWith(
                noticeRevision: old == null ? 0 : old.noticeRevision + 1,
                detailsJson: proposed.details
                    .patch({
                      'history': old?.details.toJson()['history'] ?? [],
                      'attachment_ids':
                          old?.details.attachmentIds ??
                          proposed.details.attachmentIds,
                    })
                    .record(old == null ? 'created' : 'plan_changed', at)
                    .encode(),
              ),
            );
          }
          for (final row in changes) {
            final exists = all.any((r) => r.id == row.id);
            if (exists) {
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

  Future<ReminderActionResult> editTaskDetails(
    Reminder expected,
    TaskDetails details,
    DataGeneration generation, {
    String action = 'edited',
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final updated = await _dbHelper.writeTransaction(ticket, (db) async {
        final rows = await db.query(
          'Reminders',
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        if (rows.isEmpty) throw const StaleReminderOccurrenceException();
        final current = Reminder.fromJson(rows.single);
        if (current.detailsJson != expected.detailsJson ||
            current.occurrenceIdentity != expected.occurrenceIdentity) {
          throw const StaleReminderOccurrenceException();
        }
        final saved = current.copyWith(
          detailsJson: details.record(action, DateTime.now()).encode(),
          noticeRevision: current.noticeRevision + 1,
          noticeAcknowledgedAt: null,
          upcomingDismissedAt: null,
        );
        await db.update(
          'Reminders',
          saved.toJson(),
          where: 'id = ?',
          whereArgs: [saved.id],
        );
        return saved;
      });
      _dbHelper.checkGeneration(ticket);
      _publishManaged([updated]);
      return ReminderActionResult(
        ReminderActionDisposition.applied,
        reminder: updated,
        nativeSyncFailed: await _synchronizeReminder(
          updated,
          ticket,
          cancelOverdue: true,
        ),
      );
    }),
    generation: generation,
  );

  Future<ReminderActionResult> setChecklistItem(
    Reminder expected,
    String itemId,
    bool done,
    DataGeneration generation,
  ) {
    if (!expected.details.checklist.any((e) => e.id == itemId)) {
      throw const FormatException('Checklist item missing');
    }
    if (expected.details.kind == 'departure') {
      return _setDepartureChecklist(expected, itemId, done, generation);
    }
    return editTaskDetails(
      expected,
      expected.details.patch({
        'checklist': [
          for (final item in expected.details.checklist)
            (item.id == itemId ? item.copyWith(done: done) : item).toJson(),
        ],
      }),
      generation,
      action: done ? 'item_done' : 'item_reopened',
    );
  }

  Future<ReminderBatchResult> changeLifecycle(
    Reminder expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) => _changeLifecycles([expected], action, generation, now: now);

  /// Ordinary root tasks only. Validation and all business writes are atomic;
  /// native failures are reported after the durable transaction has committed.
  Future<ReminderBatchResult> changeLifecycleBatch(
    List<Reminder> expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) {
    if (expected.isEmpty ||
        expected.length > 50 ||
        expected.map((e) => e.id).toSet().length != expected.length) {
      throw const FormatException('Select between 1 and 50 distinct tasks');
    }
    return _changeLifecycles(
      List.unmodifiable(expected),
      action,
      generation,
      now: now,
      ordinaryOnly: true,
    );
  }

  Future<ReminderBatchResult> _changeLifecycles(
    List<Reminder> expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
    bool ordinaryOnly = false,
  }) {
    if (!const {
      'pause',
      'resume',
      'trash',
      'restore',
      'archive',
      'unarchive',
    }.contains(action)) {
      throw ArgumentError(action);
    }
    final at = now ?? DateTime.now();
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final all = (await db.query(
            'Reminders',
          )).map(Reminder.fromJson).toList();
          final targets = <Reminder>[];
          for (final wanted in expected) {
            final target = all.where((r) => r.id == wanted.id).firstOrNull;
            if (target == null ||
                !mapEquals(target.toJson(), wanted.toJson())) {
              throw const StaleReminderOccurrenceException();
            }
            if (ordinaryOnly &&
                (target.details.kind != 'task' ||
                    target.details.planId != null ||
                    all.any((r) => r.details.planId == target.id))) {
              throw StateError('Bulk actions only accept ordinary root tasks');
            }
            if (ordinaryOnly &&
                !switch (action) {
                  'pause' ||
                  'resume' => target.isVisible && !target.isCompleted,
                  'trash' => target.details.deletedAt == null,
                  'restore' => target.details.deletedAt != null,
                  'archive' => target.isVisible && target.isCompleted,
                  _ =>
                    target.details.deletedAt == null &&
                        target.details.archivedAt != null,
                }) {
              throw StateError('Task is not eligible for this bulk action');
            }
            if (action == 'archive' &&
                !target.isCompleted &&
                target.details.kind != 'medicationPlan') {
              throw StateError('Only completed tasks can be archived');
            }
            targets.add(target);
          }
          final changes = <Reminder>[];
          for (final target in targets) {
            for (final row in all.where(
              (r) => r.id == target.id || r.details.planId == target.id,
            )) {
              if (row.id != target.id) {
                if (action == 'trash' && row.details.deletedAt != null) {
                  continue;
                }
                if (action == 'restore' &&
                    (target.details.deletedAt == null ||
                        row.details.deletedAt != target.details.deletedAt)) {
                  continue;
                }
                if (action == 'archive' && row.details.archivedAt != null) {
                  continue;
                }
                if (action == 'unarchive' &&
                    (target.details.archivedAt == null ||
                        row.details.archivedAt != target.details.archivedAt)) {
                  continue;
                }
              }
              if (row.id != target.id &&
                  row.isCompleted &&
                  (action == 'pause' || action == 'resume')) {
                continue;
              }
              final fields = switch (action) {
                'pause' => <String, dynamic>{'paused': true},
                'resume' => <String, dynamic>{'paused': false},
                'trash' => <String, dynamic>{
                  'deleted_at': at.toIso8601String(),
                },
                'restore' => <String, dynamic>{'deleted_at': null},
                'archive' => <String, dynamic>{
                  'archived_at': at.toIso8601String(),
                },
                _ => <String, dynamic>{'archived_at': null},
              };
              var next = row.copyWith(
                detailsJson: row.details
                    .patch(fields)
                    .record(action, at)
                    .encode(),
                noticeRevision: row.noticeRevision + 1,
                noticeAcknowledgedAt: null,
                upcomingDismissedAt: null,
              );
              if (action == 'resume' &&
                  next.isRecurring &&
                  next.triggerTime != null &&
                  !next.triggerTime!.isAfter(at)) {
                final due = next.getNextOccurrence(after: at);
                next = next.copyWith(
                  eventTime:
                      due != null &&
                          row.eventTime != null &&
                          row.triggerTime != null
                      ? row.details.repeat?.anchor != null ||
                                row.details.repeat?.exceptions.isEmpty == false
                            ? RemindersNotifier._eventForTrigger(row, due)
                            : due.add(
                                row.eventTime!.difference(row.triggerTime!),
                              )
                      : row.eventTime,
                  triggerTime: due ?? next.triggerTime,
                  isCompleted: due == null,
                );
              }
              await db.update(
                'Reminders',
                next.toJson(),
                where: 'id = ?',
                whereArgs: [next.id],
              );
              changes.add(next);
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
