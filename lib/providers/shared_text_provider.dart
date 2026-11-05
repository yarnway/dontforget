import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/shared_text_inbox.dart';
import 'workspace_drafts_provider.dart';

final sharedTextInboxProvider = Provider<SharedTextInbox>(
  (ref) => SharedTextInbox(ref.watch(workspaceDraftsProvider.notifier)),
);

class SharedTextInboxCommand {
  bool Function()? open;
}

final sharedTextInboxCommandProvider = Provider(
  (ref) => SharedTextInboxCommand(),
);
