import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/global_capture_shortcut.dart';
import 'providers.dart';

final globalCaptureShortcutProvider =
    ChangeNotifierProvider<GlobalCaptureShortcut>((ref) {
      final database = ref.read(databaseHelperProvider);
      return GlobalCaptureShortcut(
        backend: WindowsCaptureShortcutBackend(),
        runtime: ref.read(runtimeRecoveryGateProvider),
        readSaved: () => database.withDeviceWindowPreferences(
          (store) => store.readCaptureShortcut(),
        ),
        writeSaved: (value) => database.withDeviceWindowPreferences(
          (store) => store.writeCaptureShortcut(value),
        ),
      );
    });

class CaptureInputCommand {
  bool Function()? focus;
}

final captureInputCommandProvider = Provider((ref) => CaptureInputCommand());
