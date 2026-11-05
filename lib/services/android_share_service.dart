import 'package:flutter/services.dart';
import 'shared_text_inbox.dart';

class AndroidShareService {
  static const channel = MethodChannel('com.yarnway.dontforget/share');
  int _epoch = 0;
  Future<bool> initialize({
    required String datasetEpoch,
    required void Function() onPending,
  }) async {
    final epoch = ++_epoch;
    channel.setMethodCallHandler((call) async {
      if (epoch == _epoch && call.method == 'onPendingShares') onPending();
    });
    try {
      await channel.invokeMethod<void>('initialize', datasetEpoch);
      return epoch == _epoch;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<SharedText>> pending() async {
    final epoch = _epoch;
    final raw = await channel.invokeMethod<Object?>('pending');
    if (epoch != _epoch) return [];
    if (raw is! List || raw.length > 16) {
      throw const FormatException('Invalid native share queue');
    }
    final items = raw.map((v) => SharedText.parse(v, incoming: true)).toList();
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException('Duplicate native share identity');
    }
    return items;
  }

  Future<void> acknowledge(String id) =>
      channel.invokeMethod<void>('acknowledge', id);
  Future<void> resetForRecovery() async {
    _epoch++;
    try {
      await channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // Compatible with older native binaries.
    }
  }

  void dispose() {
    _epoch++;
    channel.setMethodCallHandler(null);
  }
}
