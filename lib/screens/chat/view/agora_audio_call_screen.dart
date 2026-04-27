import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/call/agora_call_service.dart';

class AgoraAudioCallScreen extends StatefulWidget {
  const AgoraAudioCallScreen({
    super.key,
    required this.appId,
    required this.peerName,
    required this.session,
  });

  final String appId;
  final String peerName;
  final AgoraCallSession session;

  @override
  State<AgoraAudioCallScreen> createState() => _AgoraAudioCallScreenState();
}

class _AgoraAudioCallScreenState extends State<AgoraAudioCallScreen> {
  RtcEngine? _engine;
  bool _connecting = true;
  bool _connected = false;
  bool _remoteJoined = false;
  bool _micMuted = false;
  String? _status;
  int? _remoteUid;
  Timer? _callTimer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _status = 'Microphone permission denied';
      });
      return;
    }

    final engine = createAgoraRtcEngine();
    _engine = engine;
    await engine.initialize(RtcEngineContext(appId: widget.appId));
    await engine.enableAudio();
    await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

    engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          if (!mounted) return;
          setState(() {
            _connecting = false;
            _connected = true;
            _status = 'Connected';
          });
          _callTimer?.cancel();
          _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (!mounted) return;
            setState(() => _elapsed += const Duration(seconds: 1));
          });
        },
        onUserJoined: (connection, uid, elapsed) {
          if (!mounted) return;
          setState(() {
            _remoteUid = uid;
            _remoteJoined = true;
            _status = 'In call';
          });
        },
        onUserOffline: (connection, uid, reason) {
          if (!mounted) return;
          setState(() {
            _remoteUid = null;
            _remoteJoined = false;
            _status = 'Peer left the call';
          });
        },
        onLeaveChannel: (connection, stats) {
          if (!mounted) return;
          Navigator.of(context).maybePop();
        },
        onError: (err, msg) {
          if (!mounted) return;
          setState(() {
            _connecting = false;
            _status = 'Agora error $err: $msg';
          });
        },
      ),
    );

    await engine.joinChannel(
      token: widget.session.token ?? '',
      channelId: widget.session.channelName,
      uid: widget.session.localUid,
      options: const ChannelMediaOptions(),
    );
  }

  Future<void> _endCall() async {
    final engine = _engine;
    if (engine != null) {
      await engine.leaveChannel();
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
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
    _callTimer?.cancel();
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      unawaited(engine.leaveChannel());
      unawaited(engine.release());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mm = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Call')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.peerName,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(_status ?? (_connecting ? 'Connecting...' : 'Ready')),
              const SizedBox(height: 10),
              if (_connected) Text('$mm:$ss', style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 8),
              Text(_remoteJoined ? 'Peer joined' : 'Waiting for peer...'),
              if (_remoteUid != null) Text('Remote uid: $_remoteUid'),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    onPressed: _connected ? _toggleMute : null,
                    icon: Icon(_micMuted ? Icons.mic_off_rounded : Icons.mic_rounded),
                  ),
                  const SizedBox(width: 20),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _endCall,
                    icon: const Icon(Icons.call_end_rounded),
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
