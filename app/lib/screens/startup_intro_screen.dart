import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../startup/startup_intro_preferences.dart';

const String _introAssetPath = 'assets/videos/storyvault_intro.mp4';

class StartupIntroGate extends StatefulWidget {
  const StartupIntroGate({required this.child, super.key});

  final Widget child;

  @override
  State<StartupIntroGate> createState() => _StartupIntroGateState();
}

class _StartupIntroGateState extends State<StartupIntroGate> {
  bool? _showIntro;

  @override
  void initState() {
    super.initState();
    _loadIntroState();
  }

  Future<void> _loadIntroState() async {
    final bool showIntro = await consumeStartupIntroOnNextBoot();
    if (!mounted) {
      return;
    }
    setState(() => _showIntro = showIntro);
  }

  void _finishIntro() {
    if (!mounted) {
      return;
    }
    setState(() => _showIntro = false);
  }

  @override
  Widget build(BuildContext context) {
    final showIntro = _showIntro;
    if (showIntro == null) {
      return const ColoredBox(color: Colors.black);
    }
    if (showIntro) {
      return StartupIntroScreen(onComplete: _finishIntro);
    }
    return widget.child;
  }
}

class StartupIntroScreen extends StatefulWidget {
  const StartupIntroScreen({required this.onComplete, super.key});

  final VoidCallback onComplete;

  @override
  State<StartupIntroScreen> createState() => _StartupIntroScreenState();
}

class _StartupIntroScreenState extends State<StartupIntroScreen> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  bool _completed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset(_introAssetPath)
      ..addListener(_handleVideoTick);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setVolume(1);
      await _controller.play();
      if (!mounted) {
        return;
      }
      setState(() => _ready = true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
      Future<void>.delayed(const Duration(milliseconds: 700), _complete);
    }
  }

  void _handleVideoTick() {
    if (_completed || !_controller.value.isInitialized) {
      return;
    }
    final value = _controller.value;
    if (value.hasError) {
      _complete();
      return;
    }
    final duration = value.duration;
    if (duration == Duration.zero) {
      return;
    }
    if (value.position >= duration - const Duration(milliseconds: 150)) {
      _complete();
    }
  }

  void _complete() {
    if (_completed) {
      return;
    }
    _completed = true;
    widget.onComplete();
  }

  @override
  void dispose() {
    _controller.removeListener(_handleVideoTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready)
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            )
          else
            const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
          if (_error != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Opening StoryVault...',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextButton(
                  onPressed: _complete,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black.withValues(alpha: 0.42),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  child: const Text(
                    'Skip',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
