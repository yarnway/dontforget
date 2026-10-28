part of 'providers.dart';

extension RoutineDates on RemindersNotifier {
  /// A single historical date never advances, regenerates or changes its siblings.
  /// Medication outcomes stay in the dedicated dose review flow.
  Future<ReminderActionResult> changeRoutineDate(
    Reminder expected,
    Reminder parent,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) {
    if (!const [
      'complete',
      'skip',
      'reopen',
      'trash',
      'restore',
    ].contains(action)) {
      throw ArgumentError.value(action);
    }
    final at = now ?? DateTime.now();
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        final saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final rows = (await db.query(
            'Reminders',
            where: 'id IN (?, ?)',
            whereArgs: [expected.id, parent.id],
          )).map(Reminder.fromJson).toList();
          final owner = rows.where((e) => e.id == parent.id).firstOrNull;
          final child = rows.where((e) => e.id == expected.id).firstOrNull;
          if (owner == null ||
              child == null ||
              !_sameEditSnapshot(owner, parent) ||
              !mapEquals(child.toJson(), expected.toJson()) ||
              child.details.planId != owner.id ||
              !owner.isVisible ||
              owner.details.paused ||
              !(OrdinarySeries.isOwner(owner) &&
                      OrdinarySeries.isOccurrence(child) ||
                  owner.details.kind == 'departure' &&
                      owner.details.planId == null &&
                      child.details.kind == 'departure') ||
              (action == 'restore'
                  ? child.details.deletedAt == null ||
                        child.details.archivedAt != null
                  : !child.isVisible) ||
              (const ['complete', 'skip'].contains(action) &&
                  child.isCompleted) ||
              (action == 'reopen' && !child.isCompleted)) {
            throw const StaleReminderOccurrenceException();
          }
          final data = child.details
              .patch({
                if (action == 'trash') 'deleted_at': at.toIso8601String(),
                if (action == 'restore') 'deleted_at': null,
                if (const ['complete', 'skip', 'reopen'].contains(action))
                  'completed_at': action == 'reopen'
                      ? null
                      : at.toIso8601String(),
              })
              .record(
                switch (action) {
                  'complete' => 'completed',
                  'skip' => 'skipped',
                  'reopen' => 'reopened',
                  _ => action,
                },
                at,
                scheduled:
                    child.eventTime ??
                    TaskDetails.date(child.details.data['scheduled_at']) ??
                    child.triggerTime,
              );
          final next = child.copyWith(
            isCompleted: const ['complete', 'skip'].contains(action)
                ? true
                : action == 'reopen'
                ? false
                : child.isCompleted,
            noticeRevision: child.noticeRevision + 1,
            noticeAcknowledgedAt: null,
            upcomingDismissedAt: null,
            detailsJson: data.encode(),
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
          nativeSyncFailed:
              saved.canNotify &&
                  saved.triggerTime != null &&
                  !saved.triggerTime!.isAfter(at)
              ? await _synchronizeNotification(
                  saved.id,
                  ticket,
                  () => _notifications.cancelReminderStrict(saved.id),
                  cancellation: true,
                )
              : await _synchronizeReminder(saved, ticket, cancelOverdue: true),
        );
      }),
      generation: generation,
    );
  }
}
