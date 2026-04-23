import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/chat/chat_image_message.dart';
import '../../../data/chat/chat_media_repository.dart';
import '../../../theme/app_theme.dart';

final chatVoiceFileCache = <String, String>{};

class ChatMessageVoiceBubble extends StatefulWidget {
  const ChatMessageVoiceBubble({
    super.key,
    required this.payload,
    required this.outgoing,
    required this.metaStyle,
    required this.timeLabel,
    this.trailingMeta,
    this.onRetry,
    this.onFirstPlayStarted,
  });

  final ChatVoiceMessage payload;
  final bool outgoing;
  final TextStyle metaStyle;
  final String timeLabel;
  final Widget? trailingMeta;
  final VoidCallback? onRetry;
  final VoidCallback? onFirstPlayStarted;

  @override
  State<ChatMessageVoiceBubble> createState() => _ChatMessageVoiceBubbleState();
}

class _ChatMessageVoiceBubbleState extends State<ChatMessageVoiceBubble> {
  static final ValueNotifier<String?> _activeKey = ValueNotifier<String?>(null);

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;

  bool _loading = true;
  bool _playing = false;
  double _downloadProgress = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  String? _sourcePath;
  String? _key;
  bool _reportedFirstPlay = false;

  @override
  void initState() {
    super.initState();
    _key = _voiceKey(widget.payload);
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing = s == PlayerState.playing;
      });
      if (s == PlayerState.completed) {
        _player.seek(Duration.zero);
        _activeKey.value = null;
      }
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        setState(() => _duration = d);
      }
    });
    _activeKey.addListener(_onGlobalActiveChanged);
    unawaited(_prepare());
  }

  @override
  void didUpdateWidget(covariant ChatMessageVoiceBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.url != widget.payload.url ||
        oldWidget.payload.localPath != widget.payload.localPath ||
        oldWidget.payload.hash != widget.payload.hash) {
      _key = _voiceKey(widget.payload);
      _position = Duration.zero;
      _duration = Duration(milliseconds: widget.payload.durationMs);
      _error = null;
      unawaited(_prepare());
    }
  }

  @override
  void dispose() {
    _activeKey.removeListener(_onGlobalActiveChanged);
    _stateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onGlobalActiveChanged() {
    if (_activeKey.value != _key && _player.state == PlayerState.playing) {
      unawaited(_player.pause());
    }
  }

  String _voiceKey(ChatVoiceMessage v) {
    final h = v.hash.trim().toLowerCase();
    if (h.isNotEmpty) return h;
    final u = v.url.trim();
    if (u.isNotEmpty) return u;
    final lp = v.localPath?.trim() ?? '';
    return lp;
  }

  Future<void> _prepare() async {
    setState(() {
      _loading = true;
      _downloadProgress = 0;
      _error = null;
      _sourcePath = null;
    });

    final p = widget.payload;
    _duration = Duration(milliseconds: p.durationMs);
    final local = p.localPath?.trim() ?? '';
    if (local.isNotEmpty && File(local).existsSync()) {
      await _setPlayerFromPath(local);
      return;
    }

    final key = _voiceKey(p);
    if (key.isNotEmpty && chatVoiceFileCache.containsKey(key)) {
      final cp = chatVoiceFileCache[key]!;
      if (File(cp).existsSync()) {
        await _setPlayerFromPath(cp);
        return;
      }
    }

    final url = p.url.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      setState(() {
        _loading = false;
      });
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      final h = key.isEmpty ? 'voice' : key;
      final out = '${dir.path}/chat_voice_$h.m4a';
      final file = File(out);
      if (!await file.exists() || await file.length() <= 0) {
        final bytes = await Get.find<ChatMediaRepository>().downloadUrl(
          url,
          onProgress: (a, b) {
            if (!mounted || b <= 0) return;
            setState(() => _downloadProgress = (a / b).clamp(0.0, 1.0));
          },
        );
        await file.writeAsBytes(bytes, flush: true);
      }
      if (h.isNotEmpty) {
        chatVoiceFileCache[h] = out;
      }
      await _setPlayerFromPath(out);
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load audio';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load audio';
      });
    }
  }

  Future<void> _setPlayerFromPath(String path) async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      if (!mounted) return;
      setState(() {
        _sourcePath = path;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not open audio';
      });
    }
  }

  Future<void> _togglePlay() async {
    if (_sourcePath == null || _loading) return;
    if (_playing) {
      await _player.pause();
      _activeKey.value = null;
      return;
    }
    final sourcePath = _sourcePath;
    if (sourcePath == null || sourcePath.isEmpty) return;
    _activeKey.value = _key;
    if (!_reportedFirstPlay) {
      _reportedFirstPlay = true;
      widget.onFirstPlayStarted?.call();
    }
    await _player.play(DeviceFileSource(sourcePath));
  }

  Future<void> _seekToFraction(double fraction) async {
    if (_sourcePath == null || _loading) return;
    final d = _duration;
    if (d <= Duration.zero) return;
    final f = fraction.clamp(0.0, 1.0);
    final target = Duration(milliseconds: (d.inMilliseconds * f).round());
    await _player.seek(target);
    if (mounted) {
      setState(() => _position = target);
    }
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 59);
    final m = d.inMinutes;
    final ss = s.toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final canRetry = p.status == 'failed' && widget.onRetry != null;
    final showUpload =
        widget.outgoing &&
        (p.status == 'uploading' ||
            p.status == 'pending' ||
            (p.status == null && p.url.isEmpty));
    final progress = showUpload
        ? p.progress.clamp(0.0, 1.0)
        : _downloadProgress.clamp(0.0, 1.0);
    final d = _duration > Duration.zero
        ? _duration
        : Duration(milliseconds: p.durationMs);
    final pos = _position > d ? d : _position;
    final shown = _playing ? pos : d;
    final frac = d.inMilliseconds <= 0
        ? 0.0
        : (pos.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
    final wave = p.waveform.isEmpty
        ? List<int>.generate(28, (i) => (30 + (i % 7) * 8).clamp(0, 100))
        : p.waveform;
    final playedBars = (wave.length * frac).floor();

    return SizedBox(
      width: 266,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Material(
                color: Colors.white.withValues(alpha: 0.14),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: canRetry ? widget.onRetry : _togglePlay,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Icon(
                      canRetry
                          ? Icons.refresh_rounded
                          : (_playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded),
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final width = c.maxWidth <= 0 ? 1.0 : c.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) =>
                          unawaited(_seekToFraction(d.localPosition.dx / width)),
                      onHorizontalDragUpdate: (d) => unawaited(
                        _seekToFraction(d.localPosition.dx / width),
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          SizedBox(
                            height: 18,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: List.generate(wave.length, (i) {
                                final v = wave[i];
                                final h = (3 + (v / 100) * 11).clamp(2.5, 14.0);
                                final active = i <= playedBars;
                                return Expanded(
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: Container(
                                      width: 2,
                                      height: h,
                                      decoration: BoxDecoration(
                                        color: active
                                            ? const Color(0xFF53C5FF)
                                            : Colors.white.withValues(alpha: 0.32),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                          Positioned(
                            left: (frac * width) - 4,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF47C2FF),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                showUpload || _loading ? _fmt(d) : _fmt(shown),
                style: GoogleFonts.ptSans(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (showUpload || _loading)
                SizedBox(
                  width: 52,
                  child: LinearProgressIndicator(
                    value: progress <= 0 ? null : progress,
                    minHeight: 2,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF47C2FF),
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(width: 8),
                Text(
                  _error!,
                  style: GoogleFonts.ptSans(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ],
              if (widget.trailingMeta != null) ...[
                const SizedBox(width: 8),
              if (_playing && widget.outgoing) ...[
                const Icon(
                  Icons.mic_rounded,
                  size: 13,
                  color: kPrimaryBlue,
                ),
                const SizedBox(width: 3),
              ],
                widget.trailingMeta!,
              ],
            ],
          ),
        ],
      ),
    );
  }
}
