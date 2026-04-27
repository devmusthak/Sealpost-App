import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/call/agora_call_service.dart';
import 'core/mailto/mailto_link_service.dart';
import 'core/share/share_receive_service.dart';
import 'core/push/push_notification_service.dart';
import 'core/network/auth_interceptor.dart';
import 'core/network/dio_client.dart';
import 'data/auth/auth_repository.dart';
import 'data/chat/chat_media_repository.dart';
import 'data/chat/chat_repository.dart';
import 'screens/chat/chat_forward_opener.dart';
import 'screens/chat/chat_forward_opener_impl.dart';
import 'screens/chat/controller/chat_controller.dart';
import 'data/mail/mail_repository.dart';
import 'package:sealpost/data/session/session_storage.dart';
import 'data/session/account_session_manager.dart';
import 'firebase_options.dart';
import 'push/firebase_messaging_background.dart';
import 'screens/splash/view/splash_view.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  final sessionStorage = await SessionStorage.create();
  final dio = createDio();
  dio.interceptors.add(AuthInterceptor());
  Get.put<Dio>(dio, permanent: true);
  Get.put<SessionStorage>(sessionStorage, permanent: true);
  Get.put(
    AuthRepository(Get.find<Dio>(), Get.find<SessionStorage>()),
    permanent: true,
  );
  final accountManager = await AccountSessionManager().init();
  Get.put<AccountSessionManager>(accountManager, permanent: true);
  Get.put<MailRepository>(
    MailRepository(Get.find<Dio>()),
    permanent: true,
  );
  Get.put<ChatRepository>(ChatRepository(Get.find<Dio>()), permanent: true);
  Get.put<ChatMediaRepository>(
    ChatMediaRepository(Get.find<Dio>()),
    permanent: true,
  );
  Get.put<ChatController>(ChatController(), permanent: true);
  Get.put<ChatForwardOpener>(ChatForwardOpenerImpl(), permanent: true);
  Get.put<AgoraCallService>(AgoraCallService(), permanent: true);
  Get.put(
    MailtoLinkService(Get.find<SessionStorage>()),
    permanent: true,
  );
  Get.put(ShareReceiveService(), permanent: true);
  Get.put(PendingMailNotification(), permanent: true);
  Get.put(PendingChatNotification(), permanent: true);
  runApp(const SealpostApp());
}

class SealpostApp extends StatefulWidget {
  const SealpostApp({super.key});

  @override
  State<SealpostApp> createState() => _SealpostAppState();
}

class _SealpostAppState extends State<SealpostApp> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _appLinkSub;
  Timer? _presenceHeartbeat;
  bool _presenceForeground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initAppLinks());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPresenceFromLifecycle();
    });
  }

  void _goPresenceForeground() {
    if (_presenceForeground) return;
    _presenceForeground = true;
    unawaited(_updatePresence(online: true));
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = Timer.periodic(const Duration(seconds: 35), (_) {
      if (_presenceForeground) unawaited(_updatePresence(online: true));
    });
  }

  void _goPresenceBackground() {
    if (!_presenceForeground) return;
    _presenceForeground = false;
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    unawaited(_updatePresence(online: false));
  }

  void _syncPresenceFromLifecycle() {
    if (!mounted) return;
    final s = WidgetsBinding.instance.lifecycleState;
    switch (s) {
      case AppLifecycleState.resumed:
        _goPresenceForeground();
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _goPresenceBackground();
        break;
      case null:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final s2 = WidgetsBinding.instance.lifecycleState;
          if (s2 == AppLifecycleState.resumed) {
            _goPresenceForeground();
          }
        });
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _goPresenceForeground();
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _goPresenceBackground();
        break;
    }
  }

  Future<void> _initAppLinks() async {
    final appLinks = AppLinks();
    try {
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        Get.find<MailtoLinkService>().ingestUri(initial);
      }
    } catch (_) {
      /* cold start link optional */
    }
    _appLinkSub = appLinks.uriLinkStream.listen((uri) {
      Get.find<MailtoLinkService>().ingestUri(uri, fromExternalTap: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceHeartbeat?.cancel();
    unawaited(_updatePresence(online: false));
    final sub = _appLinkSub;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _updatePresence({required bool online}) async {
    if (!Get.isRegistered<AuthRepository>()) return;
    await Get.find<AuthRepository>().updatePresence(online: online);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kPrimaryBlue,
      brightness: Brightness.light,
    );
    final baseTheme = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
      ),
    );
    return GetMaterialApp(
      title: 'sealpost',
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(
        textTheme: GoogleFonts.ptSansTextTheme(baseTheme.textTheme),
      ),
      home: const SplashScreen(),
    );
  }
}