import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/call/agora_call_service.dart';
import '../../../core/call/call_ringtone_service.dart';
import '../../../core/call/incoming_call_kit_coordinator.dart';

/// WhatsApp-style full-screen voice call: incoming, ringing (outgoing), and active.
/// Background: [assets/chat.jpeg]. Uses server [VoiceCallSession] + Agora RTC.
class AgoraAudioCallScreen extends StatefulWidget {
  const AgoraAudioCallScreen({
    super.key,
    required this.session,
    this.autoAcceptIncoming = false,
  });

  final VoiceCallSession session;

  /// When true (e.g. user tapped Accept on the incoming-call notification), join immediately.
  final bool autoAcceptIncoming;

  @override
  State<AgoraAudioCallScreen> createState() => _AgoraAudioCallScreenState();
}

class _AgoraAudioCallScreenState extends State<AgoraAudioCallScreen>
    with WidgetsBindingObserver {
  static Future<void> _engineLifecycleBarrier = Future<void>.value();
  RtcEngine? _engine;
  bool _connecting = false;
  bool _connected = false;
  bool _remoteJoined = false;
  bool _peerAccepted = false;
  bool _micMuted = false;
  bool _speakerOn = true;
  bool _joinedRtc = false;
  bool _pickedIncoming = false;

  /// Server told us the callee is being notified (socket online or FCM sent) — show "Ringing…" for caller.
  bool _peerNotifiedRinging = false;

  String? _statusLine;
  Timer? _callTimer;
  Duration _elapsed = Duration.zero;
  StreamSubscription<Map<String, dynamic>>? _sigSub;
  bool _isClosingScreen = false;
  bool _engineTeardownStarted = false;
  Timer? _closeDelayTimer;

  VoiceCallSession get _s => widget.session;

  bool get _isIncoming => _s.isIncoming;

  bool get _showIncomingAcceptReject =>
      _isIncoming && !_pickedIncoming && !_connected;

  bool get _rtcReady => _engine != null;

  /// Mic / speaker affect local stream once [RtcEngine] exists (both sides).
  bool get _canUseAudioControls => _rtcReady;

  /// White translucent control (opacity ~0.2), white icons.
  ButtonStyle get _glassControlStyle => IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.2),
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.12),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.45),
        minimumSize: const Size(56, 56),
      );

  ButtonStyle get _endCallStyle => IconButton.styleFrom(
        backgroundColor: const Color(0xFFE11D48).withValues(alpha: 0.92),
        foregroundColor: Colors.white,
        minimumSize: const Size(56, 56),
      );

  ButtonStyle get _acceptCallStyle => IconButton.styleFrom(
        backgroundColor: const Color(0xFF25D366),
        foregroundColor: Colors.white,
        minimumSize: const Size(72, 72),
      );

  ButtonStyle get _incomingDeclineStyle => IconButton.styleFrom(
        backgroundColor: const Color(0xFFE11D48).withValues(alpha: 0.92),
        foregroundColor: Colors.white,
        minimumSize: const Size(72, 72),
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusLine = null;
    if (!_isIncoming) {
      _peerNotifiedRinging = _s.outgoingCalleeRingingHint;
    }
    _bindSignaling();
    _syncRingToneLoop();
    if (_isIncoming) {
      _connecting = false;
      if (widget.autoAcceptIncoming) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_pickIncoming());
        });
      }
    } else {
      unawaited(_startOutgoing());
    }
  }

  void _bindSignaling() {
    final svc = Get.find<AgoraCallService>();
    _sigSub = svc.callEvents.listen((payload) {
      if (!_payloadMatchesThisCall(payload)) return;
      final ev = '${payload['_event'] ?? ''}'.trim();
      switch (ev) {
        case 'call_rejected':
          _stopRingToneLoop();
          _showTerminalStateThenClose('Call rejected');
          return;
        case 'call_cancelled':
          _stopRingToneLoop();
          _showTerminalStateThenClose('Call cancelled');
          return;
        case 'call_missed':
          _stopRingToneLoop();
          _showTerminalStateThenClose('No answer');
          return;
        case 'call_failed':
          _stopRingToneLoop();
          _showTerminalStateThenClose('Call failed');
          return;
        case 'call_timeout':
          _stopRingToneLoop();
          _showTerminalStateThenClose('Call timed out');
          return;
        case 'call_ended':
          if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
            debugPrint('[callkit-ios] call ended reason=${payload['reason'] ?? 'ended'}');
          }
          _stopRingToneLoop();
          _showTerminalStateThenClose('Call ended');
          return;
        case 'call_remote_ringing':
          if (!_isIncoming && mounted) {
            setState(() {
              _peerNotifiedRinging = true;
              if (!(_statusLine?.contains('error') ?? false)) {
                _statusLine = null;
              }
            });
            _syncRingToneLoop();
          }
          return;
        case 'call_accepted':
          if (!_isIncoming && mounted) {
            setState(() {
              _peerAccepted = true;
              _statusLine = null;
            });
            _syncRingToneLoop();
          }
          return;
        case 'remote_user_joined':
          _stopRingToneLoop();
          return;
        default:
          return;
      }
    });
  }

  String _statusForDisplay() {
    final m = _statusLine;
    if (m != null &&
        (m.contains('error') ||
            m.contains('permission') ||
            m.contains('denied'))) {
      return m;
    }
    if (_isIncoming && !_pickedIncoming) return 'Incoming call';
    if (_remoteJoined) return 'In call';
    if (!_isIncoming && !_remoteJoined) {
      if (_peerAccepted) return 'Connecting…';
      return _peerNotifiedRinging ? 'Ringing…' : 'Calling…';
    }
    if (_isIncoming && _pickedIncoming && !_remoteJoined) {
      return _connecting ? 'Connecting…' : 'Connecting…';
    }
    return m ?? 'Connecting…';
  }

  bool _payloadMatchesThisCall(Map<String, dynamic> payload) {
    final callId = _signalString(payload, const ['callId', 'call_id', 'id']);
    if (callId.isNotEmpty &&
        (callId == _s.callId || callId == _s.channelName)) {
      return true;
    }
    final channel = _signalString(payload, const ['channelName', 'channelId']);
    if (channel.isNotEmpty &&
        (channel == _s.channelName || channel == _s.callId)) {
      return true;
    }
    return false;
  }

  String _signalString(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      final value = '${payload[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<void> _startOutgoing() async {
    if (_joinedRtc) return;
    await _runJoinFlow();
  }

  Future<void> _runJoinFlow() async {
    if (_joinedRtc) return;
    _joinedRtc = true;
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
      debugPrint('[callkit-ios] Agora init start');
    }
    setState(() {
      _connecting = true;
      if (!(_statusLine?.contains('error') ?? false)) {
        _statusLine = null;
      }
    });
    _syncRingToneLoop();
    await _engineLifecycleBarrier;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _statusLine = 'Microphone permission denied';
      });
      _joinedRtc = false;
      _syncRingToneLoop();
      return;
    }

    final appId = _s.effectiveAppId;
    final engine = createAgoraRtcEngine();
    _engine = engine;
    await engine.initialize(RtcEngineContext(appId: appId));
    await engine.enableAudio();
    await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
    // Do not call setEnableSpeakerphone here — on many Android devices it returns
    // -3 (not ready) before join; apply after onJoinChannelSuccess instead.

    engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
            debugPrint('[callkit-ios] Agora join success');
          }
          if (!mounted) return;
          setState(() {
            _connecting = false;
            _connected = true;
            if (!(_statusLine?.contains('error') ?? false)) {
              _statusLine = null;
            }
          });
          _syncRingToneLoop();
          final eng = _engine;
          if (eng != null) {
            unawaited(_safeSetSpeakerphone(eng, _speakerOn));
          }
        },
        onUserJoined: (connection, uid, elapsed) {
          if (!mounted) return;
          setState(() {
            _remoteJoined = true;
            _statusLine = null;
          });
          _startCallTimer();
          _syncRingToneLoop();
        },
        onUserOffline: (connection, uid, reason) {
          if (!mounted) return;
          setState(() {
            _remoteJoined = false;
            _statusLine = 'Call ended';
          });
          _callTimer?.cancel();
          _syncRingToneLoop();
          unawaited(_leaveAndPop());
        },
        onLeaveChannel: (connection, stats) {
          _closeScreenOnce();
        },
        onError: (err, msg) {
          if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
            debugPrint('[callkit-ios] Agora join failure err=$err msg=$msg');
          }
          if (!mounted) return;
          setState(() {
            _connecting = false;
            _statusLine = 'Connection error ($err)';
          });
          _syncRingToneLoop();
        },
      ),
    );

    if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
      debugPrint('[callkit-ios] Agora join start');
    }
    await engine.joinChannel(
      token: _s.token ?? '',
      channelId: _s.channelName,
      uid: _s.localUid,
      options: const ChannelMediaOptions(),
    );
  }

  Future<void> _leaveAndPop() async {
    _stopRingToneLoop();
    await _teardownEngineOnce();
    if (Get.isRegistered<AgoraCallService>()) {
      await Get.find<AgoraCallService>().endCall(_s.callId, reason: 'ended');
    }
    _closeScreenOnce();
  }

  Future<void> _rejectOrDecline() async {
    _stopRingToneLoop();
    if (Get.isRegistered<AgoraCallService>()) {
      await Get.find<AgoraCallService>().rejectCall(_s.callId);
    }
    if (!mounted) return;
    Get.find<AgoraCallService>().releaseCallUi(_s.callId);
    _closeScreenOnce();
  }

  Future<void> _endCall() async {
    _stopRingToneLoop();
    if (_isIncoming && !_pickedIncoming) {
      await _rejectOrDecline();
      return;
    }
    if (!_connected && !_isIncoming) {
      await Get.find<AgoraCallService>().endCall(_s.callId, reason: 'cancelled');
    } else {
      await Get.find<AgoraCallService>().endCall(_s.callId, reason: 'ended');
    }
    await _teardownEngineOnce();
    if (_engine == null) {
      if (!mounted) return;
      Get.find<AgoraCallService>().releaseCallUi(_s.callId);
      _closeScreenOnce();
    }
  }

  void _closeScreenOnce() {
    if (!mounted || _isClosingScreen) return;
    _isClosingScreen = true;
    Navigator.of(context).maybePop();
  }

  void _showTerminalStateThenClose(String message) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _remoteJoined = false;
      _statusLine = message;
    });
    _closeDelayTimer?.cancel();
    _closeDelayTimer = Timer(const Duration(seconds: 2), _closeScreenOnce);
  }

  Future<void> _pickIncoming() async {
    if (_pickedIncoming) return;
    setState(() {
      _pickedIncoming = true;
      _connecting = true;
      _statusLine = null;
    });
    _syncRingToneLoop();
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.iOS) {
      debugPrint('[callkit-ios] incoming accept flow start');
    }
    try {
      await Get.find<AgoraCallService>().acceptCall(_s.callId);
    } catch (_) {
      /* still attempt RTC — server may have already transitioned */
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final activated = await IncomingCallKitCoordinator.waitForAudioSessionActivation(
        retryDelay: const Duration(milliseconds: 300),
        maxRetries: 8,
      );
      if (kDebugMode) {
        debugPrint('[callkit-ios] audio session activated before Agora=$activated');
      }
      if (!activated) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    await _runJoinFlow();
  }

  void _syncRingToneLoop() {
    // Keep an audible cue while ringing:
    // - incoming before user accepts/rejects
    // - outgoing until peer accepts or joins
    final shouldPlay =
        (_isIncoming && !_pickedIncoming) ||
        (!_isIncoming && !_remoteJoined && !_peerAccepted);
    if (!shouldPlay) {
      unawaited(_stopRingToneLoop());
      return;
    }
    if (CallRingtoneService.isPlaying) return;
    unawaited(CallRingtoneService.playLoop());
  }

  Future<void> _stopRingToneLoop() async {
    await CallRingtoneService.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_stopRingToneLoop());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _syncRingToneLoop();
    }
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _elapsed = Duration.zero;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  /// [setEnableSpeakerphone] can throw -3 on Android if the audio route is not ready yet.
  Future<void> _safeSetSpeakerphone(RtcEngine engine, bool on) async {
    try {
      await engine.setEnableSpeakerphone(on);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[agora] setEnableSpeakerphone failed: $e');
      }
    }
  }

  Future<void> _toggleSpeaker() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_speakerOn;
    await _safeSetSpeakerphone(engine, next);
    if (!mounted) return;
    setState(() => _speakerOn = next);
  }

  Future<void> _toggleMute() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_micMuted;
    await engine.muteLocalAudioStream(next);
    if (!mounted) return;
    setState(() => _micMuted = next);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopRingToneLoop());
    _closeDelayTimer?.cancel();
    _sigSub?.cancel();
    _callTimer?.cancel();
    Get.find<AgoraCallService>().releaseCallUi(_s.callId);
    // Never call leaveChannel/release from multiple paths in parallel.
    unawaited(_teardownEngineOnce());
    super.dispose();
  }

  Future<void> _teardownEngineOnce() async {
    if (_engineTeardownStarted) return;
    _engineTeardownStarted = true;
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    _engineLifecycleBarrier = _engineLifecycleBarrier.then((_) async {
      try {
        await engine.leaveChannel();
      } catch (_) {
        /* channel may already be left */
      }
      try {
        await engine.release();
      } catch (_) {
        /* non-fatal */
      }
    });
    await _engineLifecycleBarrier;
  }

  @override
  Widget build(BuildContext context) {
    final mm = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    final initials = _s.peerName.trim().isEmpty
        ? '?'
        : _s.peerName.trim()[0].toUpperCase();

    final status = _statusForDisplay();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/chat.jpeg',
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
            ),
          ),
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 26),
                Text(
                  _s.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 16,
                  ),
                ),
                if (_remoteJoined) ...[
                  const SizedBox(height: 6),
                  Text(
                    '$mm:$ss',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                CircleAvatar(
                  radius: 96,
                  backgroundColor: const Color(0xFF4A3523).withValues(alpha: 0.9),
                  child: Text(
                    initials,
                    style: const TextStyle(
                      color: Color(0xFFFFD98B),
                      fontSize: 80,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                  child: _buildControls(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    if (_showIncomingAcceptReject) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton.filled(
            style: _acceptCallStyle,
            onPressed: _pickIncoming,
            icon: const Icon(Icons.call_rounded, size: 30, color: Colors.white),
          ),
          IconButton.filled(
            style: _incomingDeclineStyle,
            onPressed: _rejectOrDecline,
            icon: const Icon(Icons.call_end_rounded, size: 28, color: Colors.white),
          ),
        ],
      );
    }

    if (!_isIncoming && !_remoteJoined) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filled(
            style: _endCallStyle,
            onPressed: _endCall,
            icon: const Icon(Icons.call_end_rounded, size: 28, color: Colors.white),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton.filled(
          style: _glassControlStyle,
          onPressed: _canUseAudioControls ? _toggleMute : null,
          icon: Icon(
            _micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            color: Colors.white,
          ),
        ),
        IconButton.filled(
          style: _glassControlStyle,
          onPressed: _canUseAudioControls ? _toggleSpeaker : null,
          icon: Icon(
            _speakerOn ? Icons.volume_up_rounded : Icons.hearing_disabled_rounded,
            color: Colors.white,
          ),
        ),
        IconButton.filled(
          style: _endCallStyle,
          onPressed: _endCall,
          icon: const Icon(Icons.call_end_rounded, size: 28, color: Colors.white),
        ),
      ],
    );
  }
}
