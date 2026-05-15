import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/call/incoming_call_kit_coordinator.dart';
import '../../../core/push/push_notification_service.dart';
import '../../../core/share/share_receive_service.dart';
import '../../../features/calendar/controller/calendar_controller.dart';
import '../../../features/calendar/view/calendar_screen.dart';
import '../../chat/controller/chat_controller.dart';
import '../../chat/view/chat_view.dart';
import '../../home/controller/home_controller.dart';
import '../../home/view/home_view.dart';
import '../../calls/calls_history_controller.dart';
import '../../calls/calls_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  static const _navBackground = Color(0xFF121212);

  late final List<Widget> _pages;

  Worker? _shareTabWorker;
  Timer? _acceptedSyncTimer;
  bool _acceptedSyncInFlight = false;

  @override
  void initState() {
    super.initState();
    if (!Get.isRegistered<CalendarController>()) {
      Get.put(CalendarController(), permanent: true);
    }
    _pages = [
      const HomeScreen(),
      const ChatScreen(),
      const CallsScreen(),
      const CalendarScreen(),
    ];
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // iOS stability: defer push/callkit listener bootstrap until main navigation
      // is mounted and app services are ready.
      unawaited(PushNotificationService.requestPermissionAndSetupListeners());
      _scheduleAcceptedCallSync();
    });
    if (Get.isRegistered<ShareReceiveService>()) {
      final s = Get.find<ShareReceiveService>();
      final initial = s.pending.value;
      if (initial != null && initial.isNotEmpty) {
        _selectedIndex = 1;
      }
      _shareTabWorker = ever(s.pending, (list) {
        if (list != null && list.isNotEmpty && mounted) {
          setState(() => _selectedIndex = 1);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _acceptedSyncTimer?.cancel();
    _shareTabWorker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleAcceptedCallSync();
    }
  }

  void _scheduleAcceptedCallSync() {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    if (_acceptedSyncInFlight) return;
    _acceptedSyncTimer?.cancel();
    _acceptedSyncTimer = Timer(const Duration(milliseconds: 900), () async {
      _acceptedSyncInFlight = true;
      try {
        await IncomingCallKitCoordinator.syncAcceptedCallFromNativeIfNeeded();
      } catch (_) {
        // Safety net only: ignore to avoid taking down app startup.
      } finally {
        _acceptedSyncInFlight = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(color: _navBackground),
        child: Obx(() {
          final mailUnread = Get.isRegistered<HomeController>()
              ? Get.find<HomeController>().inboxUnreadCount.value
              : 0;
          final chatUnread = Get.isRegistered<ChatController>()
              ? Get.find<ChatController>()
                  .contacts
                  .fold<int>(0, (s, c) => s + c.unreadCount)
              : 0;
          return NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              indicatorColor: Colors.white.withValues(alpha: 0.22),
              iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
                final selected = states.contains(WidgetState.selected);
                return IconThemeData(
                  color: selected ? Colors.white : Colors.white.withValues(alpha: 0.75),
                );
              }),
              labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
                final selected = states.contains(WidgetState.selected);
                return TextStyle(
                  color: selected ? Colors.white : Colors.white.withValues(alpha: 0.8),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                );
              }),
            ),
            child: NavigationBar(
              height: 60,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (index) {
                setState(() {
                  _selectedIndex = index;
                });
                if (index == 2 && Get.isRegistered<CallsHistoryController>()) {
                  unawaited(Get.find<CallsHistoryController>().refresh(silent: true));
                }
              },
              destinations: [
                NavigationDestination(
                  icon: _TabIconBadge(icon: Icons.mail_outline, count: mailUnread),
                  selectedIcon: _TabIconBadge(icon: Icons.mail, count: mailUnread),
                  label: 'Mail',
                ),
                NavigationDestination(
                  icon: _TabIconBadge(icon: Icons.chat_bubble_outline, count: chatUnread),
                  selectedIcon: _TabIconBadge(icon: Icons.chat_bubble, count: chatUnread),
                  label: 'Chat',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.call_outlined),
                  selectedIcon: Icon(Icons.call),
                  label: 'Calls',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.calendar_today_outlined),
                  selectedIcon: Icon(Icons.calendar_today),
                  label: 'Reminder',
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _TabIconBadge extends StatelessWidget {
  const _TabIconBadge({required this.icon, required this.count});

  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return Icon(icon);
    final label = count > 99 ? '99+' : '$count';
    return Badge(
      label: Text(
        label,
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, height: 1.1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      isLabelVisible: true,
      child: Icon(icon),
    );
  }
}
