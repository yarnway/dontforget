import 'dart:async';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// SQLite's isolate runs on real time; widget callbacks run on the fake clock.
/// Drain both before closing an isolated DB with autosaves still in flight.
Future<void> drainWorkspaceDrafts(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final store = container.read(workspaceDraftsProvider.notifier);
  for (var round = 0; round < 10; round++) {
    final pending = store.flushed;
    var done = false;
    unawaited(pending.then((_) => done = true));
    for (var tick = 0; tick < 500 && !done; tick++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'Persisted draft writes must settle');
    if (identical(pending, store.flushed)) return;
  }
  fail('Draft autosave did not settle');
}
