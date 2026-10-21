import 'stored_datetime.dart';

class MediaRecord {
  final String id;
  final String type; // text, audio, video, image
  final String contentOrPath;
  final DateTime createdAt;

  MediaRecord({
    required this.id,
    required this.type,
    required this.contentOrPath,
    required this.createdAt,
  });

  factory MediaRecord.fromJson(Map<String, dynamic> json) => MediaRecord(
    id: json['id'] as String,
    type: json['type'] as String,
    contentOrPath: json['content_or_path'] as String,
    createdAt: parseStoredDateTime(json['created_at']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'content_or_path': contentOrPath,
    'created_at': createdAt.toIso8601String(),
  };
}
