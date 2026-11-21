import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/about_strings.dart';
import '../../l10n/app_localizations.dart';
import '../../services/app_update_service.dart';

final installedAppInfoReaderProvider =
    Provider<Future<InstalledAppInfo> Function()>(
      (ref) => () async {
        final info = await PackageInfo.fromPlatform();
        return InstalledAppInfo(
          name: info.appName,
          version: info.version,
          buildNumber: info.buildNumber,
        );
      },
    );

final appUpdateServiceProvider = Provider<AppUpdateService>(
  (ref) => AppUpdateService(),
);

final appUpdatePlatformProvider = Provider<UpdatePlatform>(
  (ref) => switch (defaultTargetPlatform) {
    TargetPlatform.windows => UpdatePlatform.windows,
    TargetPlatform.linux => UpdatePlatform.linux,
    TargetPlatform.android => UpdatePlatform.android,
    TargetPlatform.iOS => UpdatePlatform.ios,
    TargetPlatform.macOS => UpdatePlatform.macos,
    _ => UpdatePlatform.other,
  },
);

final appProjectLinkOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => (uri) async {
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !(uri.path == '/yarnway/dontforget' ||
            uri.path.startsWith('/yarnway/dontforget/'))) {
      return false;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  },
);

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  InstalledAppInfo? _info;
  bool _loadingInfo = true,
      _infoFailed = false,
      _checking = false,
      _opening = false;
  AppUpdateResult? _result;
  UpdateFailure? _failure;
  DateTime? _checkedAt;

  String t(String key) =>
      aboutText(AppLocalizations.of(context).locale.languageCode, key);

  @override
  void initState() {
    super.initState();
    _readInfo();
  }

  Future<void> _readInfo() async {
    setState(() {
      _loadingInfo = true;
      _infoFailed = false;
    });
    try {
      final info = await ref.read(installedAppInfoReaderProvider)();
      if (mounted) {
        setState(() {
          _info = info;
          _loadingInfo = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _infoFailed = true;
          _loadingInfo = false;
        });
      }
    }
  }

  Future<void> _check() async {
    final info = _info;
    if (info == null || _checking) return;
    setState(() {
      _checking = true;
      _failure = null;
      _result = null;
      _checkedAt = null;
    });
    try {
      final result = await ref.read(appUpdateServiceProvider).check(info);
      if (mounted) setState(() => _result = result);
    } on UpdateCheckException catch (error) {
      if (mounted) setState(() => _failure = error.failure);
    } catch (_) {
      if (mounted) setState(() => _failure = UpdateFailure.network);
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _checkedAt = DateTime.now();
        });
      }
    }
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('copyFailed'))));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('copied'))));
    }
  }

  Future<void> _open(Uri uri) async {
    if (_opening) return;
    setState(() => _opening = true);
    var opened = false;
    try {
      opened = await ref.read(appProjectLinkOpenerProvider)(uri);
    } catch (_) {
      /* Show a copyable fallback below. */
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('openFailed')),
          action: SnackBarAction(
            label: t('copyLink'),
            onPressed: () => _copy(uri.toString()),
          ),
        ),
      );
    }
  }

  UpdatePlatform get _platform => ref.read(appUpdatePlatformProvider);

  Widget _link(String key, Uri uri, {IconData icon = Icons.open_in_new}) =>
      OutlinedButton.icon(
        key: ValueKey('about-$key'),
        onPressed: _opening ? null : () => _open(uri),
        icon: Icon(icon),
        label: Text(t(key)),
      );

  Widget _release(AppUpdateResult result) {
    final release = result.release;
    final newer = result.comparison == UpdateComparison.newer;
    final downloads = release.forPlatform(_platform);
    return Card.outlined(
      key: const ValueKey('about-update-result'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              header: true,
              liveRegion: true,
              child: Text(
                t(result.comparison.name),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 10),
            SelectableText('${t('publicVersion')} ${release.displayVersion}'),
            if (newer) ...[
              const SizedBox(height: 16),
              if (downloads.isEmpty) Text(t('noPackage')),
              for (final download in downloads)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.icon(
                    key: ValueKey('about-download-${download.kind.name}'),
                    onPressed: _opening ? null : () => _open(download.url),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(t(download.kind.name)),
                  ),
                ),
              if (_platform == UpdatePlatform.android && downloads.isNotEmpty)
                Text(t('arm64Hint')),
              if (_platform == UpdatePlatform.ios && downloads.isNotEmpty) ...[
                Text(t('iosHint')),
                const SizedBox(height: 10),
                _link('iosGuide', Uri.parse(iosInstallGuideUrl)),
              ],
            ],
            const SizedBox(height: 12),
            _link('releasePage', release.url),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(t('notes'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              SelectableText(release.notes),
            ],
            if (release.notes.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(t('notesOnPage')),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('title'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            key: const ValueKey('about-list'),
            padding: const EdgeInsets.all(18),
            children: [
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.asset(
                              'assets/app_icon.png',
                              width: 56,
                              height: 56,
                              excludeFromSemantics: true,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _info?.name ?? 'DontForget',
                                  style: theme.textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 8),
                                Text(t('description')),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (_loadingInfo) Text(t('loading')),
                      if (_infoFailed) ...[
                        Text(t('versionError')),
                        TextButton(
                          onPressed: _loadingInfo ? null : _readInfo,
                          child: Text(t('retry')),
                        ),
                      ],
                      if (_info case final info?) ...[
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                '${t('version')} ${info.displayVersion}',
                                key: const ValueKey('about-installed-version'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              key: const ValueKey('about-copy-version'),
                              tooltip: t('copyVersion'),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () =>
                                  _copy('${info.name} ${info.displayVersion}'),
                              icon: const Icon(Icons.copy_outlined),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(t('updates'), style: theme.textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Text(t('hint')),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const ValueKey('about-check-updates'),
                        onPressed: _info == null || _checking ? null : _check,
                        icon: _checking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.system_update_alt),
                        label: Text(t(_checking ? 'checking' : 'check')),
                      ),
                      if (_failure case final failure?)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Semantics(
                            container: true,
                            liveRegion: true,
                            child: Text(
                              t(failure.name),
                              key: const ValueKey('about-update-error'),
                            ),
                          ),
                        ),
                      if (_checkedAt case final time?)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${t('checked')} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                          ),
                        ),
                      const SizedBox(height: 10),
                      _link('allReleases', Uri.parse(appReleasesUrl)),
                    ],
                  ),
                ),
              ),
              if (_result case final result?) ...[
                const SizedBox(height: 18),
                _release(result),
              ],
              const SizedBox(height: 18),
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(t('resources'), style: theme.textTheme.titleMedium),
                      const SizedBox(height: 14),
                      _link(
                        'project',
                        Uri.parse(appRepositoryUrl),
                        icon: Icons.code,
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('about-licenses'),
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: _info?.name ?? 'DontForget',
                          applicationVersion: _info?.displayVersion,
                        ),
                        icon: const Icon(Icons.description_outlined),
                        label: Text(t('licenses')),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}
