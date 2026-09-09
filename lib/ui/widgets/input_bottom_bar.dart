import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/home_controller.dart';
import '../../l10n/app_localizations.dart';

class InputBottomBar extends ConsumerStatefulWidget {
  const InputBottomBar({super.key});

  @override
  ConsumerState<InputBottomBar> createState() => _InputBottomBarState();
}

class _InputBottomBarState extends ConsumerState<InputBottomBar>
    with SingleTickerProviderStateMixin {
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
    final l10n = AppLocalizations.of(context);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) {
        final controller = ref.read(homeControllerProvider.notifier);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 3,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  l10n.get('uploadMaterial'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.get('uploadMaterialDesc'),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildMediaOption(
                      icon: Icons.camera_alt_outlined,
                      color: Colors.blue.shade600,
                      label: l10n.get('takePhoto'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.camera);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.photo_library_outlined,
                      color: Colors.purple.shade500,
                      label: l10n.get('galleryPhoto'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.gallery);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.snippet_folder_outlined,
                      color: Colors.amber.shade700,
                      label: l10n.get('importFile'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processFile();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.video_collection_outlined,
                      color: Colors.redAccent,
                      label: l10n.get('uploadVideo'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processVideo();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final homeState = ref.watch(homeControllerProvider);
    final isRecording = homeState.isRecording || _isLongPressRecording;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isRecording
                ? Colors.red.withValues(alpha: 0.6)
                : Theme.of(context).colorScheme.outlineVariant,
            width: 1.0,
          ),
        ),
        child: Row(
          children: [
            // Left '+' Add button
            IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
              color: Theme.of(context).colorScheme.primary,
              tooltip: l10n.get('uploadMaterial'),
              splashRadius: 18,
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
                              blurRadius: 8 * _animationController.value,
                              spreadRadius: 2 * _animationController.value,
                            )
                          ]
                        : [],
                  ),
                  child: IconButton(
                    icon: Icon(
                      isRecording ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
                      color: isRecording ? Colors.red : Colors.grey.shade600,
                      size: 22,
                    ),
                    splashRadius: 18,
                    tooltip: isRecording ? l10n.get('recordingClickStop') : l10n.get('inputHint'),
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
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _isLongPressRecording
                                  ? l10n.get('releaseToSend')
                                  : l10n.get('recordingClickStop'),
                              style: TextStyle(
                                fontSize: 12,
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
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: l10n.get('inputHint'),
                          hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        ),
                        onSubmitted: (_) => _submitText(),
                      ),
              ),
            ),

            // Background Processing capsule (Wireframe)
            if (homeState.isProcessingInBackground)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 9,
                      height: 9,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      homeState.pendingTasksCount > 1
                          ? 'AI (${homeState.pendingTasksCount})'
                          : 'AI...',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),

            // Right Send button (Wireframe)
            Container(
              margin: const EdgeInsets.only(left: 4),
              child: IconButton(
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                tooltip: l10n.get('send'),
                onPressed: _submitText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
