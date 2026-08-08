import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../models/category.dart';
import 'content_image.dart';

/// Round category icon selector
class CategoryIcon extends StatelessWidget {
  final Category category;
  final bool isSelected;
  final VoidCallback? onTap;

  const CategoryIcon({
    super.key,
    required this.category,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget fallbackIcon() => Icon(
      category.icon,
      size: 28,
      color: isSelected ? SunshineColors.warmOrange : SunshineColors.lavender,
    );

    Widget imageIcon(Widget child) => Padding(
      padding: const EdgeInsets.all(2),
      child: ClipOval(child: child),
    );

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? SunshineColors.pink.withValues(alpha: 0.18)
                    : SunshineColors.white,
                border: Border.all(
                  color: isSelected
                      ? SunshineColors.pink
                      : SunshineColors.white,
                  width: isSelected ? 3 : 1.5,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: SunshineColors.pink.withValues(alpha: 0.3),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: category.iconUrl != null && category.iconUrl!.isNotEmpty
                  ? imageIcon(
                      buildContentImage(
                        category.iconUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            fallbackIcon(),
                      ),
                    )
                  : category.assetPath != null
                  ? imageIcon(
                      buildContentImage(
                        category.assetPath!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            fallbackIcon(),
                      ),
                    )
                  : Icon(
                      category.icon,
                      size: 28,
                      color: isSelected
                          ? SunshineColors.warmOrange
                          : SunshineColors.lavender,
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              category.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.nunito(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected
                    ? SunshineColors.darkText
                    : SunshineColors.darkText.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
