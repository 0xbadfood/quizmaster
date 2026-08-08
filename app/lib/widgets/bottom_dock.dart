import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

enum DockItem { home, rhymes, stories, quiz, playlists, parents }

/// Plank-style bottom navigation dock using the custom icon set.
class BottomDock extends StatelessWidget {
  final DockItem selectedItem;
  final ValueChanged<DockItem> onTap;
  final Set<DockItem>? visibleItems;

  const BottomDock({
    super.key,
    required this.selectedItem,
    required this.onTap,
    this.visibleItems,
  });

  static const List<_DockItem> _items = [
    _DockItem(
      id: DockItem.home,
      label: 'Home',
      assetPath: 'assets/images/dock/home_icon_512x512.png',
    ),
    _DockItem(
      id: DockItem.rhymes,
      label: 'Rhymes',
      assetPath: 'assets/images/dock/rhymes_icon_512x512.png',
    ),
    _DockItem(
      id: DockItem.stories,
      label: 'Stories',
      assetPath: 'assets/images/dock/stories_icon_512x512.png',
    ),
    _DockItem(
      id: DockItem.quiz,
      label: 'Quiz',
      assetPath: 'assets/images/dock/quiz_icon_512x512.png',
    ),
    _DockItem(
      id: DockItem.playlists,
      label: 'Playlists',
      assetPath: 'assets/images/dock/playlists_icon_512x512.png',
    ),
    _DockItem(
      id: DockItem.parents,
      label: 'Parents',
      assetPath: 'assets/images/dock/parents_icon_512x512.png',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final items = visibleItems == null
        ? _items
        : _items.where((item) => visibleItems!.contains(item.id)).toList();

    return SafeArea(
      top: false,
      minimum: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        height: 116,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Image.asset(
                  'assets/images/dock/bottom_plank_banner_1536x320.png',
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.bottomCenter,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: Row(
                children: List.generate(items.length, (index) {
                  final item = items[index];
                  final isSelected = item.id == selectedItem;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => onTap(item.id),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 180),
                        scale: isSelected ? 1.06 : 1.0,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              width: isSelected ? 54 : 50,
                              height: isSelected ? 54 : 50,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isSelected ? 0.28 : 0.18,
                                    ),
                                    blurRadius: isSelected ? 12 : 8,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Image.asset(
                                item.assetPath,
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontSize: 10.5,
                                height: 1,
                                fontWeight: isSelected
                                    ? FontWeight.w900
                                    : FontWeight.w800,
                                color: isSelected
                                    ? SunshineColors.white
                                    : SunshineColors.cream.withValues(
                                        alpha: 0.92,
                                      ),
                                shadows: const [
                                  Shadow(
                                    color: Color(0xAA4A2100),
                                    blurRadius: 4,
                                    offset: Offset(0, 1.5),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockItem {
  final DockItem id;
  final String label;
  final String assetPath;

  const _DockItem({
    required this.id,
    required this.label,
    required this.assetPath,
  });
}
