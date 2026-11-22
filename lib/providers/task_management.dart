part of 'providers.dart';

/// Mutations share the reminder queue, recovery admission and notification journal.
extension TaskManagement on RemindersNotifier {
  Future<int> clearWordArchives(
    WordArchiveCleanupPreview preview,
    DataGeneration generation, {
    DateTime? now,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final deleted = await _dbHelper.writeTransaction(ticket, (db) async {
        final rows = (await db.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final at = now ?? DateTime.now();
        if (!LearningQueueService.sameDay(preview.preparedAt, at)) {
          throw const WordArchiveCleanupStale();
        }
        final current = WordArchiveCleanupService.preview(rows, now: at);
        final ids = preview.candidates.map((r) => r.id).toSet();
        if (current.snapshot != preview.snapshot ||
            !setEquals(ids, current.candidates.map((r) => r.id).toSet())) {
          throw const WordArchiveCleanupStale();
        }
        for (final id in ids) {
          await db.delete('Reminders', where: 'id = ?', whereArgs: [id]);
        }
        return ids.length;
      });
      _dbHelper.checkGeneration(ticket);
      if (deleted > 0) await _loadReminders(ticket, runEffects: false);
      return deleted;
    }),
    generation: generation,
  );

  String? _editDetails(Reminder row) {
    if (row.details.kind != 'departure' ||
        row.details.planId != null ||
        row.details.data['_weather_refresh'] == null) {
      return row.detailsJson;
    }
    return row.details.patch({
      'data': {...row.details.data}..remove('_weather_refresh'),
    }).encode();
  }

  bool _sameEditSnapshot(Reminder a, Reminder b) => mapEquals(
    {...a.toJson(), 'details_json': _editDetails(a)},
    {...b.toJson(), 'details_json': _editDetails(b)},
  );

  TaskDetails _preserveWeatherRefresh(Reminder current, TaskDetails proposed) {
    if (current.details.kind != 'departure' || current.details.planId != null) {
      return proposed;
    }
    final data = {...proposed.data}..remove('_weather_refresh');
    if (data['weather_enabled'] == true &&
        data['latitude'] == current.details.data['latitude'] &&
        data['longitude'] == current.details.data['longitude'] &&
        current.details.data['_weather_refresh'] != null) {
      data['_weather_refresh'] = current.details.data['_weather_refresh'];
    }
    return proposed.patch({'data': data});
  }

