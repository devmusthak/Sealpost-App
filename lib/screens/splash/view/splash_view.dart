import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

import '../../../core/push/push_notification_service.dart';
import '../../../theme/app_theme.dart';
import '../controller/splash_controller.dart';
import '../model/splash_constants.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _bgOpacity;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoScale;
  late final SplashController _splash;

  @override
  void initState() {
    super.initState();
    _splash = Get.put(SplashController());
    _anim = AnimationController(
      vsync: this,
      duration: SplashConstants.animationDuration,
    );
    _bgOpacity = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOutCubic),
    );
    _logoOpacity = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.12, 0.55, curve: Curves.easeOut),
    );
    _logoScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(
        parent: _anim,
        curve: const Interval(0.12, 0.65, curve: Curves.easeOutBack),
      ),
    );

    _anim.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(PushNotificationService.requestPermissionAndSetupListeners());
    });

    Future<void>.delayed(SplashConstants.navigateDelay, () async {
      if (!mounted) return;
      await _splash.navigateAfterSplash();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    Get.delete<SplashController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: _bgOpacity.value,
                child: SvgPicture.asset(
                  'assets/splash-bg.svg',
                  fit: BoxFit.cover,
                ),
              ),
              Center(
                child: Opacity(
                  opacity: _logoOpacity.value,
                  child: Transform.scale(
                    scale: _logoScale.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SvgPicture.asset(
                          'assets/logo.svg',
                          width: 72,
                          height: 72,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'SEALPOST',
                          style: sealpostWordmarkStyle(
                            color: Colors.white.withValues(
                              alpha: 0.85 + 0.15 * _logoOpacity.value,
                            ),
                            fontSize: 28,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
