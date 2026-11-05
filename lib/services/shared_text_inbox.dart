import 'dart:async';

import '../providers/workspace_drafts_provider.dart';

class SharedText {
  const SharedText({
    required this.id,
    required this.text,
    required this.createdAt,
  });
  final String id;
  final String text;
  final int createdAt;
  static const maxTextLength = 16000;
  static final _id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static bool validText(String text) =>
      text.length <= maxTextLength &&
      !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(text);
  static SharedText parse(Object? value, {bool incoming = false}) {
    if (value is! Map ||
        value.length != 3 ||
        value['id'] is! String ||
        !_id.hasMatch(value['id'] as String) ||
        value['text'] is! String ||
        !validText(value['text'] as String) ||
        (incoming && (value['text'] as String).trim().isEmpty) ||
        value['created_at'] is! int ||
        (value['created_at'] as int) <= 0) {
      throw const FormatException('Invalid shared text');
    }
    return SharedText(
      id: value['id'] as String,
      text: value['text'] as String,
      createdAt: value['created_at'] as int,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'text': text,
    'created_at': createdAt,
  };
}

class SharedTextInboxData {
  const SharedTextInboxData(this.items, this.receipts);
  final List<SharedText> items;
  final List<String> receipts;
  static SharedTextInboxData parse(Object? value) {
    if (value == null) return const SharedTextInboxData([], []);
    if (value is! Map ||
        value.length != 3 ||
        value['version'] != 1 ||
        value['items'] is! List ||
        (value['items'] as List).length > SharedTextInbox.maxItems ||
        value['receipts'] is! List ||
        (value['receipts'] as List).length > 128) {
      throw const FormatException('Invalid shared inbox');
    }
    final items = (value['items'] as List).map(SharedText.parse).toList();
    final receipts = (value['receipts'] as List).map((id) {
      if (id is! String || !SharedText._id.hasMatch(id)) {
        throw const FormatException('Invalid share receipt');
      }
      return id;
    }).toList();
    if (items.map((item) => item.id).toSet().length != items.length ||
        receipts.toSet().length != receipts.length ||
        items.any((item) => !receipts.contains(item.id))) {
      throw const FormatException('Invalid share identities');
    }
    return SharedTextInboxData(
      List.unmodifiable(items),
      List.unmodifiable(receipts),
    );
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'items': items.map((item) => item.toJson()).toList(),
    'receipts': receipts,
  };
}

/// Incoming content has its own durable entry; it never replaces the composer.
/// A native event is acknowledged only after this transaction commits.
class SharedTextInbox {
  SharedTextInbox(this.drafts);
  static const key = 'sharedTextInbox';
  static const maxItems = 32;
  final WorkspaceDrafts drafts;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> accept(SharedText incoming) => _serial(() async {
    SharedText.parse(incoming.toJson(), incoming: true);
    final raw = await drafts.readPersistedKey(key);
    final data = SharedTextInboxData.parse(raw);
    if (data.receipts.contains(incoming.id)) return true;
    if (data.items.length >= maxItems) return false;
    // Keep every still-pending identity when pruning completed receipts.
    final items = [...data.items, incoming];
    final active = items.map((item) => item.id).toSet();
    final recent = [...data.receipts, incoming.id];
    while (recent.length > 128) {
      final removable = recent.indexWhere((id) => !active.contains(id));
      if (removable < 0) throw StateError('Share receipt limit');
      recent.removeAt(removable);
    }
    await drafts.compareAndPut(
      key,
      raw,
      SharedTextInboxData(items, recent).toJson(),
    );
    return true;
  });

  Future<void> edit(String id, String expected, String text) =>
      _serial(() async {
        if (!SharedText.validText(text)) {
          throw const FormatException('Invalid shared text');
        }
        final raw = await drafts.readPersistedKey(key);
        final data = SharedTextInboxData.parse(raw);
        final index = data.items.indexWhere((item) => item.id == id);
        if (index < 0 || data.items[index].text != expected) {
          throw StateError('Shared draft changed');
        }
        final items = [...data.items];
        items[index] = SharedText(
          id: id,
          text: text,
          createdAt: items[index].createdAt,
        );
        await drafts.compareAndPut(
          key,
          raw,
          SharedTextInboxData(items, data.receipts).toJson(),
        );
      });

  Future<void> remove(String id, String expected) => _serial(() async {
    final raw = await drafts.readPersistedKey(key);
    final data = SharedTextInboxData.parse(raw);
    final item = data.items.where((item) => item.id == id).firstOrNull;
    if (item == null) return;
    if (item.text != expected) throw StateError('Shared draft changed');
    await drafts.compareAndPut(
      key,
      raw,
      SharedTextInboxData(
        data.items.where((item) => item.id != id).toList(),
        data.receipts,
      ).toJson(),
    );
  });

  Future<void> get flushed => _tail;
  static int count(Map<String, dynamic> workspace) {
    final raw = workspace[key];
    return raw is Map && raw['items'] is List
        ? (raw['items'] as List).length
        : 0;
  }
}
