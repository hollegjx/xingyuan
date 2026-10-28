import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/assistant/presentation/assistant_conversation_view.dart';
import '../features/companion/companion_providers.dart';
import '../features/companion/presentation/companion_home_view.dart';
import '../features/goals/presentation/today_view.dart';
import '../features/review/review_view.dart';
import '../shared/presentation.dart';
import '../shared/ui/sparkle.dart';
import 'providers.dart';
import 'my_view.dart';
import 'theme.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _tab = 0;
  bool _planningOpened = false;

  void _select(int index) => setState(() {
    _tab = index;
    if (index == 1) _planningOpened = true;
  });

  @override
  Widget build(BuildContext context) {
    ref.listen(notificationOpenProvider, (_, next) {
      if (mounted) setState(() => _tab = 0);
    });
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TodayView(onOpenCompanion: () => _select(3)),
          _planningOpened
              ? const SafeArea(
                  bottom: false,
                  child: AssistantConversationView(),
                )
              : const SizedBox.shrink(),
          const SafeArea(bottom: false, child: ReviewView()),
          // Built only while visible, so it refreshes each time it is opened.
          _tab == 3
              ? const SafeArea(bottom: false, child: CompanionHomeView())
              : const SizedBox.shrink(),
          _tab == 4
              ? const SafeArea(bottom: false, child: MyView())
              : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.xy.line, width: 0.5)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) {
            if (index != _tab) HapticFeedback.selectionClick().ignore();
            _select(index);
          },
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          animationDuration: Duration.zero,
          destinations: [
            NavigationDestination(
              icon: StarMark(lit: false, size: 24, outline: context.xy.muted),
              selectedIcon: StarMark(
                lit: true,
                size: 24,
                glow: false,
                color: Theme.of(context).colorScheme.primary,
              ),
              label: '今天',
              tooltip: '今天',
            ),
            const NavigationDestination(
              icon: Icon(CupertinoIcons.sparkles),
              selectedIcon: Icon(CupertinoIcons.sparkles),
              label: '规划',
              tooltip: '规划',
            ),
            const NavigationDestination(
              icon: Icon(CupertinoIcons.calendar),
              selectedIcon: Icon(CupertinoIcons.calendar_today),
              label: '回顾',
              tooltip: '回顾',
            ),
            const NavigationDestination(
              icon: _CompanionTabIcon(selected: false),
              selectedIcon: _CompanionTabIcon(selected: true),
              label: '陪伴',
              tooltip: '陪伴',
            ),
            const NavigationDestination(
              icon: Icon(CupertinoIcons.person_crop_circle),
              selectedIcon: Icon(CupertinoIcons.person_crop_circle_fill),
              label: '我的',
              tooltip: '我的',
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the unread chat count once chat is already running. It only reads
/// providers that exist, so it never starts or revives companion state.
class _CompanionTabIcon extends ConsumerWidget {
  const _CompanionTabIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = Icon(
      selected ? CupertinoIcons.person_2_fill : CupertinoIcons.person_2,
    );
    if (ref.watch(companionForegroundProvider) == null) return icon;
    final pairing = ref.watch(pairingControllerProvider).asData?.value;
    if (pairing == null) return icon;
    return ListenableBuilder(
      listenable: pairing,
      builder: (context, _) {
        if (pairing.snapshot?.state?.group == null ||
            !ref.exists(chatControllerProvider)) {
          return icon;
        }
        final chat = ref.read(chatControllerProvider).asData?.value;
        if (chat == null || !chat.available) return icon;
        return FrameSafeListenableBuilder(
          listenable: chat,
          builder: (context, _) => Badge.count(
            count: chat.available ? chat.unread : 0,
            isLabelVisible: chat.available && chat.unread > 0,
            child: icon,
          ),
        );
      },
    );
  }
}
