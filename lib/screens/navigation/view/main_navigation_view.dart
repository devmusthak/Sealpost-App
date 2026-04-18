import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../chat/controller/chat_controller.dart';
import '../../chat/view/chat_view.dart';
import '../../home/controller/home_controller.dart';
import '../../home/view/home_view.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;
    static const _navBackground = Color(0xFF121212);

  late final List<Widget> _tabs = const [
    HomeScreen(),
    ChatScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _tabs),
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
