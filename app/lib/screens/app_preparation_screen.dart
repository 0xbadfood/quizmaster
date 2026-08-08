import 'package:flutter/material.dart';

import '../startup/app_preparation.dart';
import '../theme/app_theme.dart';

const String _talkPreparationGif =
    'assets/images/talk_preparation_progress.gif';
const String _resultWizardAsset = 'assets/personas/wizard_wonder.png';

class AppPreparationGate extends StatefulWidget {
  const AppPreparationGate({
    required this.controller,
    required this.childBuilder,
    super.key,
  });

  final AppPreparationController controller;
  final WidgetBuilder childBuilder;

  @override
  State<AppPreparationGate> createState() => _AppPreparationGateState();
}

class _AppPreparationGateState extends State<AppPreparationGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final AppPreparationController controller = widget.controller;
      if (controller.localTtsEnabled) {
        return;
      }
      if (controller.state == AppPreparationState.ready &&
          controller.report != null) {
        controller.retry();
        return;
      }
      controller.prepare();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        if (widget.controller.localTtsEnabled &&
            widget.controller.state == AppPreparationState.ready) {
          return widget.childBuilder(context);
        }
        return AppPreparationScreen(controller: widget.controller);
      },
    );
  }
}

class AppPreparationScreen extends StatelessWidget {
  const AppPreparationScreen({required this.controller, super.key});

  final AppPreparationController controller;

  @override
  Widget build(BuildContext context) {
    final bool showingResult = controller.state == AppPreparationState.result;
    final DeviceTtsBenchmarkReport? report = controller.report;
    final bool voiceReady = report?.enablesLocalTts ?? false;
    final bool canRetry = !voiceReady;
    final double windowMaxWidth = constraintsForWindow(context);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset('assets/images/bg_sunshine_world.png', fit: BoxFit.cover),
          DecoratedBox(
            decoration: BoxDecoration(
              color: SunshineColors.deepBlue.withValues(alpha: 0.12),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 52,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: windowMaxWidth),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: SunshineColors.deepBlue.withValues(
                              alpha: 0.62,
                            ),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: SunshineColors.white.withValues(
                                alpha: 0.22,
                              ),
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 28,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (showingResult)
                                  _ResultArtwork(voiceReady: voiceReady)
                                else
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(22),
                                    child: Image.asset(
                                      _talkPreparationGif,
                                      height: (constraints.maxHeight * 0.46)
                                          .clamp(260.0, 420.0),
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                if (showingResult) ...<Widget>[
                                  const SizedBox(height: 16),
                                  Text(
                                    'Talk setup complete',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineLarge
                                        ?.copyWith(
                                          color: SunshineColors.white,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                ],
                                const SizedBox(height: 14),
                                Text(
                                  showingResult
                                      ? _resultMessage(voiceReady)
                                      : _publicProgressMessage(controller),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: SunshineColors.white.withValues(
                                          alpha: 0.92,
                                        ),
                                      ),
                                ),
                                if (!showingResult &&
                                    controller
                                        .showAssetDownloadProgress) ...<Widget>[
                                  const SizedBox(height: 16),
                                  _AssetDownloadProgress(
                                    progress: controller.assetDownloadProgress,
                                    label: controller.assetDownloadProgressText,
                                  ),
                                ],
                                if (!showingResult) ...<Widget>[
                                  const SizedBox(height: 18),
                                  TextButton(
                                    onPressed: () => _skipForNow(context),
                                    style: TextButton.styleFrom(
                                      foregroundColor: SunshineColors.white,
                                    ),
                                    child: const Text('Skip for now'),
                                  ),
                                ],
                                if (showingResult) ...<Widget>[
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: voiceReady
                                          ? controller.continueToApp
                                          : () => _skipForNow(context),
                                      child: Text(
                                        voiceReady ? 'Start Chat' : 'Not now',
                                      ),
                                    ),
                                  ),
                                  if (canRetry) ...<Widget>[
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton(
                                        onPressed: controller.retry,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: SunshineColors.white,
                                          side: const BorderSide(
                                            color: SunshineColors.white,
                                          ),
                                        ),
                                        child: const Text('Check again'),
                                      ),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  double constraintsForWindow(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    return width < 420 ? width : 440;
  }

  String _publicProgressMessage(AppPreparationController controller) {
    if (controller.countdownActive) {
      final double progress = controller.progress;
      if (progress < 0.74) {
        return 'Polishing your device for clear conversations.';
      }
      if (progress < 0.86) {
        return 'Warming the storyteller voice.';
      }
      return 'Determining whether Chat can run on this device.';
    }
    return switch (controller.phaseLabel) {
      'Checking downloaded voice assets' => 'Checking downloaded voice assets.',
      'Downloading voice assets' => _downloadMessage(controller.progress),
      'Checking device compatibility' =>
        'Checking whether this device is ready for Chat.',
      'Polishing your device' => 'Polishing your device.',
      'Preparing clear listening' => 'Preparing clear listening.',
      'Warming the storyteller voice' => 'Warming the storyteller voice.',
      'Tuning the voice clone' => 'Tuning the voice clone.',
      'Saving voice files for next time' => 'Saving voice files for next time.',
      'Preparing storytellers for Chat' => 'Preparing storytellers for Chat.',
      'Saving storyteller thumbnails.' => 'Saving storyteller thumbnails.',
      'Saving storyteller portraits.' => 'Saving storyteller portraits.',
      'Saving storyteller voices.' => 'Saving storyteller voices.',
      'Almost ready for Talk' => 'Almost ready for Talk.',
      _ => 'Preparing voice assets for Talk.',
    };
  }

  String _downloadMessage(double progress) {
    if (progress < 0.18) {
      return 'Downloading voice assets.';
    }
    if (progress < 0.34) {
      return 'Saving a clear storyteller voice on this device.';
    }
    if (progress < 0.50) {
      return 'Preparing voices for smooth playback.';
    }
    return 'Almost done with the voice download.';
  }

  String _resultMessage(bool voiceReady) {
    if (voiceReady) {
      return 'Chat can be enabled on this device.';
    }
    return 'Chat cannot be enabled on this device.';
  }

  Future<void> _skipForNow(BuildContext context) async {
    await controller.skipForNow();
    if (context.mounted) {
      Navigator.of(context).maybePop();
    }
  }
}

class _AssetDownloadProgress extends StatelessWidget {
  const _AssetDownloadProgress({required this.progress, required this.label});

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final double value = progress.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: value > 0 ? value : null,
            minHeight: 10,
            backgroundColor: SunshineColors.white.withValues(alpha: 0.24),
            color: SunshineColors.sunshineYellow,
          ),
        ),
        if (label.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: SunshineColors.white.withValues(alpha: 0.86),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );
  }
}

class _ResultArtwork extends StatelessWidget {
  const _ResultArtwork({required this.voiceReady});

  final bool voiceReady;

  @override
  Widget build(BuildContext context) {
    final Color badgeColor = voiceReady
        ? const Color(0xFF25B978)
        : const Color(0xFFE15A5A);
    return SizedBox(
      height: 168,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: SunshineColors.white.withValues(alpha: 0.16),
              border: Border.all(
                color: SunshineColors.white.withValues(alpha: 0.25),
              ),
            ),
          ),
          Image.asset(_resultWizardAsset, height: 148, fit: BoxFit.contain),
          Positioned(
            right: 42,
            bottom: 12,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: badgeColor,
                border: Border.all(color: SunshineColors.white, width: 3),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(
                voiceReady ? Icons.check_rounded : Icons.close_rounded,
                color: SunshineColors.white,
                size: 28,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
