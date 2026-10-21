import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../models/ai_profile.dart';
import '../../models/settings.dart';
import '../../providers/providers.dart';

/// A local draft: ordering or typing never sends a network request.
class AiProfilesScreen extends ConsumerStatefulWidget {
  const AiProfilesScreen({super.key});
  @override
  ConsumerState<AiProfilesScreen> createState() => _AiProfilesScreenState();
}

class _AiProfilesScreenState extends ConsumerState<AiProfilesScreen> {
  late List<AiProfile> profiles;
  late bool fallback;
  bool saving = false;
  String? error;
  final Map<String, int> keyRevisions = {};

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    profiles = settings.effectiveProfiles.toList();
    fallback = settings.aiFallbackEnabled;
  }

  void change(int index, AiProfile value) => setState(() {
    profiles[index] = value;
    error = null;
  });

  void changeUrl(int index, String value) {
    final profile = profiles[index];
    final url = value.trim();
    final previous = Uri.tryParse(profile.settings.baseUrl);
    final next = Uri.tryParse(url);
    final sameOrigin =
        previous != null &&
        next != null &&
        previous.scheme == next.scheme &&
        previous.host == next.host &&
        previous.port == next.port;
    if (!sameOrigin && profile.settings.apiKey.isNotEmpty) {
      keyRevisions[profile.id] = (keyRevisions[profile.id] ?? 0) + 1;
    }
    change(
      index,
      profile.copyWith(
        settings: profile.settings.copyWith(
          baseUrl: url,
          apiKey: sameOrigin ? profile.settings.apiKey : '',
        ),
      ),
    );
  }

  void move(int index, int offset) => setState(() {
    final item = profiles.removeAt(index);
    profiles.insert(index + offset, item);
  });

  Future<void> save() async {
    if (saving) return;
    if (profiles.any((p) => p.enabled && !p.isConfigured)) {
      setState(() => error = '请补全已启用模型的名称、地址、模型标识和密钥，或关闭该项。');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final current = ref.read(settingsProvider);
      final enabled = profiles.where((p) => p.enabled);
      final primary = enabled.isEmpty ? null : enabled.first.settings;
      await ref
          .read(settingsProvider.notifier)
          .updateSettings(
            current.copyWith(
              aiProfiles: profiles,
              aiFallbackEnabled: fallback,
              apiKey: primary?.apiKey ?? '',
              baseUrl: primary?.baseUrl ?? current.baseUrl,
              modelName: primary?.modelName ?? current.modelName,
            ),
          );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '配置未保存，请检查本地存储后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('任务提取模型')),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存模型配置'),
        ),
      ),
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('按列表顺序尝试启用的模型。用于文字、图片和文件任务提取；语音转写、报告和微习惯仍使用首个启用配置。'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('不可用时自动尝试下一模型'),
              subtitle: const Text('开启后，同一次任务内容可能发送给后续启用的服务。关闭时只使用首个启用模型。'),
              value: fallback,
              onChanged: saving
                  ? null
                  : (value) => setState(() => fallback = value),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (var index = 0; index < profiles.length; index++)
              profileCard(index),
            OutlinedButton.icon(
              onPressed: saving || profiles.length >= 16
                  ? null
                  : () => setState(
                      () => profiles.add(
                        AiProfile(
                          id: const Uuid().v4(),
                          label: '模型 ${profiles.length + 1}',
                          settings: AppSettings.defaults(),
                          enabled: false,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('添加模型配置'),
            ),
            const SizedBox(height: 12),
            const Text('配置和密钥保存在本机，并包含在备份中。此页面不会自动探测或调用服务；可用性由实际请求判断。'),
          ],
        ),
      ),
    ),
  );

  Widget profileCard(int index) {
    final profile = profiles[index];
    return Card(
      key: ValueKey(profile.id),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '优先级 ${index + 1}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Switch(
                  value: profile.enabled,
                  onChanged: saving
                      ? null
                      : (value) =>
                            change(index, profile.copyWith(enabled: value)),
                ),
                IconButton(
                  tooltip: '上移',
                  onPressed: saving || index == 0
                      ? null
                      : () => move(index, -1),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: '下移',
                  onPressed: saving || index == profiles.length - 1
                      ? null
                      : () => move(index, 1),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: '移除配置',
                  onPressed: saving || profiles.length == 1
                      ? null
                      : () => setState(() => profiles.removeAt(index)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            field(
              profile.id,
              'name',
              '配置名称',
              profile.label,
              (v) => change(index, profile.copyWith(label: v)),
            ),
            field(
              profile.id,
              'url',
              '接口地址',
              profile.settings.baseUrl,
              (v) => changeUrl(index, v),
            ),
            field(
              profile.id,
              'model',
              '模型 API 标识',
              profile.settings.modelName,
              (v) => change(
                index,
                profile.copyWith(
                  settings: profile.settings.copyWith(modelName: v.trim()),
                ),
              ),
            ),
            field(
              profile.id,
              'key',
              'API Key',
              profile.settings.apiKey,
              (v) => change(
                index,
                profile.copyWith(
                  settings: profile.settings.copyWith(apiKey: v.trim()),
                ),
              ),
              secret: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget field(
    String id,
    String kind,
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextFormField(
      key: ValueKey(
        secret ? '$id/$kind/${keyRevisions[id] ?? 0}' : '$id/$kind',
      ),
      initialValue: value,
      enabled: !saving,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: kind == 'url' ? '更换服务地址的主机或协议会清除旧密钥。' : null,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}
