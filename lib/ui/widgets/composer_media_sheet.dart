import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/home_controller.dart';

void showComposerMediaOptionsSheet(
  BuildContext context,
  HomeController controller,
) {
  final l10n = AppLocalizations.of(context);

  showModalBottomSheet<void>(
    context: context,
    builder: (sheetCtx) {
      final options = <({IconData icon, Color color, String label, VoidCallback onTap})>[
        if (Platform.isAndroid || Platform.isIOS)
          (
            icon: Icons.camera_alt_outlined,
            color: Theme.of(sheetCtx).colorScheme.primary,
            label: l10n.get('takePhoto'),
            onTap: () {
              Navigator.pop(sheetCtx);
              controller.processImageWithSource(ImageSource.camera);
            },
          ),
        (
          icon: Icons.photo_library_outlined,
          color: Theme.of(sheetCtx).colorScheme.secondary,
          label: l10n.get('galleryPhoto'),
          onTap: () {
            Navigator.pop(sheetCtx);
            controller.processImageWithSource(ImageSource.gallery);
          },
        ),
        (
          icon: Icons.snippet_folder_outlined,
          color: Theme.of(sheetCtx).colorScheme.tertiary,
          label: l10n.get('importFile'),
          onTap: () {
            Navigator.pop(sheetCtx);
            controller.processFile();
          },
        ),
        (
          icon: Icons.video_collection_outlined,
          color: Theme.of(sheetCtx).colorScheme.error,
          label: l10n.get('uploadVideo'),
          onTap: () {
            Navigator.pop(sheetCtx);
            controller.processVideo();
          },
        ),
      ];

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: LayoutBuilder(
            builder: (ctx, bounds) {
              final textScale = MediaQuery.textScalerOf(ctx).scale(1);
              final useGrid =
                  options.length > 3 &&
                  (bounds.maxWidth < 360 || textScale > 1.35);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 3.5,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(sheetCtx).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.get('uploadMaterial'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.get('uploadMaterialDesc'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(sheetCtx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (useGrid)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            for (final opt in options.take(2))
                              Expanded(child: _MediaOptionTile(option: opt)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final opt in options.skip(2))
                              Expanded(child: _MediaOptionTile(option: opt)),
                          ],
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        for (final opt in options)
                          Expanded(child: _MediaOptionTile(option: opt)),
                      ],
                    ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

class _MediaOptionTile extends StatelessWidget {
  const _MediaOptionTile({required this.option});

  final ({IconData icon, Color color, String label, VoidCallback onTap}) option;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: option.label,
      child: InkWell(
        onTap: option.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.7),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: option.color.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(option.icon, color: option.color, size: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  option.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
