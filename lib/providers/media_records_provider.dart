part of 'providers.dart';

final mediaRecordsProvider =
    StateNotifierProvider<MediaRecordsNotifier, List<MediaRecord>>((ref) {
      return MediaRecordsNotifier(ref.read(databaseHelperProvider));
    });

/// Derived O(1) lookup index for media records so TaskCard avoids scanning all records per card.
final mediaRecordByIdProvider = Provider<Map<String, MediaRecord>>((ref) {
  final list = ref.watch(mediaRecordsProvider);
  return {for (final m in list) m.id: m};
});

class MediaRecordsNotifier extends StateNotifier<List<MediaRecord>> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;
  DataGeneration? _stateGeneration;
  Future<void> _operations = Future<void>.value();

  MediaRecordsNotifier(this._dbHelper) : super([]) {
    ready = _enqueue(_loadRecords);
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _operations.then((_) => action());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> _loadRecords() async {
    final generation = _dbHelper.captureGeneration();
    final cached = _dbHelper.takeBootstrapMediaRecords(generation);
    final List<MediaRecord> records;
    if (cached != null) {
      records = cached;
    } else {
      final rows = await _dbHelper.read(
        generation,
        (db) => db.query('MediaRecords'),
      );
      records = rows.map(MediaRecord.fromJson).toList();
    }
    _dbHelper.checkGeneration(generation);
    _stateGeneration = generation;
    if (mounted) {
      state = records;
    }
  }

  Future<void> refreshMediaRecords() => _enqueue(_loadRecords);

  Future<void> addRecord(MediaRecord record) async {
    final generation = _dbHelper.captureGeneration();
    await addRecordForGeneration(record, generation);
  }

  Future<void> addRecordForGeneration(
    MediaRecord record,
    DataGeneration generation,
  ) => _enqueue(() async {
    _dbHelper.checkGeneration(generation);
    if (_stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    await _dbHelper.writeTransaction(
      generation,
      (txn) => txn.insert('MediaRecords', record.toJson()),
    );
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = [...state, record];
    }
  });
}
