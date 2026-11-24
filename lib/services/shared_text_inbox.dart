import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../providers/workspace_drafts_provider.dart';

class SharedText {
  const SharedText({
    required this.id,
    required this.text,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentName,
  });
  final String id;
  final String text;
  final int createdAt;
  final String? attachmentPath;
  final String? attachmentName;
  static const maxTextLength = 16000;
  static const maxPathLength = 4096;
  static const maxNameLength = 255;
  static const imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
  };
  static final _id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _nonUrlCharacters = RegExp(r'[\s\x00-\x1f\x7f\\<>"`]');

  /// Accept a URL on its own line, including shares with a separate title.
  static Uri? webLinkFromText(String text) {
    Uri? link;
    for (final line in text.split('\n')) {
      final candidate = line.trim();
      if (_nonUrlCharacters.hasMatch(candidate)) continue;
      final uri = Uri.tryParse(candidate);
      if (uri == null ||
          !(uri.isScheme('https') || uri.isScheme('http')) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      if (link != null && link != uri) return null;
      link = uri;
    }
    return link;
  }

  static bool validText(String text) =>
      text.length <= maxTextLength &&
      !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(text);
  static bool validAttachmentPath(String filePath) =>
      filePath.isNotEmpty &&
      filePath.length <= maxPathLength &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(filePath) &&
      p.isAbsolute(filePath) &&
      !p.split(filePath).contains('..');
  static bool validAttachmentName(String name) =>
      name.trim().isNotEmpty &&
      name.length <= maxNameLength &&
      !RegExp(r'[\x00-\x1f\x7f/\\]').hasMatch(name) &&
      name != '.' &&
      name != '..';
  static bool isImagePath(String filePath) =>
      imageExtensions.contains(p.extension(filePath).toLowerCase());

  /// Native bridges stage each share as `shared_handoff/<id>/<name>`.
  /// Only that private layout may be imported or removed for a share.
  static bool isHandoffPath(String filePath, String id) {
    final parent = p.dirname(filePath);
    return validAttachmentPath(filePath) &&
        p.basename(parent) == id &&
        p.basename(p.dirname(parent)) == 'shared_handoff';
  }

  bool get hasAttachment => attachmentPath != null;
  bool get isImageAttachment =>
      attachmentPath != null &&
      (isImagePath(attachmentPath!) ||
          (attachmentName != null && isImagePath(attachmentName!)));

  static SharedText parse(Object? value, {bool incoming = false}) {
    if (value is! Map ||
        !value.keys.every(
          (key) => const {
            'id',
            'text',
            'created_at',
            'attachment_path',
            'attachment_name',
          }.contains(key),
        ) ||
        value['id'] is! String ||
        !_id.hasMatch(value['id'] as String) ||
        value['text'] is! String ||
        !validText(value['text'] as String) ||
        value['created_at'] is! int ||
        (value['created_at'] as int) <= 0) {
      throw const FormatException('Invalid shared text');
    }
    final rawPath = value['attachment_path'];
    final rawName = value['attachment_name'];
    if (rawPath == null && rawName != null) {
      throw const FormatException('Invalid shared attachment');
    }
    String? attachmentPath;
    String? attachmentName;
    if (rawPath != null) {
      final shareId = value['id'] as String;
      if (rawPath is! String || !isHandoffPath(rawPath, shareId)) {
        throw const FormatException('Invalid shared attachment path');
      }
      attachmentPath = rawPath;
      if (rawName != null) {
        if (rawName is! String || !validAttachmentName(rawName)) {
          throw const FormatException('Invalid shared attachment name');
        }
        attachmentName = rawName;
      } else {
        final base = p.basename(rawPath);
        if (!validAttachmentName(base)) {
          throw const FormatException('Invalid shared attachment name');
        }
        attachmentName = base;
      }
    } else if (incoming && (value['text'] as String).trim().isEmpty) {
      throw const FormatException('Invalid shared text');
    }
    return SharedText(
      id: value['id'] as String,
      text: value['text'] as String,
      createdAt: value['created_at'] as int,
      attachmentPath: attachmentPath,
      attachmentName: attachmentName,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'text': text,
    'created_at': createdAt,
    if (attachmentPath != null) 'attachment_path': attachmentPath!,
    if (attachmentName != null) 'attachment_name': attachmentName!,
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
          attachmentPath: items[index].attachmentPath,
          attachmentName: items[index].attachmentName,
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
    final stagedPath = item.attachmentPath;
    if (stagedPath != null && SharedText.isHandoffPath(stagedPath, id)) {
      final parent = p.dirname(stagedPath);
      try {
        final dir = Directory(parent);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> get flushed => _tail;
  static int count(Map<String, dynamic> workspace) {
    final raw = workspace[key];
    return raw is Map && raw['items'] is List
        ? (raw['items'] as List).length
        : 0;
  }
}
