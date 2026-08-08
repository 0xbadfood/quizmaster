import 'content_item.dart';

const int kMaxPlaylists = 20;
const int kMaxItemsPerPlaylist = 50;
const String kDefaultEmptyPlaylistCover =
    'assets/images/dock/playlists_icon_512x512.png';

String playlistItemIdentity(ContentItem item) {
  final serverId = item.serverContentId > 0
      ? item.serverContentId.toString()
      : item.id;
  return '${item.type}:${item.language}:$serverId';
}

class PlaylistPlaybackContext {
  final String playlistId;
  final int itemIndex;
  final bool shuffle;

  const PlaylistPlaybackContext({
    required this.playlistId,
    required this.itemIndex,
    this.shuffle = false,
  });

  factory PlaylistPlaybackContext.fromJson(Map<String, dynamic> json) {
    return PlaylistPlaybackContext(
      playlistId: (json['playlist_id'] ?? json['playlistId'] ?? '').toString(),
      itemIndex: ((json['item_index'] ?? json['itemIndex'] ?? 0) as num)
          .toInt(),
      shuffle: json['shuffle'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'playlist_id': playlistId,
      'item_index': itemIndex,
      'shuffle': shuffle,
    };
  }

  PlaylistPlaybackContext copyWith({
    String? playlistId,
    int? itemIndex,
    bool? shuffle,
  }) {
    return PlaylistPlaybackContext(
      playlistId: playlistId ?? this.playlistId,
      itemIndex: itemIndex ?? this.itemIndex,
      shuffle: shuffle ?? this.shuffle,
    );
  }
}

class PlaylistItem {
  final ContentItem content;
  final int addedAtMillis;

  const PlaylistItem({required this.content, required this.addedAtMillis});

  String get identity => playlistItemIdentity(content);

  factory PlaylistItem.fromContent(ContentItem content) {
    return PlaylistItem(
      content: content,
      addedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    return PlaylistItem(
      content: ContentItem.fromJson(
        (json['content'] as Map<dynamic, dynamic>? ?? const {})
            .cast<String, dynamic>(),
      ),
      addedAtMillis:
          ((json['added_at_millis'] ?? json['addedAtMillis'] ?? 0) as num)
              .toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'content': content.toJson(), 'added_at_millis': addedAtMillis};
  }

  PlaylistItem copyWith({ContentItem? content, int? addedAtMillis}) {
    return PlaylistItem(
      content: content ?? this.content,
      addedAtMillis: addedAtMillis ?? this.addedAtMillis,
    );
  }
}

class Playlist {
  final String id;
  final String title;
  final List<PlaylistItem> items;
  final int maxItems;
  final int createdAtMillis;
  final int updatedAtMillis;
  final String? fallbackCoverImage;
  final bool readOnly;

  const Playlist({
    required this.id,
    required this.title,
    required this.items,
    this.maxItems = kMaxItemsPerPlaylist,
    required this.createdAtMillis,
    required this.updatedAtMillis,
    this.fallbackCoverImage,
    this.readOnly = false,
  });

  factory Playlist.create({
    required String id,
    required String title,
    List<PlaylistItem> items = const [],
    String? fallbackCoverImage,
    bool readOnly = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Playlist(
      id: id,
      title: title,
      items: List<PlaylistItem>.from(items),
      createdAtMillis: now,
      updatedAtMillis: now,
      fallbackCoverImage: fallbackCoverImage,
      readOnly: readOnly,
    );
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final itemsJson = (json['items'] as List<dynamic>? ?? const []);
    return Playlist(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      items: itemsJson
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => PlaylistItem.fromJson(item.cast<String, dynamic>()))
          .toList(),
      maxItems:
          ((json['max_items'] ?? json['maxItems'] ?? kMaxItemsPerPlaylist)
                  as num)
              .toInt(),
      createdAtMillis:
          ((json['created_at_millis'] ?? json['createdAtMillis'] ?? 0) as num)
              .toInt(),
      updatedAtMillis:
          ((json['updated_at_millis'] ?? json['updatedAtMillis'] ?? 0) as num)
              .toInt(),
      fallbackCoverImage:
          json['fallback_cover_image']?.toString() ??
          json['fallbackCoverImage']?.toString(),
      readOnly: json['read_only'] == true || json['readOnly'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'items': items.map((item) => item.toJson()).toList(growable: false),
      'max_items': maxItems,
      'created_at_millis': createdAtMillis,
      'updated_at_millis': updatedAtMillis,
      'fallback_cover_image': fallbackCoverImage,
      'read_only': readOnly,
    };
  }

  Playlist copyWith({
    String? id,
    String? title,
    List<PlaylistItem>? items,
    int? maxItems,
    int? createdAtMillis,
    int? updatedAtMillis,
    String? fallbackCoverImage,
    bool? readOnly,
  }) {
    return Playlist(
      id: id ?? this.id,
      title: title ?? this.title,
      items: items ?? List<PlaylistItem>.from(this.items),
      maxItems: maxItems ?? this.maxItems,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      fallbackCoverImage: fallbackCoverImage ?? this.fallbackCoverImage,
      readOnly: readOnly ?? this.readOnly,
    );
  }

  int get itemCount => items.length;

  bool get isFull => itemCount >= maxItems;

  PlaylistItem? get firstItem => items.isNotEmpty ? items.first : null;

  String get coverImage {
    final fallback = (fallbackCoverImage ?? '').trim();
    if (readOnly && fallback.isNotEmpty) {
      return fallback;
    }
    final first = firstItem?.content;
    final thumbnail = (first?.thumbnail ?? '').trim();
    if (thumbnail.isNotEmpty) {
      return thumbnail;
    }
    final thumbnailUrl = (first?.thumbnailUrl ?? '').trim();
    if (thumbnailUrl.isNotEmpty) {
      return thumbnailUrl;
    }
    return fallback.isNotEmpty ? fallback : kDefaultEmptyPlaylistCover;
  }

  int get totalDurationSeconds {
    return items.fold<int>(
      0,
      (sum, item) => sum + item.content.durationSeconds,
    );
  }

  String get displayCount => '$itemCount / $maxItems';

  String get totalDurationLabel {
    final totalSeconds = totalDurationSeconds;
    if (totalSeconds <= 0) {
      return '0 min';
    }
    final totalMinutes = (totalSeconds / 60).ceil();
    return '$totalMinutes min';
  }

  bool containsContent(ContentItem item) {
    final identity = playlistItemIdentity(item);
    return items.any((entry) => entry.identity == identity);
  }
}
