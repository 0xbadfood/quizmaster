import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/content_item.dart';
import '../providers/app_state.dart';
import '../utils/content_access.dart';
import 'add_to_playlist_sheet.dart';
import 'content_image.dart';

/// Content list card for rhymes/stories
class ContentCard extends StatelessWidget {
  final ContentItem item;
  final VoidCallback? onPlay;
  final bool isStory;

  const ContentCard({
    super.key,
    required this.item,
    this.onPlay,
    this.isStory = false,
  });

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final parentMode = appState.parentMode;
    final locked = isContentLockedForCurrentUser(appState, item);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: sunshineCardDecoration(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPlay,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: buildContentImage(
                    item.thumbnail.isNotEmpty
                        ? item.thumbnail
                        : (item.thumbnailUrl ?? ''),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: SunshineColors.lavender.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.music_note,
                        color: SunshineColors.lavender,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Title & metadata
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.darkText,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: item.type == 'rhyme'
                                  ? SunshineColors.pink.withValues(alpha: 0.15)
                                  : SunshineColors.deepBlue.withValues(
                                      alpha: 0.1,
                                    ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              item.type == 'rhyme' ? 'Rhyme' : 'Story',
                              style: GoogleFonts.nunito(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: item.type == 'rhyme'
                                    ? SunshineColors.pink
                                    : SunshineColors.deepBlue,
                              ),
                            ),
                          ),
                          if (item.isHeroFree) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: SunshineColors.mintGreen.withValues(
                                  alpha: 0.18,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'FREE',
                                style: GoogleFonts.nunito(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: SunshineColors.deepBlue,
                                ),
                              ),
                            ),
                          ],
                          if (locked) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: SunshineColors.deepBlue.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'LOCKED',
                                style: GoogleFonts.nunito(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: SunshineColors.deepBlue,
                                ),
                              ),
                            ),
                          ],
                          Text(
                            item.duration,
                            style: GoogleFonts.nunito(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: SunshineColors.darkText.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                          if (item.downloaded) ...[
                            const Icon(
                              Icons.check_circle,
                              size: 14,
                              color: SunshineColors.mintGreen,
                            ),
                          ],
                          if (item.isNew) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: SunshineColors.sunshineYellow,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'NEW',
                                style: GoogleFonts.nunito(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800,
                                  color: SunshineColors.darkText,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                Column(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: isStory
                            ? SunshineColors.blueGradient
                            : SunshineColors.pinkGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isStory
                                        ? SunshineColors.deepBlue
                                        : SunshineColors.pink)
                                    .withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        locked
                            ? Icons.lock_rounded
                            : isStory
                            ? Icons.auto_stories
                            : Icons.play_arrow_rounded,
                        color: SunshineColors.white,
                        size: 22,
                      ),
                    ),
                    if (parentMode) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => showAddToPlaylistSheet(context, item),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: SunshineColors.cream,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: SunshineColors.deepBlue.withValues(
                                alpha: 0.12,
                              ),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.playlist_add,
                                size: 14,
                                color: SunshineColors.deepBlue,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Playlist',
                                style: GoogleFonts.nunito(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: SunshineColors.deepBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
