import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/presentation.dart';
import '../shared/ui/sparkle.dart';
import '../features/companion/companion_providers.dart';
import '../features/companion/presentation/companion_foreground.dart';
import 'home_page.dart';
import 'providers.dart';
import 'theme.dart';

class HabitCheckinApp extends ConsumerStatefulWidget {
  const HabitCheckinApp({super.key});

  @override
  ConsumerState<HabitCheckinApp> createState() => _HabitCheckinAppState();
}

class _HabitCheckinAppState extends ConsumerState<HabitCheckinApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigator = GlobalKey<NavigatorState>();
  CompanionForeground? _companion;
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    ref.listenManual(companionForegroundProvider, (_, next) {
      _companion = next;
      next?.setForeground(_foreground);
    }, fireImmediately: true);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        _companion?.setForeground(_foreground);
      },
      onResume: () {
        ref.invalidate(chatPhotoCleanupProvider);
        ref.read(environmentProvider.notifier).refresh().ignore();
        unawaited(ref.read(notificationAccessProvider.notifier).refresh());
        ref.read(reminderReportProvider.notifier).refresh().ignore();
      },
    );
  }

  @override
  void dispose() {
    _companion?.setForeground(false);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatPhotoCleanupProvider);
    ref.watch(reminderReportProvider);
    ref.listen(notificationOpenProvider, (_, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    });
    return MaterialApp(
      navigatorKey: _navigator,
      title: '星愿',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildXyTheme(Brightness.light),
      darkTheme: buildXyTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) => Actions(
        actions: <Type, Action<Intent>>{
          // Apply outside-tap dismissal to touch input on every route as well.
          EditableTextTapOutsideIntent:
              CallbackAction<EditableTextTapOutsideIntent>(
                onInvoke: (intent) {
                  intent.focusNode.unfocus();
                  return null;
                },
              ),
        },
        child: child!,
      ),
      home: ref
          .watch(environmentProvider)
          .when(
            data: (_) => const HomePage(),
            loading: () => const _Splash(),
            error: (error, stack) => Scaffold(
              body: SafeArea(
                child: PageScroll(
                  children: [
                    StatusPanel(
                      message: '无法读取设备日期与时区，记录未被清空。',
                      retry: () => ref.invalidate(environmentProvider),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }
}

/// Shown for the moment it takes to read the device clock.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Semantics(
        label: '正在读取本地日期',
        child: const StarMark(lit: true, size: 56, glow: false),
      ),
    ),
  );
}
