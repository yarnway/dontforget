import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/settings.dart';
import '../models/reminder.dart';
import 'package:uuid/uuid.dart';

class AudioTranscriptionUnsupportedException implements Exception {
  final String message;
  AudioTranscriptionUnsupportedException([this.message = '模型服务商未提供语音转文字接口']);
  @override
  String toString() => message;
}

class LLMService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 25),
    persistentConnection: true,
  ));

  Future<List<Reminder>> extractTasks(
      String text, AppSettings settings) async {
    return _sendExtractionRequestWithRetry(settings, [
      {'role': 'user', 'content': text},
    ]);
  }

  Future<List<Reminder>> extractTasksFromImage(
      String base64Image, AppSettings settings) async {
    try {
      return await _sendExtractionRequestWithRetry(settings, [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': '请分析这张图片中的文字、计划、备忘或待办事项，提取出具体可执行的任务，并计算精确提醒时间。'
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,$base64Image'
              }
            }
          ]
        }
      ]);
    } catch (e) {
      // Graceful fallback if model doesn't support multimodal vision (e.g. DeepSeek)
      final now = DateTime.now();
      final nowStr = '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      return [
        Reminder(
          id: const Uuid().v4(),
          taskTitle: '图片待办 ($nowStr)',
          taskSummary: '已保存图片附件，点击卡片图标可随时查看大图',
          quadrantLevel: 2,
          urgencyLevel: 'General',
          importanceLevel: 'Important',
          triggerTime: _deduceDefaultTriggerTime(now, 2),
        )
      ];
    }
  }

  Future<List<Reminder>> extractTasksFromFile(
      String fileName, String fileContent, AppSettings settings) async {
    final truncatedContent = fileContent.length > 2500
        ? '${fileContent.substring(0, 2500)}...\n[文件内容较长，已截取前段分析]'
        : fileContent;

    final prompt = '''
用户上传了文档附件，文件名: "$fileName"。
文件提取文本内容如下:
"""
$truncatedContent
"""
请根据该文档内容，提炼出其中需要跟进、处理的行动项或任务，并合理自动规划提醒时间与四象限分类。若无具体行动项，请总结该文档的核心内容作为待办。
''';

    try {
      final tasks = await extractTasks(prompt, settings);
      if (tasks.isNotEmpty) return tasks;
    } catch (_) {}

    final now = DateTime.now();
    return [
      Reminder(
        id: const Uuid().v4(),
        taskTitle: '文件任务: $fileName',
        taskSummary: truncatedContent.length > 60 ? '${truncatedContent.substring(0, 60)}...' : truncatedContent,
        quadrantLevel: 2,
        urgencyLevel: 'General',
        importanceLevel: 'Important',
        triggerTime: _deduceDefaultTriggerTime(now, 2),
      )
    ];
  }

  Future<List<Reminder>> extractTasksFromVideo(
      String fileName, AppSettings settings) async {
    final now = DateTime.now();
    final prompt = '用户记录了视频任务，视频文件名为: "$fileName"。请为此视频生成一个待办任务标题、行动摘要，并安排合理的提醒时间。';
    try {
      final tasks = await extractTasks(prompt, settings);
      if (tasks.isNotEmpty) return tasks;
    } catch (_) {}

    return [
      Reminder(
        id: const Uuid().v4(),
        taskTitle: '视频事项: $fileName',
        taskSummary: '已关联视频素材，点击卡片视频图标可快速调用播放器查看。',
        quadrantLevel: 2,
        urgencyLevel: 'General',
        importanceLevel: 'Important',
        triggerTime: _deduceDefaultTriggerTime(now, 2),
      )
    ];
  }

  Future<List<Reminder>> _sendExtractionRequestWithRetry(AppSettings settings, List<Map<String, dynamic>> userMessages, {int maxRetries = 2}) async {
    int attempts = 0;
    while (attempts < maxRetries) {
      try {
        return await _sendExtractionRequest(settings, userMessages);
      } catch (e) {
        attempts++;
        if (attempts >= maxRetries) {
          rethrow;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return [];
  }

  Future<List<Reminder>> _sendExtractionRequest(AppSettings settings, List<Map<String, dynamic>> userMessages) async {
    if (settings.apiKey.isEmpty) {
      throw Exception('API Key is not configured.');
    }

    final now = DateTime.now();
    final nowStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final systemPrompt = '''
You are a highly efficient, accurate, and intelligent task management AI assistant.
Current local time is: $nowStr.
User will provide a text (may be speech-to-text transcription) or an image.
Your task is to accurately extract actionable task(s), automatically generate appropriate reminder times, and detect recurrence patterns.

Guidelines:
1. "title": Crisp, actionable task title (under 15 Chinese characters or 10 words).
2. "summary": Refined, concise summary of the context. Eliminate conversational fillers, specify key details.
3. "time": MUST ALWAYS BE AUTOMATICALLY GENERATED in "YYYY-MM-DD HH:MM" format based on "Current local time ($nowStr)".
   - Do NOT ask user to choose or input time. Auto-infer a smart reminder timestamp:
     * If user explicitly mentions a time ("下午3点开会", "明天交周报", "10分钟后吃药"): calculate exact future timestamp.
     * If no explicit time is mentioned ("买牛奶", "复习英语", "发邮件给客户"): NEVER return null! Automatically assign a sensible future time:
       - Urgent/Important (Q1): within 1-2 hours or today's working hours.
       - Important/Not Urgent (Q2): tonight 20:00 or tomorrow morning 09:30.
       - Routine/General (Q3/Q4): today 18:30 or 20:00. If already late night (>21:00), schedule tomorrow 09:00.
     * Special case only: If input is completely unintelligible gibberish, return null and flag needs_clarification.
4. "is_recurring": boolean. true if user mentions or implies periodic/recurring behavior (e.g. "每天", "每周五", "工作日", "每个月", "按时吃药", "每日复盘"), otherwise false.
5. "recurrence_rule": "none" | "daily" | "workday" | "weekly" | "monthly" | "yearly".
6. "recurrence_desc": Short Chinese description if recurring (e.g. "每天", "每个工作日", "每周五", "每月1号"), or null if none.
7. "quadrant": Categorize into Eisenhower Matrix:
   1 = 紧急且重要 (Urgent & Important)
   2 = 重要不紧急 (Important & Not Urgent)
   3 = 紧急不重要 (Urgent & Not Important)
   4 = 不重要不紧急 (Not Important & Not Urgent)
8. "urgency": "Urgent" | "General" | "Not Urgent"
9. "importance": "Important" | "General" | "Not Important"

Output strictly in valid JSON object matching this structure:
{
  "tasks": [
    {
      "title": "...",
      "summary": "...",
      "time": "YYYY-MM-DD HH:MM",
      "is_recurring": false,
      "recurrence_rule": "none",
      "recurrence_desc": null,
      "quadrant": 1,
      "urgency": "...",
      "importance": "..."
    }
  ]
}
''';

    try {
      final messages = [
        {'role': 'system', 'content': systemPrompt},
        ...userMessages,
      ];

      final response = await _dio.post(
        '${settings.baseUrl}/chat/completions',
        options: Options(
          headers: {
            'Authorization': 'Bearer ${settings.apiKey}',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': settings.modelName,
          'messages': messages,
          'temperature': 0.1,
          'max_tokens': 2048,
          'response_format': {'type': 'json_object'},
        },
      );

      final message = response.data['choices'][0]['message'];
      String content = (message['content'] as String? ?? '').trim();
      if (content.isEmpty && message['reasoning_content'] != null) {
        content = (message['reasoning_content'] as String? ?? '').trim();
      }
      
      String jsonStr = content.trim();
      final jsonBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', caseSensitive: false);
      final match = jsonBlockRegex.firstMatch(jsonStr);
      if (match != null) {
        jsonStr = match.group(1)!.trim();
      } else {
        final startIdx = jsonStr.indexOf('{');
        final endIdx = jsonStr.lastIndexOf('}');
        if (startIdx != -1 && endIdx != -1 && endIdx > startIdx) {
          jsonStr = jsonStr.substring(startIdx, endIdx + 1);
        }
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(jsonStr);
      } catch (_) {
        decoded = _tryRegexExtract(content);
      }

      List<dynamic> tasksList = [];
      if (decoded is Map<String, dynamic>) {
        if (decoded['tasks'] is List) {
          tasksList = decoded['tasks'];
        } else if (decoded.containsKey('title') || decoded.containsKey('task')) {
          tasksList = [decoded];
        }
      } else if (decoded is List) {
        tasksList = decoded;
      }

      if (tasksList.isEmpty) {
        final regexResult = _tryRegexExtract(content);
        if (regexResult['tasks'] is List) {
          tasksList = regexResult['tasks'];
        }
      }

      return tasksList.map((json) {
        DateTime? parsedTime;
        final rawTime = json['time'] ?? json['date'];
        if (rawTime != null && rawTime.toString().toLowerCase() != 'null') {
          try {
            parsedTime = DateTime.parse(rawTime.toString());
          } catch (_) {}
        }
        
        int quad = json['quadrant'] is int ? json['quadrant'] : 4;

        // If the model didn't return a time, automatically assign a smart default reminder time
        parsedTime ??= _deduceDefaultTriggerTime(DateTime.now(), quad);

        bool isRecur = false;
        if (json['is_recurring'] is bool) {
          isRecur = json['is_recurring'];
        } else if (json['is_recurring'] != null) {
          isRecur = json['is_recurring'].toString().toLowerCase() == 'true' || json['is_recurring'] == 1;
        }

        String rule = json['recurrence_rule'] as String? ?? 'none';
        String? desc = json['recurrence_desc'] as String? ?? json['recurrence_description'] as String?;

        return Reminder(
          id: const Uuid().v4(),
          taskTitle: json['title'] ?? json['task'] ?? json['event'] ?? '新事项',
          taskSummary: json['summary'] ?? json['description'],
          quadrantLevel: quad,
          urgencyLevel: json['urgency'] ?? 'General',
          importanceLevel: json['importance'] ?? 'General',
          triggerTime: parsedTime,
          isRecurring: isRecur,
          recurrenceRule: rule,
          recurrenceDescription: desc,
        );
      }).toList();
    } catch (e) {
      throw Exception(formatErrorMessage(e));
    }
  }

  DateTime _deduceDefaultTriggerTime(DateTime now, int quadrant) {
    switch (quadrant) {
      case 1:
        return now.add(const Duration(hours: 1));
      case 2:
        if (now.hour >= 20) {
          return DateTime(now.year, now.month, now.day + 1, 9, 30);
        } else {
          return DateTime(now.year, now.month, now.day, 20, 0);
        }
      case 3:
        return now.add(const Duration(hours: 2));
      case 4:
      default:
        if (now.hour >= 21) {
          return DateTime(now.year, now.month, now.day + 1, 10, 0);
        } else {
          return DateTime(now.year, now.month, now.day, 21, 0);
        }
    }
  }

  Map<String, dynamic> _tryRegexExtract(String raw) {
    final titleMatch = RegExp(r'"(?:title|task|event)"\s*:\s*"([^"]+)"').firstMatch(raw);
    final summaryMatch = RegExp(r'"(?:summary|description)"\s*:\s*"([^"]+)"').firstMatch(raw);
    final timeMatch = RegExp(r'"(?:time|date)"\s*:\s*"([^"]+)"').firstMatch(raw);
    final quadMatch = RegExp(r'"quadrant"\s*:\s*(\d+)').firstMatch(raw);
    final urgencyMatch = RegExp(r'"urgency"\s*:\s*"([^"]+)"').firstMatch(raw);
    final importanceMatch = RegExp(r'"importance"\s*:\s*"([^"]+)"').firstMatch(raw);
    final recurMatch = RegExp(r'"is_recurring"\s*:\s*(true|false)', caseSensitive: false).firstMatch(raw);
    final ruleMatch = RegExp(r'"recurrence_rule"\s*:\s*"([^"]+)"').firstMatch(raw);
    final descMatch = RegExp(r'"recurrence_desc"\s*:\s*"([^"]+)"').firstMatch(raw);

    if (titleMatch != null) {
      return {
        'tasks': [
          {
            'title': titleMatch.group(1),
            'summary': summaryMatch?.group(1),
            'time': timeMatch?.group(1),
            'quadrant': int.tryParse(quadMatch?.group(1) ?? '4') ?? 4,
            'urgency': urgencyMatch?.group(1) ?? 'General',
            'importance': importanceMatch?.group(1) ?? 'General',
            'is_recurring': recurMatch?.group(1)?.toLowerCase() == 'true',
            'recurrence_rule': ruleMatch?.group(1) ?? 'none',
            'recurrence_desc': descMatch?.group(1),
          }
        ]
      };
    }
    return {'tasks': []};
  }

  String formatErrorMessage(dynamic e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout || 
          e.type == DioExceptionType.receiveTimeout || 
          e.type == DioExceptionType.sendTimeout) {
        return '网络请求超时，大模型响应缓慢';
      }
      if (e.type == DioExceptionType.connectionError) {
        return '网络连接异常，无法连通模型服务器';
      }
      final statusCode = e.response?.statusCode;
      if (statusCode == 401) {
        return 'API Key 无效或未授权，请检查设置';
      }
      if (statusCode == 402) {
        return '大模型账户余额不足，请前往服务商充值';
      }
      if (statusCode == 429) {
        return '调用过于频繁或并发超限，请稍后重试';
      }
      if (statusCode == 404) {
        return '模型或接口地址不存在，请检查设置中的模型名称与 URL';
      }
      final serverMsg = e.response?.data?['error']?['message'] ?? e.response?.data?['message'];
      if (serverMsg != null) {
        return '服务接口提示: $serverMsg';
      }
      return '网络请求错误 (HTTP $statusCode)';
    }
    if (e is FormatException) {
      return '大模型输出非标准数据，已为您智能降级处理';
    }
    return e.toString().replaceAll('Exception: ', '');
  }

  Future<String> transcribeAudio(String filePath, AppSettings settings) async {
    if (settings.apiKey.isEmpty) {
      throw Exception('API Key is not configured.');
    }

    String targetUrl;
    if (settings.baseUrl.contains('openai.com')) {
      targetUrl = 'https://api.openai.com/v1/audio/transcriptions';
    } else if (settings.baseUrl.contains('deepseek.com') ||
               settings.baseUrl.contains('googleapis.com') ||
               settings.baseUrl.contains('moonshot.cn') ||
               settings.baseUrl.contains('anthropic.com')) {
      throw AudioTranscriptionUnsupportedException(
        '${settings.modelName} 未提供语音转文字接口，已自动为您保存原声备忘录',
      );
    } else {
      targetUrl = '${settings.baseUrl}/audio/transcriptions';
    }

    try {
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath),
        'model': 'whisper-1',
      });

      final response = await _dio.post(
        targetUrl,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${settings.apiKey}',
          },
        ),
        data: formData,
      );

      return response.data['text'] ?? '';
    } catch (e) {
      if (e is AudioTranscriptionUnsupportedException) rethrow;
      throw AudioTranscriptionUnsupportedException('语音转文字失败，已自动保存原声备忘录');
    }
  }
}