  /// Classification only: no deadlines, outcomes or native schedules change.
  Future<ReminderBatchResult> updateMetadataBatch(
    List<Reminder> expected,
    TaskMetadataPatch patch,
    DataGeneration generation, {
    DateTime? now,
  }) {
    if (expected.isEmpty ||
        expected.length > 50 ||
        expected.map((e) => e.id).toSet().length != expected.length) {
      throw const FormatException('Select between 1 and 50 distinct tasks');
    }
    final frozen = List<Reminder>.unmodifiable(expected);
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final all = (await db.query(
            'Reminders',
          )).map(Reminder.fromJson).toList();
          final byId = <String, Reminder>{for (final r in all) r.id: r};
          final planParentIds = <String>{
            for (final r in all)
              if (r.details.planId != null) r.details.planId!,
          };
          final changes = <Reminder>[];
          for (final wanted in frozen) {
            final row = byId[wanted.id];
            if (row == null ||
                !mapEquals(row.toJson(), wanted.toJson()) ||
                row.details.kind != 'task' ||
                row.details.planId != null ||
                row.details.deletedAt != null ||
                planParentIds.contains(row.id)) {
              throw const StaleReminderOccurrenceException();
            }
            final details = patch.apply(row.details);
            if (details.project == row.details.project &&
                listEquals(details.tags, row.details.tags)) {
              continue;
            }
            final next = row.copyWith(
              detailsJson: details
                  .record('metadata_updated', now ?? DateTime.now())
                  .encode(),
            );
            await db.update(
              'Reminders',
              next.toJson(),
              where: 'id = ?',
              whereArgs: [row.id],
            );
            changes.add(next);
          }
          return changes;
        });
        _dbHelper.checkGeneration(ticket);
        _publishManaged(saved);
        return ReminderBatchResult(
          changed: saved.length,
          nativeSyncFailures: 0,
        );
      }),
      generation: generation,
    );
  }

  /// One root and its explicitly previewed members, across every task kind.
  Future<ReminderBatchResult> changeContentArchive(
    Reminder expected,
    List<Reminder> children,
    bool archived,
    DataGeneration generation,
  ) {
    if (expected.details.planId != null ||
        expected.details.data['learning_archive'] == true ||
        children.length > 1000 ||
        children.any((e) => e.details.planId != expected.id) ||
        {expected.id, ...children.map((e) => e.id)}.length !=
            children.length + 1) {
      throw const FormatException('Invalid archive group');
    }
    return _changeLifecycles(
      [expected],
      archived ? 'archive' : 'unarchive',
      generation,
      contentBaseline: {
        for (final e in [expected, ...children]) e.id: e,
      },
    );
  }

  Future<List<Reminder>> _archiveLearning(
    DatabaseExecutor db,
    Reminder source,
  ) async {
    final progress = LearningQueueService.decode(source.wordProgressJson);
    if (progress.isEmpty) return const [];
    final words = VocabularyEntry.parseNotes(source.taskSummary ?? '');
    final archivedRows = <Reminder>[];
    for (final entry in progress.entries) {
      final word = words
          .where((w) => LearningQueueService.wordKey(w.word) == entry.key)
          .firstOrNull;
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
          LearningQueueService.isNewerProgress(oldProgress, entry.value)) {
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
        taskTitle: word?.word ?? old?.taskTitle ?? entry.key,
        taskSummary: word?.toNotes() ?? old?.taskSummary,
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
      archivedRows.add(archived);
    }
    return archivedRows;
  }

  Future<ReminderActionResult> _lifecycleResult(
    Reminder expected,
    String action,
    DataGeneration generation, {
    bool ordinaryOnly = false,
  }) async {
    final saved = <Reminder>[];
    final result = await _changeLifecycles(
      [expected],
      action,
      generation,
      ordinaryOnly: ordinaryOnly,
      savedOut: saved,
    );
    final updated = saved.where((r) => r.id == expected.id).firstOrNull;
    if (updated == null) {
      throw const StaleReminderOccurrenceException();
    }
    return ReminderActionResult(
      ReminderActionDisposition.applied,
      reminder: updated,
      nativeSyncFailed: result.nativeSyncFailures > 0,
    );
  }

  Future<ReminderActionResult> adoptLanSyncTrash(
    LanSyncConflict conflict,
    Reminder expected,
    DataGeneration generation,
  ) async {
    if (!conflict.canAdoptTrash(expected)) {
      return const ReminderActionResult(ReminderActionDisposition.stale);
    }
    try {
      return await _lifecycleResult(
        expected,
        conflict.peer.inTrash ? 'trash' : 'restore',
        generation,
        ordinaryOnly: true,
      );
    } on StaleReminderOccurrenceException {
      return const ReminderActionResult(ReminderActionDisposition.stale);
    }
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
              (current == null || !_sameEditSnapshot(current, baseline))) {
            throw const StaleReminderOccurrenceException();
          }
          final departureEdit = current?.details.kind == 'departure';
          if (departureEdit &&
              (!current!.isVisible ||
                  all.any(
                    (r) =>
                        r.details.planId == owner.id &&
                        r.details.kind != 'departure',
                  ))) {
            throw const StaleReminderOccurrenceException();
          }
          bool protectedDeparture(Reminder row) =>
              departureEdit &&
              row.details.planId == owner.id &&
              (row.isCompleted ||
                  row.details.archivedAt != null ||
                  (row.details.deletedAt != null &&
                      row.details.history.lastOrNull?.action !=
                          'plan_changed') ||
                  row.snoozedAt != null ||
                  row.noticeAcknowledgedAt != null ||
                  row.upcomingDismissedAt != null ||
                  (row.details.paused && current?.details.paused != true) ||
                  row.details.checklist.any((e) => e.done && !e.once) ||
                  row.details.history.any(
                    (e) =>
                        !const ['created', 'plan_changed'].contains(e.action) &&
                        current?.details.history.any(
                              (p) => p.action == e.action && p.at == e.at,
                            ) !=
                            true,
                  ));
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

          final byId = <String, Reminder>{for (final r in all) r.id: r};
          final existingPlanChildren = <Reminder>[
            for (final r in all)
              if (r.details.planId == owner.id) r,
          ];
          final protectedDoseSlots = <String>{
            for (final row in existingPlanChildren)
              if (row.isCompleted ||
                  !(row.eventTime ?? row.triggerTime)!.isAfter(at))
                if (doseSlot(row) != null) doseSlot(row)!,
          };
          for (final previous in existingPlanChildren) {
            if (!ids.contains(previous.id) &&
                !protectedDeparture(previous) &&
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
            final old = byId[proposed.id];
            if (old != null &&
                old.id != owner.id &&
                old.details.planId != owner.id) {
              throw StateError('Routine ID collision');
            }
            // Already acted or historical doses keep their original instructions.
            if (old != null &&
                old.id != owner.id &&
                (protectedDeparture(old) ||
                    old.isCompleted ||
                    !(old.eventTime ?? old.triggerTime)!.isAfter(at))) {
              continue;
            }
            changes.add(
              proposed.copyWith(
                noticeRevision: old == null ? 0 : old.noticeRevision + 1,
                detailsJson:
                    (old == null
                            ? proposed.details
                            : _preserveWeatherRefresh(old, proposed.details))
                        .patch({
                          'history': old?.details.toJson()['history'] ?? [],
                          if (departureEdit)
                            'paused':
                                current!.details.paused ||
                                proposed.details.paused,
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
            if (byId.containsKey(row.id)) {
              await db.update(
                'Reminders',
                row.toJson(),
                where: 'id = ?',
                whereArgs: [row.id],
              );
            } else {
              await db.insert('Reminders', row.toJson());
              byId[row.id] = row;
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
        if (_editDetails(current) != _editDetails(expected) ||
            current.occurrenceIdentity != expected.occurrenceIdentity) {
          throw const StaleReminderOccurrenceException();
        }
        final saved = current.copyWith(
          detailsJson: _preserveWeatherRefresh(
            current,
            details,
          ).record(action, DateTime.now()).encode(),
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
    Map<String, Reminder>? contentBaseline,
    List<StudyPlanGroup>? studyPlanBaselines,
    List<Reminder>? savedOut,
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
          if (studyPlanBaselines != null &&
              !StudyPlanGroup.matchesSnapshots(all, studyPlanBaselines)) {
            throw const StaleReminderOccurrenceException();
          }
          if (contentBaseline != null) {
            final root = expected.single;
            final members = all
                .where((e) => e.id == root.id || e.details.planId == root.id)
                .toList();
            if (root.details.deletedAt != null ||
                (action == 'archive'
                    ? root.details.archivedAt != null
                    : root.details.archivedAt == null) ||
                members.length != contentBaseline.length ||
                members.any(
                  (e) =>
                      contentBaseline[e.id] == null ||
                      !mapEquals(e.toJson(), contentBaseline[e.id]!.toJson()),
                )) {
              throw const StaleReminderOccurrenceException();
            }
          }
          final byId = <String, Reminder>{for (final r in all) r.id: r};
          final childrenByPlan = <String, List<Reminder>>{};
          for (final r in all) {
            final pid = r.details.planId;
            if (pid != null) {
              (childrenByPlan[pid] ??= <Reminder>[]).add(r);
            }
          }
          final targets = <Reminder>[];
          for (final wanted in expected) {
            final target = byId[wanted.id];
            if (target == null ||
                !mapEquals(target.toJson(), wanted.toJson())) {
              throw const StaleReminderOccurrenceException();
            }
            if (ordinaryOnly &&
                (target.details.kind != 'task' ||
                    target.details.planId != null ||
                    childrenByPlan.containsKey(target.id))) {
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
            if (contentBaseline == null &&
                action == 'archive' &&
                !target.isCompleted &&
                target.details.kind != 'medicationPlan') {
              throw StateError('Only completed tasks can be archived');
            }
            targets.add(target);
          }
          final changes = <Reminder>[];
          for (final target in targets) {
            final group = <Reminder>[target, ...?childrenByPlan[target.id]];
            for (final row in group) {
              if (contentBaseline != null && row.details.deletedAt != null) {
                continue;
              }
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
                  studyPlanBaselines == null &&
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
        savedOut?.addAll(saved);
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
