import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/scene.dart';
import 'content_image.dart';

/// Scene thumbnail for the player's scene strip
class SceneThumbnail extends StatelessWidget {
  final Scene scene;
  final bool isCurrent;
  final VoidCallback? onTap;

  const SceneThumbnail({
    super.key,
    required this.scene,
    this.isCurrent = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(right: 8),
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent ? SunshineColors.pink : Colors.transparent,
                  width: isCurrent ? 3 : 0,
                ),
                boxShadow: isCurrent
                    ? [
                        BoxShadow(
                          color: SunshineColors.pink.withValues(alpha: 0.3),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(isCurrent ? 11 : 14),
                    child: buildContentImage(
                      scene.image,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: SunshineColors.lavender.withValues(alpha: 0.3),
                        child: const Icon(Icons.image, size: 20),
                      ),
                    ),
                  ),
                  // Number badge
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? SunshineColors.pink
                            : SunshineColors.darkText.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${scene.number}',
                          style: GoogleFonts.nunito(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              scene.label,
              style: GoogleFonts.nunito(
                fontSize: 9,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                color: isCurrent
                    ? SunshineColors.darkText
                    : SunshineColors.darkText.withValues(alpha: 0.5),
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
