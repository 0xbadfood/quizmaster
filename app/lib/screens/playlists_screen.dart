import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../models/playlist.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/playlist_card.dart';

class PlaylistsScreen extends StatelessWidget {
  final ValueChanged<Playlist>? onOpenPlaylist;
  final VoidCallback? onManagePlaylists;
  final VoidCallback? onOpenSettings;
  const PlaylistsScreen({super.key, this.onOpenPlaylist, this.onManagePlaylists, this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return BackgroundScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('🎶 Playlists', style: GoogleFonts.nunito(fontSize: 24, fontWeight: FontWeight.w900, color: SunshineColors.white)),
                Text('Your favorite mixes', style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600, color: SunshineColors.white.withValues(alpha: 0.8))),
              ]),
              const Spacer(),
              if (appState.parentMode)
                GestureDetector(
                  onTap: onManagePlaylists,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: SunshineColors.cream.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.edit, size: 16, color: SunshineColors.deepBlue),
                        const SizedBox(width: 6),
                        Text(
                          'Manage',
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.deepBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                GestureDetector(
                  onTap: onOpenSettings,
                  child: Container(width: 36, height: 36, decoration: BoxDecoration(color: SunshineColors.white.withValues(alpha: 0.3), shape: BoxShape.circle), child: const Icon(Icons.settings, color: SunshineColors.white, size: 18)),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: appState.playlists.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        appState.parentMode
                            ? 'No playlists yet. Browse rhymes or stories in Parent Mode and add items as you go.'
                            : 'No playlists yet. Ask a parent to create some favorites for you.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700, color: SunshineColors.white.withValues(alpha: 0.85)),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: appState.playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = appState.playlists[index];
                      return PlaylistCard(
                        playlist: playlist,
                        onPlayAll: () => onOpenPlaylist?.call(playlist),
                        onTap: () => onOpenPlaylist?.call(playlist),
                      );
                    },
                  ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SunshineColors.cream.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(children: [
              Icon(
                appState.parentMode ? Icons.admin_panel_settings : Icons.info_outline,
                size: 18,
                color: SunshineColors.lavender,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  appState.parentMode
                      ? 'Parent Mode is active. Add items while browsing, then manage order and removals here.'
                      : 'Ask a parent to edit playlists. You can play all your favorite mixes here!',
                  style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w600, color: SunshineColors.purpleText),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
