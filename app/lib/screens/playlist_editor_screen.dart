import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/content_image.dart';

class PlaylistEditorScreen extends StatefulWidget {
  final VoidCallback? onBack;

  const PlaylistEditorScreen({super.key, this.onBack});

  @override
  State<PlaylistEditorScreen> createState() => _PlaylistEditorScreenState();
}

class _PlaylistEditorScreenState extends State<PlaylistEditorScreen> {
  String? _selectedPlaylistId;

  Playlist? _resolveSelectedPlaylist(AppState appState) {
    final explicit = _selectedPlaylistId == null
        ? null
        : appState.getPlaylistById(_selectedPlaylistId!);
    if (explicit != null) {
      return explicit;
    }
    if (appState.playlists.isEmpty) {
      return null;
    }
    final first = appState.playlists.first;
    _selectedPlaylistId = first.id;
    return first;
  }

  Future<void> _showRenameDialog(Playlist playlist) async {
    if (playlist.readOnly) {
      return;
    }
    final controller = TextEditingController(text: playlist.title);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'Rename Playlist',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              context.read<AppState>().renamePlaylist(
                playlist.id,
                controller.text,
              );
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final created = context.read<AppState>().createPlaylist(
                controller.text,
              );
              if (created != null) {
                setState(() => _selectedPlaylistId = created.id);
              }
              Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Playlist playlist) async {
    if (playlist.readOnly) {
      return;
    }
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'Delete Playlist?',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'Remove "${playlist.title}" and all of its saved ordering?',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: SunshineColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) {
      return;
    }
    context.read<AppState>().deletePlaylist(playlist.id);
    setState(() => _selectedPlaylistId = null);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final selectedPlaylist = _resolveSelectedPlaylist(appState);

    return BackgroundScaffold(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: widget.onBack,
                  child: const Icon(
                    Icons.arrow_back,
                    color: SunshineColors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: SunshineColors.purpleGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Parent Mode On',
                    style: GoogleFonts.nunito(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.white,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${appState.editablePlaylists.length} / $kMaxPlaylists playlists',
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: SunshineColors.white.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Manage Playlists',
                    style: GoogleFonts.nunito(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.white,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: appState.canCreatePlaylist ? _showCreateDialog : null,
                  child: Opacity(
                    opacity: appState.canCreatePlaylist ? 1 : 0.55,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: SunshineColors.cream.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.add,
                            size: 16,
                            color: SunshineColors.deepBlue,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'New',
                            style: GoogleFonts.nunito(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: SunshineColors.deepBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: appState.playlists.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final playlist = appState.playlists[index];
                final selected = playlist.id == selectedPlaylist?.id;
                return GestureDetector(
                  onTap: () =>
                      setState(() => _selectedPlaylistId = playlist.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 210,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: selected
                          ? SunshineColors.cream
                          : SunshineColors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: selected
                          ? Border.all(color: SunshineColors.pink, width: 2)
                          : null,
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: buildContentImage(
                            playlist.coverImage,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: SunshineColors.lavender.withValues(
                                      alpha: 0.18,
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.playlist_play,
                                    color: SunshineColors.lavender,
                                  ),
                                ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                playlist.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.nunito(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: SunshineColors.darkText,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                playlist.displayCount,
                                style: GoogleFonts.nunito(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: SunshineColors.purpleText,
                                ),
                              ),
                              Text(
                                playlist.totalDurationLabel,
                                style: GoogleFonts.nunito(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: SunshineColors.darkText.withValues(
                                    alpha: 0.55,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: selectedPlaylist == null
                ? Center(
                    child: Text(
                      'Create a playlist to start organizing favorites.',
                      style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: SunshineColors.white.withValues(alpha: 0.8),
                      ),
                    ),
                  )
                : _SelectedPlaylistPanel(
                    playlist: selectedPlaylist,
                    onRename: () => _showRenameDialog(selectedPlaylist),
                    onDelete: () => _confirmDelete(selectedPlaylist),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SelectedPlaylistPanel extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _SelectedPlaylistPanel({
    required this.playlist,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: sunshineCardDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: buildContentImage(
                  playlist.coverImage,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: SunshineColors.lavender.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.playlist_play,
                      color: SunshineColors.lavender,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.title,
                      style: GoogleFonts.nunito(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: SunshineColors.darkText,
                      ),
                    ),
                    Text(
                      '${playlist.displayCount} • ${playlist.totalDurationLabel}',
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: SunshineColors.purpleText,
                      ),
                    ),
                  ],
                ),
              ),
              if (playlist.readOnly)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: SunshineColors.lavender.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        size: 14,
                        color: SunshineColors.deepBlue,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'StoryVault',
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                _HeaderAction(
                  icon: Icons.edit,
                  label: 'Rename',
                  onTap: onRename,
                ),
                const SizedBox(width: 8),
                _HeaderAction(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onTap: onDelete,
                  isDanger: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: playlist.items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Text(
                        'This playlist is empty. Browse stories or rhymes in Parent Mode and use Add to Playlist there.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.darkText.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: playlist.items.length,
                    // ignore: deprecated_member_use
                    onReorder: (oldIndex, newIndex) {
                      if (playlist.readOnly) {
                        return;
                      }
                      context.read<AppState>().reorderPlaylistItem(
                        playlist.id,
                        oldIndex,
                        newIndex,
                      );
                    },
                    itemBuilder: (context, index) {
                      final item = playlist.items[index];
                      return Container(
                        key: ValueKey('${playlist.id}:${item.identity}'),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: SunshineColors.cream.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: SunshineColors.lavender.withValues(
                                  alpha: 0.15,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: GoogleFonts.nunito(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: SunshineColors.purpleText,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: buildContentImage(
                                item.content.thumbnail.isNotEmpty
                                    ? item.content.thumbnail
                                    : (item.content.thumbnailUrl ?? ''),
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      width: 44,
                                      height: 44,
                                      color: SunshineColors.lavender.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.content.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.nunito(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: SunshineColors.darkText,
                                    ),
                                  ),
                                  Text(
                                    '${item.content.type == 'story' ? 'Story' : 'Rhyme'} • ${item.content.language == 'hindi' ? 'Hindi' : 'English'} • ${item.content.duration}',
                                    style: GoogleFonts.nunito(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: SunshineColors.darkText.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!playlist.readOnly) ...[
                              GestureDetector(
                                onTap: () =>
                                    context.read<AppState>().removeFromPlaylist(
                                      playlist.id,
                                      item.identity,
                                    ),
                                child: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                  color: SunshineColors.error,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.drag_handle,
                                size: 20,
                                color: SunshineColors.dimPurple,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDanger;

  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDanger ? SunshineColors.error : SunshineColors.deepBlue;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
