import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/mailto/mailto_link_service.dart';
import 'core/push/push_notification_service.dart';
import 'core/network/auth_interceptor.dart';
import 'core/network/dio_client.dart';
import 'data/auth/auth_repository.dart';
import 'data/mail/mail_repository.dart';
import 'data/session/session_storage.dart';
import 'firebase_options.dart';
import 'push/firebase_messaging_background.dart';
import 'screens/splash/view/splash_view.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  Get.put<MailRepository>(
    MailRepository(Get.find<Dio>()),
    permanent: true,
  );
  Get.put(
    MailtoLinkService(Get.find<SessionStorage>()),
    permanent: true,
  );
  Get.put(PendingMailNotification(), permanent: true);
  runApp(const SealpostApp());
}

class SealpostApp extends StatefulWidget {
  const SealpostApp({super.key});

  @override
  State<SealpostApp> createState() => _SealpostAppState();
}

class _SealpostAppState extends State<SealpostApp> {
  StreamSubscription<Uri>? _appLinkSub;

  @override
  void initState() {
    super.initState();
    unawaited(_initAppLinks());
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
    final sub = _appLinkSub;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    super.dispose();
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