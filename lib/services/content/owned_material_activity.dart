import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Process-local reservations cover preparation and the complete restore dialog.
/// Persisted ownership metadata permits later, explicit cleanup after retention.
class OwnedMaterialActivity {
  static const markerName = '.dontforget-material.json';
  static final activeDirectories = <String>{};
  static String _identity(Directory directory) {
    try {
      return directory.resolveSymbolicLinksSync();
    } catch (_) {
      try {
        return p.join(
          directory.parent.resolveSymbolicLinksSync(),
          p.basename(directory.path),
        );
      } catch (_) {
        return p.normalize(directory.absolute.path);
      }
    }
  }

  static void hold(Directory directory) =>
      activeDirectories.add(_identity(directory));
  static void release(File snapshot) => releaseDirectory(snapshot.parent);
  static void releaseDirectory(Directory directory) =>
      activeDirectories.remove(_identity(directory));
  static bool active(String directory) =>
      activeDirectories.contains(_identity(Directory(directory)));
  static Future<void> mark(Directory directory, String role) async {
    if (!const {'original', 'restore'}.contains(role)) {
      throw ArgumentError(role);
    }
    await File(p.join(directory.path, markerName)).writeAsString(
      jsonEncode({
        'format': 'dontforget.material',
        'version': 1,
        'role': role,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }
}
