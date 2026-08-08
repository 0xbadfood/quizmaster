import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Full-screen fantasy landscape background wrapper
class BackgroundScaffold extends StatelessWidget {
  final Widget child;
  final bool showDock;

  const BackgroundScaffold({
    super.key,
    required this.child,
    this.showDock = true,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Image.asset(
            'assets/images/bg_sunshine_world.png',
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => const DecoratedBox(
              decoration: BoxDecoration(
                gradient: SunshineColors.skyGradient,
              ),
            ),
          ),
        ),
        // Keep a light tint only so the guided artwork remains visible.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  SunshineColors.deepBlue.withValues(alpha: 0.10),
                  SunshineColors.skyBlueLight.withValues(alpha: 0.06),
                  SunshineColors.deepBlue.withValues(alpha: 0.16),
                ],
              ),
            ),
          ),
        ),
        SafeArea(child: child),
      ],
    );
  }
}
