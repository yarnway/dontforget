import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'providers/providers.dart';
import 'ui/screens/home_screen.dart';
import 'l10n/app_localizations.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WindowListener, TrayListener {
  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }
  }

  Future<void> _initTray() async {
    if (!_isDesktop) return;
    try {
      // Note: Windows icon must be .ico format and bundled in assets
      await trayManager.setIcon(
        Platform.isWindows 
          ? 'assets/app_icon.ico' 
          : 'assets/app_icon.png' // Fallback for macOS and Linux
      );
      await trayManager.setToolTip("DontForget");
      Menu menu = Menu(
        items: [
          MenuItem(
            key: 'show_window',
            label: '显示应用',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: '退出',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('Tray initialization error: $e');
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  // --- WindowListener Methods ---
  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    try {
      // Hide window instead of closing
      bool isPreventClose = await windowManager.isPreventClose();
      if (isPreventClose) {
        windowManager.hide();
      }
    } catch (_) {}
  }

  // --- TrayListener Methods ---
  @override
  void onTrayIconMouseDown() {
    if (!_isDesktop) return;
    try {
      // Bring to front on single click
      windowManager.show();
      windowManager.focus();
    } catch (_) {}
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_isDesktop) return;
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!_isDesktop) return;
    try {
      if (menuItem.key == 'show_window') {
        windowManager.show();
        windowManager.focus();
      } else if (menuItem.key == 'exit_app') {
        try {
          trayManager.destroy();
        } catch (_) {}
        try {
          windowManager.destroy();
        } catch (_) {}
        exit(0);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    // Morandi-inspired minimal palette
    const primaryColor = Color(0xFF7A8B8B); // A muted, grayish cyan/teal

    return MaterialApp(
      title: "DontForget",
      debugShowCheckedModeBanner: false,
      locale: Locale(settings.language),
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''),
        Locale('zh', ''),
        Locale('ja', ''),
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.05),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.dark,
          surface: const Color(0xFF2C2C2C),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
