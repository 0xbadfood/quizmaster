import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/content_item.dart';
import '../models/playlist.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

Future<void> showAddToPlaylistSheet(
  BuildContext context,
  ContentItem item,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _AddToPlaylistSheet(item: item);
    },
  );
}

class _AddToPlaylistSheet extends StatelessWidget {
  final ContentItem item;

  const _AddToPlaylistSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final playlists = appState.editablePlaylists;
    final memberships = appState
        .editablePlaylistsContainingItem(item)
        .map((playlist) => playlist.id)
        .toSet();

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        decoration: BoxDecoration(
          color: SunshineColors.cream,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: SunshineColors.dimPurple.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Add to Playlist',
              style: GoogleFonts.nunito(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: SunshineColors.deepBlue,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: SunshineColors.purpleText,
              ),
            ),
            const SizedBox(height: 14),
            if (playlists.isEmpty)
              _EmptyPlaylistState(item: item)
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: playlists.length + 1,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index == playlists.length) {
                      return _CreatePlaylistTile(item: item);
                    }
                    final playlist = playlists[index];
                    final alreadyAdded = memberships.contains(playlist.id);
                    final full = playlist.isFull;
                    final enabled = !alreadyAdded && !full;
                    return _PlaylistSelectionTile(
                      title: playlist.title,
                      subtitle: playlist.displayCount,
                      trailingLabel: alreadyAdded
                          ? 'Added'
                          : (full ? 'Full' : 'Add'),
                      enabled: enabled,
                      added: alreadyAdded,
                      onTap: enabled
                          ? () {
                              final added = context
                                  .read<AppState>()
                                  .addToPlaylist(playlist.id, item);
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    added
                                        ? 'Added to ${playlist.title}'
                                        : 'Could not add to ${playlist.title}',
                                  ),
                                ),
                              );
                            }
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPlaylistState extends StatelessWidget {
  final ContentItem item;

  const _EmptyPlaylistState({required this.item});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'No playlists yet. Create one and add this item right away.',
          style: GoogleFonts.nunito(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SunshineColors.darkText.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 12),
        _CreatePlaylistTile(item: item),
      ],
    );
  }
}

class _CreatePlaylistTile extends StatelessWidget {
  final ContentItem item;

  const _CreatePlaylistTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final canCreate = appState.canCreatePlaylist;
    return _PlaylistSelectionTile(
      title: 'Create New Playlist',
      subtitle: canCreate
          ? '${appState.remainingPlaylistSlots} slots left'
          : 'Maximum 20 playlists reached',
      trailingLabel: canCreate ? 'Create' : 'Limit reached',
      enabled: canCreate,
      added: false,
      onTap: canCreate
          ? () async {
              final created = await _showCreatePlaylistDialog(context, item);
              if (!context.mounted) {
                return;
              }
              if (created != null) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Created ${created.title} and added item'),
                  ),
                );
              }
            }
          : null,
    );
  }
}

class _PlaylistSelectionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String trailingLabel;
  final bool enabled;
  final bool added;
  final VoidCallback? onTap;

  const _PlaylistSelectionTile({
    required this.title,
    required this.subtitle,
    required this.trailingLabel,
    required this.enabled,
    required this.added,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = added
        ? SunshineColors.mintGreen
        : (enabled ? SunshineColors.deepBlue : SunshineColors.dimPurple);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  added ? Icons.check_circle : Icons.playlist_add,
                  color: accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.nunito(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: SunshineColors.darkText,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: SunshineColors.darkText.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                trailingLabel,
                style: GoogleFonts.nunito(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<Playlist?> _showCreatePlaylistDialog(
  BuildContext context,
  ContentItem item,
) async {
  final controller = TextEditingController();
  return showDialog<Playlist>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'Create Playlist',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final playlist = context.read<AppState>().createPlaylist(
                controller.text,
                initialItem: item,
              );
              Navigator.of(dialogContext).pop(playlist);
            },
            child: const Text('Create'),
          ),
        ],
      );
    },
  );
}
