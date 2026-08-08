import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/content_item.dart';
import '../models/playlist.dart';
import '../providers/app_state.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/content_image.dart';

class HomeScreen extends StatelessWidget {
  final VoidCallback? onRhymes;
  final VoidCallback? onStories;
  final VoidCallback? onPlaylists;
  final VoidCallback? onOpenSettings;
  final ValueChanged<Playlist>? onOpenPlaylist;
  final ValueChanged<ContentItem?>? onPlayer;
  final VoidCallback? onContinueListening;

  const HomeScreen({
    super.key,
    this.onRhymes,
    this.onStories,
    this.onPlaylists,
    this.onOpenSettings,
    this.onOpenPlaylist,
    this.onPlayer,
    this.onContinueListening,
  });

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final continueItem = appState.lastPlayedItem;
    final continueAvailable = continueItem != null;
    final continueProgress = continueAvailable
        ? appState.lastPlayedProgress
        : 0.0;
    final continuePercent = (continueProgress * 100).round().clamp(0, 100);
    final playlistOnlyForKids =
        !appState.parentMode && appState.playlistOnlyForKids;
    final lastPlaylistContext = appState.lastPlayedPlaylistContext;
    final lastPlaylist = lastPlaylistContext == null
        ? null
        : appState.getPlaylistById(lastPlaylistContext.playlistId);
    final playlistProgressLabel = lastPlaylistContext == null
        ? null
        : '${lastPlaylistContext.itemIndex + 1}/${lastPlaylist?.itemCount ?? 0}';
    final continueSubtitle = lastPlaylist == null
        ? (continueItem == null
              ? 'Pick a rhyme or story to begin'
              : '${continueItem.type == 'story' ? 'Story' : 'Rhyme'} • ${continueItem.duration}')
        : 'Playlist • ${lastPlaylist.title} • $playlistProgressLabel';
    final featuredPlaylists = appState.playlists
        .take(3)
        .toList(growable: false);
    final childName = appState.customerProfile?.children.isNotEmpty == true
        ? appState.customerProfile!.children.first.nickname.trim()
        : '';
    final greeting = childName.isEmpty ? 'Hi, Little Star!' : 'Hi, $childName!';

