import 'package:flutter/material.dart';

/// Standalone startup failure surface: deliberately outside ProviderScope.
class StorageUnavailableScreen extends StatelessWidget {
  const StorageUnavailableScreen({
    super.key,
    required this.busy,
    required this.onExit,
  });
  final bool busy;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff367f80),
      useMaterial3: true,
    ),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.storage_outlined, size: 40),
                  const SizedBox(height: 20),
                  Text(
                    busy ? '数据正在使用中' : '暂时无法打开本地数据',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    busy
                        ? '请先退出另一份“别忘了”，再重新打开。\nQuit the other DontForget instance, then reopen this app.'
                        : '应用已停止加载任务和安排提醒。恢复记录与回退文件已保留，请检查存储状态后重新启动；不要删除这些文件。\nStartup is paused. Recovery evidence is preserved. Check local storage before restarting.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: onExit,
                    child: const Text('退出 / Exit'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
