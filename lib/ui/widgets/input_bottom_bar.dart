import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/home_controller.dart';

class InputBottomBar extends ConsumerStatefulWidget {
  const InputBottomBar({super.key});

  @override
  ConsumerState<InputBottomBar> createState() => _InputBottomBarState();
}

class _InputBottomBarState extends ConsumerState<InputBottomBar> with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  late AnimationController _animationController;
  bool _isLongPressRecording = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _submitText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    ref.read(homeControllerProvider.notifier).processText(text);
  }

  void _showMediaOptionsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        final controller = ref.read(homeControllerProvider.notifier);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  '上传素材给大模型',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '大模型将自动解析内容并为您创建智能待办与日程提醒',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _buildMediaOption(
                      icon: Icons.camera_alt_rounded,
                      color: Colors.blue.shade600,
                      label: '拍摄照片',
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.camera);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.photo_library_rounded,
                      color: Colors.purple.shade500,
                      label: '相册图片',
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.gallery);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.snippet_folder_rounded,
                      color: Colors.amber.shade700,
                      label: '导入文件',
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processFile();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.video_collection_rounded,
                      color: Colors.redAccent,
                      label: '上传视频',
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processVideo();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMediaOption({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final homeState = ref.watch(homeControllerProvider);
    final isRecording = homeState.isRecording || _isLongPressRecording;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: [
            // Left '+' Add button
            IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded, size: 26),
              color: Theme.of(context).colorScheme.primary,
              tooltip: '上传图片、文件或视频',
              onPressed: () => _showMediaOptionsSheet(context),
            ),

            // Mic toggle button (for desktop click or single tap)
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: isRecording
                        ? [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.4 * _animationController.value),
                              blurRadius: 12 * _animationController.value,
                              spreadRadius: 3 * _animationController.value,
                            )
                          ]
                        : [],
                  ),
                  child: IconButton(
                    icon: Icon(
                      isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                      color: isRecording ? Colors.red : Colors.grey.shade600,
                      size: 24,
                    ),
                    tooltip: isRecording ? '停止录音' : '单击录音 / 长按输入框说话',
                    onPressed: () => ref.read(homeControllerProvider.notifier).toggleRecording(),
                  ),
                );
              },
            ),

            const SizedBox(width: 4),

            // Center Input Area: Single tap to type, Long press to speak
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (!_focusNode.hasFocus) {
                    _focusNode.requestFocus();
                  }
                },
                onLongPressStart: (_) async {
                  _focusNode.unfocus();
                  HapticFeedback.heavyImpact();
                  setState(() => _isLongPressRecording = true);
                  await ref.read(homeControllerProvider.notifier).startRecording();
                },
                onLongPressEnd: (_) async {
                  HapticFeedback.mediumImpact();
                  setState(() => _isLongPressRecording = false);
                  await ref.read(homeControllerProvider.notifier).stopRecordingAndProcess();
                },
                onLongPressCancel: () async {
                  setState(() => _isLongPressRecording = false);
                  await ref.read(homeControllerProvider.notifier).stopRecordingAndProcess();
                },
                child: isRecording
                    ? Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _isLongPressRecording
                                  ? '松手立即提交生成待办...'
                                  : '正在录音中，点击左侧停止...',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.red.shade700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      )
                    : TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        decoration: InputDecoration(
                          hintText: '单击输入文本，长按输入语音...',
                          hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        ),
                        onSubmitted: (_) => _submitText(),
                      ),
              ),
            ),

            // Background Processing capsule
            if (homeState.isProcessingInBackground)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      homeState.pendingTasksCount > 1
                          ? 'AI提炼中 (${homeState.pendingTasksCount})'
                          : 'AI提炼中...',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),

            // Right Send button
            IconButton(
              icon: const Icon(Icons.arrow_upward_rounded, size: 22),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(6),
              ),
              tooltip: '发送',
              onPressed: _submitText,
            ),
          ],
        ),
      ),
    );
  }
}
