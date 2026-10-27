import 'package:dont_forget/ui/widgets/foreground_time_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('due boundary refreshes only the time-dependent subtree', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 27, 13);
    final due = now.add(const Duration(seconds: 20));
    var parentBuilds = 0;
    var clockBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            parentBuilds++;
            return ForegroundTimeBuilder(
              now: () => now,
              boundary: due,
              builder: (context, current) {
                clockBuilds++;
                return Text(current.isBefore(due) ? 'future' : 'due');
              },
            );
          },
        ),
      ),
    );
    expect(find.text('future'), findsOneWidget);
    final buildsBefore = clockBuilds;
    final parentsBefore = parentBuilds;
    now = due.subtract(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 19));
    expect(clockBuilds, buildsBefore);
    now = due;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('due'), findsOneWidget);
    expect(parentBuilds, parentsBefore);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background stops ticks and resume reads the current clock', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 27, 13);
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ForegroundTimeBuilder(
          now: () {
            reads++;
            return now;
          },
          builder: (context, current) =>
              Text('${current.hour}:${current.minute}'),
        ),
      ),
    );
    final initialReads = reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(hours: 2));
    await tester.pump(const Duration(hours: 2));
    expect(reads, initialReads);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('15:0'), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('15:1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'changed deadline cancels the old boundary and disposal stops ticks',
    (tester) async {
      var now = DateTime.utc(2026, 10, 27, 13);
      var due = now.add(const Duration(seconds: 10));
      var reads = 0;
      Widget screen() => MaterialApp(
        home: ForegroundTimeBuilder(
          now: () {
            reads++;
            return now;
          },
          boundary: due,
          builder: (context, current) =>
              Text(current.isBefore(due) ? 'future' : 'due'),
        ),
      );
      await tester.pumpWidget(screen());
      due = now.add(const Duration(seconds: 30));
      await tester.pumpWidget(screen());
      final readsAfterEdit = reads;
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(reads, readsAfterEdit);
      now = due;
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('due'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final readsAfterDispose = reads;
      await tester.pump(const Duration(minutes: 3));
      expect(reads, readsAfterDispose);
    },
  );

  testWidgets('a background mount waits and a backward clock resumes safely', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 27, 13);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ForegroundTimeBuilder(
          now: () {
            reads++;
            return now;
          },
          boundary: now,
          builder: (context, current) => Text('${current.hour}'),
        ),
      ),
    );
    final before = reads;
    now = now.subtract(const Duration(hours: 1));
    await tester.pump(const Duration(minutes: 5));
    expect(reads, before);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
