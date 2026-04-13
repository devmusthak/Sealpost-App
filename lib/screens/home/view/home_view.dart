import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../../core/mailto/mailto_link_service.dart';
import '../../../core/push/push_notification_service.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/mail/mail_list_item.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/hex_header_background.dart';
import '../../compose/view/compose_view.dart';
import '../../mail_detail/view/mail_detail_view.dart';
import '../controller/home_controller.dart';
import 'mail_search_delegate.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final Worker _mailtoWorker;

  @override
  void initState() {
    super.initState();
    _controller = Get.put(HomeController());
    _mailtoWorker = ever(Get.find<MailtoLinkService>().pending, (_) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _openMailtoFromPending());
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openMailtoFromPending());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(PushNotificationService.syncFcmTokenToServer());
      PushNotificationService.tryNavigateToMailDetail();
    });
  }

  void _openMailtoFromPending() {
    if (!mounted) return;
    final open = Get.find<MailtoLinkService>().takePendingMailto();
    if (open == null) return;
    Get.to<void>(
      () => ComposeScreen(
        prefill: open.prefill,
        mailtoSourceUri: open.sourceUri,
      ),
    );
  }

  @override
  void dispose() {
    _mailtoWorker.dispose();
    Get.delete<HomeController>();
    super.dispose();
  }

  /// Figma: near-black canvas behind list.
  static const _overlay = Color(0xFF121212);

  /// Figma: unified search bar fill (charcoal, slightly above main bg).
  static const _appBarSurface = Color(0xFF202124);

  /// Figma: hint / secondary label on bar.
  static const _searchHint = Color(0xFF9AA0A6);

  /// Figma: menu icon (soft white).
  static const _appBarIcon = Color(0xFFE8EAED);

  /// Sidebar (drawer) brand header height.
  static const double _drawerHeaderHeight = 160;

  static const _drawerDivider = Color(0xFF3C4043);
  static const _logoutRed = Color(0xFFEA4335);

  Widget _homeDrawer(BuildContext context) {
    return Drawer(
      backgroundColor: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SvgPicture.asset(
            'assets/head-login.svg',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
          ColoredBox(color: _overlay.withValues(alpha: 0.88)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: _drawerHeaderHeight,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CustomPaint(painter: HexHeaderPainter()),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              kHexHeaderBaseColor.withValues(alpha: 0),
                              _overlay,
                            ],
                            stops: const [0.35, 1],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SvgPicture.asset(
                                'assets/logo.svg',
                                fit: BoxFit.contain,
                                width: 30,
                                height: 30,
                              ),
                              const SizedBox(width: 14),
                              Text(
                                'SEALPOST',
                                style: sealpostWordmarkStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: _drawerDivider),
              Expanded(
                child: Obx(() {
                  final current = _controller.selectedFolder.value;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _DrawerNavTile(
                        icon: Icons.inbox_outlined,
                        label: 'Inbox',
                        selected: current == HomeFolder.inbox,
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(_controller.selectFolder(HomeFolder.inbox));
                        },
                      ),
                      _DrawerNavTile(
                        icon: Icons.send_outlined,
                        label: 'Sent',
                        selected: current == HomeFolder.sent,
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(_controller.selectFolder(HomeFolder.sent));
                        },
                      ),
                    ],
                  );
                }),
              ),
              const Divider(height: 1, color: _drawerDivider),
              ListTile(
                leading: Icon(
                  Icons.logout_rounded,
                  color: _logoutRed,
                  size: 24,
                ),
                title: Text(
                  'Log out',
                  style: GoogleFonts.ptSans(
                    color: _logoutRed,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_controller.logout());
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthRepository>().session;
    final userName = auth?.name ?? '';
    final initial = _firstInitial(
      userName.isNotEmpty ? userName : (auth?.email ?? '?'),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: _overlay,
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle(
                statusBarColor: _overlay,
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
                systemNavigationBarColor: _overlay,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
            );
          } else {
            SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
          }
        },
        drawer: _homeDrawer(context),
        body: Stack(
          fit: StackFit.expand,
          children: [
            SvgPicture.asset(
              'assets/head-login.svg',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
            ColoredBox(color: _overlay.withValues(alpha: 0.88)),
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    child: _HomeSearchAppBar(
                      surfaceColor: _appBarSurface,
                      hintColor: _searchHint,
                      iconColor: _appBarIcon,
                      initial: initial,
                      onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
                      onSearchTap: () async {
                        final picked = await showSearch<MailListItem?>(
                          context: context,
                          delegate: MailSearchDelegate(controller: _controller),
                        );
                        if (!context.mounted || picked == null) return;
                        Get.to<bool?>(
                          () => MailDetailScreen(
                            mailId: picked.id,
                            preview: picked,
                            folderKey: _controller.selectedFolder.value,
                          ),
                        )?.then((deleted) {
                          if (deleted == true) {
                            _controller.refreshInbox();
                          }
                        });
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                    child: Obx(
                      () => Text(
                        _controller.folderSectionLabel,
                        style: GoogleFonts.ptSans(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.35,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Obx(() {
                      final err = _controller.errorMessage.value;
                      if (err != null &&
                          err.isNotEmpty &&
                          _controller.mails.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppText(
                                  err,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                const SizedBox(height: 16),
                                TextButton(
                                  onPressed: _controller.refreshInbox,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      final loading =
                          _controller.isLoading.value &&
                          _controller.mails.isEmpty;
                      if (!loading && _controller.mails.isEmpty) {
                        return Center(
                          child: AppText(
                            'No messages yet',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 15,
                            ),
                          ),
                        );
                      }

                      return RefreshIndicator(
                        color: kPrimaryBlue,
                        backgroundColor: _appBarSurface,
                        onRefresh: _controller.refreshInbox,
                        child: Skeletonizer(
                          enabled: loading,
                          effect: const ShimmerEffect(
                            baseColor: Color(0xFF2A2A2A),
                            highlightColor: Color(0xFF3D3D3D),
                            duration: Duration(milliseconds: 1100),
                          ),
                          child: ListView.separated(
                            separatorBuilder: (context, index) => Divider(
                              color: Colors.white.withValues(alpha: 0.05),
                              height: 2,
                            ),
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            padding: const EdgeInsets.fromLTRB(0, 0, 0, 100),
                            itemCount: loading ? 9 : _controller.mails.length,
                            itemBuilder: (context, index) {
                              final item = loading
                                  ? MailListItem.skeletonSeed(index)
                                  : _controller.mails[index];
                              return _MailRow(
                                item: item,
                                index: index,
                                onTap: loading
                                    ? null
                                    : () {
                                        Get.to<bool?>(
                                          () => MailDetailScreen(
                                            mailId: item.id,
                                            preview: item,
                                            folderKey: _controller
                                                .selectedFolder
                                                .value,
                                          ),
                                        )?.then((deleted) {
                                          if (deleted == true) {
                                            _controller.refreshInbox();
                                          }
                                        });
                                      },
                              );
                            },
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 16,
              bottom: 24 + MediaQuery.paddingOf(context).bottom,
              child: Material(
                color: kPrimaryBlue,
                borderRadius: BorderRadius.circular(28),
                elevation: 6,
                child: InkWell(
                  onTap: () async {
                    await Get.to<void>(() => const ComposeScreen());
                    if (context.mounted) _controller.refreshInbox();
                  },
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.edit_outlined,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Compose',
                          style: GoogleFonts.ptSans(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerNavTile extends StatelessWidget {
  const _DrawerNavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? kPrimaryBlue : Colors.white70;
    return ListTile(
      leading: Icon(icon, color: accent, size: 24),
      title: Text(
        label,
        style: GoogleFonts.ptSans(
          color: selected ? kPrimaryBlue : Colors.white,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          fontSize: 16,
        ),
      ),
      selected: selected,
      selectedTileColor: kPrimaryBlue.withValues(alpha: 0.12),
      onTap: onTap,
    );
  }
}

class _HomeSearchAppBar extends StatelessWidget {
  const _HomeSearchAppBar({
    required this.surfaceColor,
    required this.hintColor,
    required this.iconColor,
    required this.initial,
    required this.onMenuTap,
    required this.onSearchTap,
  });

  final Color surfaceColor;
  final Color hintColor;
  final Color iconColor;
  final String initial;
  final VoidCallback onMenuTap;
  final VoidCallback onSearchTap;

  static const double _pillRadius = 28;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onMenuTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 48,
              child: Icon(Icons.menu, size: 22, color: iconColor),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Material(
            color: surfaceColor,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            surfaceTintColor: Colors.transparent,
            borderRadius: BorderRadius.circular(_pillRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onSearchTap,
              borderRadius: BorderRadius.circular(_pillRadius),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 24, color: hintColor),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Search in mail',
                        style: GoogleFonts.ptSans(
                          color: hintColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        CircleAvatar(
          radius: 18,
          backgroundColor: kPrimaryBlue.withValues(alpha: 0.92),
          child: Text(
            initial,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 15,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

class _MailRow extends StatelessWidget {
  const _MailRow({required this.item, required this.index, this.onTap});

  final MailListItem item;
  final int index;
  final VoidCallback? onTap;

  static const _avatars = [
    Color(0xFF7C4DFF),
    Color(0xFF448AFF),
    Color(0xFF26A69A),
    Color(0xFFFFA726),
    Color(0xFFEC407A),
  ];

  @override
  Widget build(BuildContext context) {
    final letter = _firstInitial(
      item.fromName.isNotEmpty ? item.fromName : '?',
    );
    final avatarColor = _avatars[index % _avatars.length];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: avatarColor,
                child: Text(
                  letter,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      item.fromName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      item.subject ?? '(No subject)',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      item.snippet,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13,
                        height: 1.25,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatShortDate(item.date),
                    style: GoogleFonts.ptSans(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Icon(
                    item.flagged ? Icons.star : Icons.star_border,
                    size: 20,
                    color: Colors.white38,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _firstInitial(String s) {
  final t = s.trim();
  if (t.isEmpty) return '?';
  return t[0].toUpperCase();
}

String _formatShortDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${_months[d.month - 1]} ${d.day}';
}
