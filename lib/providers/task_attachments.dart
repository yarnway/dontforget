part of 'providers.dart';

/// Attachments do not alter an occurrence or cancel an already-delivered notice.
/// File imports are admitted by the existing recovery/operation queue, and the
/// media row plus reminder reference commit in one database transaction.
extension TaskAttachments on RemindersNotifier {
  Future<Reminder> _attachmentTarget(
    DatabaseExecutor db,
    Reminder expected,
  ) async {
    final rows = await db.query(
      'Reminders',
      where: 'id = ?',
      whereArgs: [expected.id],
    );
    if (rows.isEmpty) throw const StaleReminderOccurrenceException();
    final current = Reminder.fromJson(rows.single);
    if (!current.isVisible ||
        !listEquals(
          current.details.attachmentIds,
          expected.details.attachmentIds,
        )) {
      throw const StaleReminderOccurrenceException();
    }
    return current;
  }

  Future<Reminder> addTaskAttachment(
    Reminder expected,
    String sourcePath,
    DataGeneration generation, {
    TaskAttachmentFiles? files,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final current = await _dbHelper.read(
        ticket,
        (db) => _attachmentTarget(db, expected),
      );
      if (current.details.attachmentIds.length >= TaskDetails.maxAttachments) {
        throw const FormatException('Attachment limit reached');
      }
      final storage = files ?? TaskAttachmentFiles();
      final media = await storage.import(sourcePath);
      late Reminder saved;
      try {
        saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final latest = await _attachmentTarget(db, expected);
          final details = latest.details.patch({
            'attachment_ids': [...latest.details.attachmentIds, media.id],
          });
          final next = latest.copyWith(detailsJson: details.encode());
          await db.insert('MediaRecords', media.toJson());
          await db.update(
            'Reminders',
            next.toJson(),
            where: 'id = ?',
            whereArgs: [next.id],
          );
          return next;
        });
      } catch (_) {
        await storage.discard(media); // The transaction did not commit.
        rethrow;
      }
      storage.committed(media);
      _dbHelper.checkGeneration(ticket);
      _publishManaged([saved]);
      return saved;
    }),
    generation: generation,
  );

  Future<Reminder> setTaskAttachmentLinked(
    Reminder expected,
    String mediaId,
    bool linked,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (db) async {
        final current = await _attachmentTarget(db, expected);
        final ids = current.details.attachmentIds.toList();
        if (linked) {
          final media = await db.query(
            'MediaRecords',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [mediaId],
          );
          if (media.isEmpty) throw const FormatException('Attachment missing');
          if (!ids.contains(mediaId)) ids.add(mediaId);
        } else {
          ids.remove(mediaId);
        }
        final next = current.copyWith(
          detailsJson: current.details.patch({'attachment_ids': ids}).encode(),
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
      return saved;
    }),
    generation: generation,
  );

  Future<Reminder> saveSharedAttachmentMemo(
    SharedText item, {
    required String text,
    required DataGeneration generation,
    TaskAttachmentFiles? files,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final sourcePath = item.attachmentPath;
      if (sourcePath == null || !SharedText.isHandoffPath(sourcePath, item.id)) {
        throw const FormatException('Missing shared attachment');
      }
      final trimmed = text.trim();
      final fallbackName = (item.attachmentName?.trim().isNotEmpty == true)
          ? item.attachmentName!.trim()
          : p.basename(sourcePath);
      final titleSource = trimmed.isEmpty ? fallbackName : trimmed;
      final title = String.fromCharCodes(titleSource.runes.take(80));
      final summary = trimmed.isEmpty ? fallbackName : text;
      final existingRow = await _dbHelper.read(
        ticket,
        (db) => db.query('Reminders', where: 'id = ?', whereArgs: [item.id]),
      );
      if (existingRow.isNotEmpty) {
        final existing = Reminder.fromJson(existingRow.single);
        if (existing.sourceText == summary &&
            existing.details.attachmentIds.isNotEmpty) {
          return existing;
        }
        throw const StaleReminderOccurrenceException();
      }
      final storage = files ?? TaskAttachmentFiles();
      final media = await storage.import(sourcePath);
      late Reminder saved;
      try {
        saved = await _dbHelper.writeTransaction(ticket, (db) async {
          final current = await db.query(
            'Reminders',
            where: 'id = ?',
            whereArgs: [item.id],
          );
          if (current.isNotEmpty) {
            throw const StaleReminderOccurrenceException();
          }
          final now = DateTime.now();
          final reminder = Reminder(
            id: item.id,
            recordId: media.id,
            createdAt: now,
            taskTitle: title,
            taskSummary: summary,
            sourceText: summary,
            quadrantLevel: 2,
            triggerTime: null,
            timeOrigin: ReminderTimeOrigin.unknown,
            eventTime: null,
            capturePending: false,
            detailsJson: TaskDetails(
              attachmentIds: [media.id],
            ).encode(),
          );
          await db.insert('MediaRecords', media.toJson());
          await db.insert('Reminders', reminder.toJson());
          return reminder;
        });
      } catch (_) {
        await storage.discard(media);
        rethrow;
      }
      storage.committed(media);
      _dbHelper.checkGeneration(ticket);
      _publishManaged([saved]);
      return saved;
    }),
    generation: generation,
  );
}