    return BackgroundScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  // Greeting bubble
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: SunshineColors.cream.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('⭐', style: TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Text(
                          greeting,
                          style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: SunshineColors.purpleText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onOpenSettings,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: SunshineColors.white.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.settings,
                        color: SunshineColors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Hero section
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SizedBox(
                height: 290,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 0,
                      left: 118,
                      right: 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text.rich(
                              TextSpan(
                                style: GoogleFonts.nunito(
                                  fontSize: 36,
                                  fontWeight: FontWeight.w900,
                                  height: 0.95,
                                  shadows: [
                                    Shadow(
                                      color: SunshineColors.deepBlue.withValues(
                                        alpha: 0.30,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                children: const [
                                  TextSpan(
                                    text: 'Story',
                                    style: TextStyle(
                                      color: SunshineColors.white,
                                    ),
                                  ),
                                  TextSpan(
                                    text: 'Vault',
                                    style: TextStyle(
                                      color: SunshineColors.error,
                                    ),
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Listen, learn & imagine',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.nunito(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: SunshineColors.white.withValues(
                                alpha: 0.94,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: -12,
                      bottom: 4,
                      child: Image.asset(
                        'assets/images/mascot_toto.png',
                        width: 156,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 150,
                          height: 200,
                          decoration: BoxDecoration(
                            color: SunshineColors.skyBlueLight,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(
                            Icons.smart_toy,
                            size: 48,
                            color: SunshineColors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 0,
                      width: 228,
                      child: GestureDetector(
                        onTap: continueAvailable
                            ? (onContinueListening ??
                                  () => onPlayer?.call(continueItem))
                            : (playlistOnlyForKids ? onPlaylists : onStories),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                          decoration: sunshineCardDecoration().copyWith(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Continue Listening',
                                style: GoogleFonts.nunito(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: SunshineColors.purpleText,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: buildContentImage(
                                      continueItem == null
                                          ? 'assets/images/app_icon.png'
                                          : (continueItem.thumbnail.isNotEmpty
                                                ? continueItem.thumbnail
                                                : (continueItem.thumbnailUrl ??
                                                      '')),
                                      width: 64,
                                      height: 64,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) =>
                                              Container(
                                                width: 64,
                                                height: 64,
                                                color: SunshineColors.lavender
                                                    .withValues(alpha: 0.2),
                                              ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          continueItem?.displayTitle ??
                                              'Start Listening',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.nunito(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w900,
                                            color: SunshineColors.darkText,
                                            height: 1.05,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          continueSubtitle,
                                          style: GoogleFonts.nunito(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: SunshineColors.purpleText
                                                .withValues(alpha: 0.74),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: SunshineColors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: SunshineColors.deepBlue
                                              .withValues(alpha: 0.14),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: SunshineColors.lavender,
                                      size: 28,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  if (continueAvailable) ...[
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(99),
                                        child: LinearProgressIndicator(
                                          minHeight: 6,
                                          value: continueProgress,
                                          backgroundColor: const Color(
                                            0xFFEBDFF9,
                                          ),
                                          valueColor:
                                              const AlwaysStoppedAnimation(
                                                SunshineColors.lavender,
                                              ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '$continuePercent%',
                                      style: GoogleFonts.nunito(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        color: SunshineColors.purpleText
                                            .withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ] else
                                    Text(
                                      'Browse content',
                                      style: GoogleFonts.nunito(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        color: SunshineColors.purpleText
                                            .withValues(alpha: 0.8),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Rhymes & Stories shortcut cards
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _ShortcutCard(
                      title: 'Rhymes',
                      icon: Icons.music_note_rounded,
                      imageAsset: 'assets/images/category_icons/type_rhyme.png',
                      gradient: SunshineColors.pinkGradient,
                      onTap: playlistOnlyForKids ? onPlaylists : onRhymes,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ShortcutCard(
                      title: 'Stories',
                      icon: Icons.auto_stories_rounded,
                      imageAsset: 'assets/images/category_icons/type_story.png',
                      gradient: SunshineColors.blueGradient,
                      onTap: playlistOnlyForKids ? onPlaylists : onStories,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Featured Playlists
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    'Featured Playlists',
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.white,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onPlaylists,
                    child: Text(
                      'See All',
                      style: GoogleFonts.nunito(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: SunshineColors.sunshineYellow,
                        decoration: TextDecoration.underline,
                        decorationColor: SunshineColors.sunshineYellow,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 140,
              child: featuredPlaylists.isEmpty
                  ? Center(
                      child: Text(
                        'No playlists yet',
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: featuredPlaylists.length,
                      itemBuilder: (context, index) {
                        final playlist = featuredPlaylists[index];
                        return _PlaylistMini(
                          title: playlist.title,
                          subtitle: '${playlist.itemCount} items',
                          image: playlist.coverImage,
                          onTap: () => onOpenPlaylist?.call(playlist),
                        );
                      },
                    ),
            ),

            if (!playlistOnlyForKids) ...[
              const SizedBox(height: 24),

              // New & Featured
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'New & Featured',
                  style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 128,
                child: appState.recentlyAddedLoading
                    ? ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: 3,
                        itemBuilder: (context, index) =>
                            const _RecentLoadingCard(),
                      )
                    : appState.recentlyAddedItems.isEmpty
                    ? Center(
                        child: Text(
                          'No featured items yet',
                          style: GoogleFonts.nunito(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: SunshineColors.white.withValues(alpha: 0.75),
                          ),
                        ),
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: appState.recentlyAddedItems.length,
                        itemBuilder: (context, index) {
                          final item = appState.recentlyAddedItems[index];
                          return _RecentCard(
                            item: item,
                            onTap: () => onPlayer?.call(item),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShortcutCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? imageAsset;
  final LinearGradient gradient;
  final VoidCallback? onTap;

  const _ShortcutCard({
    required this.title,
    required this.icon,
    this.imageAsset,
    required this.gradient,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: gradient.colors.last.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: -8,
              bottom: -8,
              child: imageAsset != null
                  ? Opacity(
                      opacity: 0.18,
                      child: Image.asset(
                        imageAsset!,
                        width: 86,
                        height: 86,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Icon(
                          icon,
                          size: 72,
                          color: SunshineColors.white.withValues(alpha: 0.15),
                        ),
                      ),
                    )
                  : Icon(
                      icon,
                      size: 72,
                      color: SunshineColors.white.withValues(alpha: 0.15),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  imageAsset != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            imageAsset!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Icon(
                              icon,
                              color: SunshineColors.white,
                              size: 28,
                            ),
                          ),
                        )
                      : Icon(icon, color: SunshineColors.white, size: 28),
                  const Spacer(),
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistMini extends StatelessWidget {
  final String title;
  final String subtitle;
  final String image;
  final VoidCallback? onTap;

  const _PlaylistMini({
    required this.title,
    required this.subtitle,
    required this.image,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 12),
        decoration: sunshineCardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              child: buildContentImage(
                image,
                width: 120,
                height: 80,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 120,
                  height: 80,
                  color: SunshineColors.lavender.withValues(alpha: 0.2),
                  child: const Icon(Icons.playlist_play),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.darkText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.nunito(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: SunshineColors.darkText.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final ContentItem item;
  final VoidCallback? onTap;

  const _RecentCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 172,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(10),
        decoration: sunshineCardDecoration(),
        child: Stack(
          children: [
            Positioned(
              right: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: SunshineColors.sunshineYellow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'NEW',
                  style: GoogleFonts.nunito(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.darkText,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: buildContentImage(
                    item.thumbnail.isNotEmpty
                        ? item.thumbnail
                        : (item.thumbnailUrl ?? ''),
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 72,
                      height: 72,
                      color: SunshineColors.lavender.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.displayTitle,
                          style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.darkText,
                            height: 1.05,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${item.type == 'rhyme' ? 'Rhyme' : 'Story'} • ${item.duration}',
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: SunshineColors.darkText.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentLoadingCard extends StatelessWidget {
  const _RecentLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(10),
      decoration: sunshineCardDecoration(),
      child: Row(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: SunshineColors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: SunshineColors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: 84,
                  height: 10,
                  decoration: BoxDecoration(
                    color: SunshineColors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  width: 58,
                  height: 22,
                  decoration: BoxDecoration(
                    color: SunshineColors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
