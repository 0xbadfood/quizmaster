/// Represents a rhyme or story content item
class ContentItem {
  static final RegExp _storyTitlePrefix = RegExp(r'^\s*\d+(?:\.\d+)*\.\s*');

  final String id;
  final String type; // 'rhyme' or 'story'
  final String language; // 'english' or 'hindi'
  final String title;
  final String category;
  final String duration;
  final int durationSeconds;
  final int serverContentId;
  final int serverCategoryId;
  final String thumbnail;
  final String? thumbnailUrl;
  final String audioSrc;
  final String? bundleAssetPath;
  final String? bundleFilePath;
  final String? bundleUrl;
  final int bundleVersion;
  final String? bundleSha256;
  final bool downloaded;
  final bool updateAvailable;
  final bool downloadInProgress;
  final bool isNew;
  final bool isPopular;
  final String ageGroup;
  final String recommendedAgeRange;
  final String ageFilterTag;
  final List<String> ageFilterTags;
  final bool unsuitableForChildren;
  final List<String> contentWarnings;
  final bool isHeroFree;
  final String entitlementRequired;
  final bool locked;

  const ContentItem({
    required this.id,
    required this.type,
    this.language = 'english',
    required this.title,
    required this.category,
    required this.duration,
    required this.durationSeconds,
    this.serverContentId = 0,
    this.serverCategoryId = 0,
    required this.thumbnail,
    this.thumbnailUrl,
    required this.audioSrc,
    this.bundleAssetPath,
    this.bundleFilePath,
    this.bundleUrl,
    this.bundleVersion = 0,
    this.bundleSha256,
    this.downloaded = false,
    this.updateAvailable = false,
    this.downloadInProgress = false,
    this.isNew = false,
    this.isPopular = false,
    this.ageGroup = '',
    this.recommendedAgeRange = '',
    this.ageFilterTag = '',
    this.ageFilterTags = const [],
    this.unsuitableForChildren = false,
    this.contentWarnings = const [],
    this.isHeroFree = false,
    this.entitlementRequired = '',
    this.locked = false,
  });

  factory ContentItem.fromJson(Map<String, dynamic> json) {
    List<String> stringList(dynamic value) {
      if (value is List) {
        return value
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
      }
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? const <String>[] : [text];
    }

    return ContentItem(
      id: (json['id'] ?? '').toString(),
      type: (json['type'] ?? 'rhyme').toString(),
      language: (json['language'] ?? 'english').toString(),
      title: (json['title'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      duration: (json['duration'] ?? '0:00').toString(),
      durationSeconds:
          ((json['durationSeconds'] ?? json['duration_seconds'] ?? 0) as num)
              .round(),
      serverContentId:
          ((json['serverContentId'] ?? json['content_id'] ?? 0) as num).round(),
      serverCategoryId:
          ((json['serverCategoryId'] ?? json['category_id'] ?? 0) as num)
              .round(),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      thumbnailUrl:
          json['thumbnailUrl']?.toString() ?? json['thumbnail_url']?.toString(),
      audioSrc: (json['audioSrc'] ?? json['audio_src'] ?? '').toString(),
      bundleAssetPath:
          json['bundleAssetPath']?.toString() ??
          json['bundle_asset_path']?.toString(),
      bundleFilePath:
          json['bundleFilePath']?.toString() ??
          json['bundle_file_path']?.toString(),
      bundleUrl:
          json['bundleUrl']?.toString() ?? json['bundle_url']?.toString(),
      bundleVersion:
          ((json['bundleVersion'] ?? json['bundle_version'] ?? 0) as num)
              .round(),
      bundleSha256:
          json['bundleSha256']?.toString() ?? json['bundle_sha256']?.toString(),
      downloaded: json['downloaded'] == true,
      updateAvailable:
          json['updateAvailable'] == true || json['update_available'] == true,
      downloadInProgress:
          json['downloadInProgress'] == true ||
          json['download_in_progress'] == true,
      isNew: json['isNew'] == true || json['is_new'] == true,
      isPopular: json['isPopular'] == true || json['is_popular'] == true,
      ageGroup: (json['ageGroup'] ?? json['age_group'] ?? '').toString(),
      recommendedAgeRange:
          (json['recommendedAgeRange'] ?? json['recommended_age_range'] ?? '')
              .toString(),
      ageFilterTag: (json['ageFilterTag'] ?? json['age_filter_tag'] ?? '')
          .toString(),
      ageFilterTags: stringList(
        json['ageFilterTags'] ?? json['age_filter_tags'],
      ),
      unsuitableForChildren:
          json['unsuitableForChildren'] == true ||
          json['unsuitable_for_children'] == true,
      contentWarnings: stringList(
        json['contentWarnings'] ?? json['content_warnings'],
      ),
      isHeroFree: json['isHeroFree'] == true || json['is_hero_free'] == true,
      entitlementRequired:
          (json['entitlementRequired'] ?? json['entitlement_required'] ?? '')
              .toString(),
      locked: json['locked'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'language': language,
      'title': title,
      'category': category,
      'duration': duration,
      'duration_seconds': durationSeconds,
      'content_id': serverContentId,
      'category_id': serverCategoryId,
      'thumbnail': thumbnail,
      'thumbnail_url': thumbnailUrl,
      'audio_src': audioSrc,
      'bundle_asset_path': bundleAssetPath,
      'bundle_file_path': bundleFilePath,
      'bundle_url': bundleUrl,
      'bundle_version': bundleVersion,
      'bundle_sha256': bundleSha256,
      'downloaded': downloaded,
      'update_available': updateAvailable,
      'download_in_progress': downloadInProgress,
      'is_new': isNew,
      'is_popular': isPopular,
      'age_group': ageGroup,
      'recommended_age_range': recommendedAgeRange,
      'age_filter_tag': ageFilterTag,
      'age_filter_tags': ageFilterTags,
      'unsuitable_for_children': unsuitableForChildren,
      'content_warnings': contentWarnings,
      'is_hero_free': isHeroFree,
      'entitlement_required': entitlementRequired,
      'locked': locked,
    };
  }

  ContentItem copyWith({
    String? id,
    String? type,
    String? language,
    String? title,
    String? category,
    String? duration,
    int? durationSeconds,
    int? serverContentId,
    int? serverCategoryId,
    String? thumbnail,
    String? thumbnailUrl,
    String? audioSrc,
    String? bundleAssetPath,
    String? bundleFilePath,
    String? bundleUrl,
    int? bundleVersion,
    String? bundleSha256,
    bool? downloaded,
    bool? updateAvailable,
    bool? downloadInProgress,
    bool? isNew,
    bool? isPopular,
    String? ageGroup,
    String? recommendedAgeRange,
    String? ageFilterTag,
    List<String>? ageFilterTags,
    bool? unsuitableForChildren,
    List<String>? contentWarnings,
    bool? isHeroFree,
    String? entitlementRequired,
    bool? locked,
  }) {
    return ContentItem(
      id: id ?? this.id,
      type: type ?? this.type,
      language: language ?? this.language,
      title: title ?? this.title,
      category: category ?? this.category,
      duration: duration ?? this.duration,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      serverContentId: serverContentId ?? this.serverContentId,
      serverCategoryId: serverCategoryId ?? this.serverCategoryId,
      thumbnail: thumbnail ?? this.thumbnail,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      audioSrc: audioSrc ?? this.audioSrc,
      bundleAssetPath: bundleAssetPath ?? this.bundleAssetPath,
      bundleFilePath: bundleFilePath ?? this.bundleFilePath,
      bundleUrl: bundleUrl ?? this.bundleUrl,
      bundleVersion: bundleVersion ?? this.bundleVersion,
      bundleSha256: bundleSha256 ?? this.bundleSha256,
      downloaded: downloaded ?? this.downloaded,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      downloadInProgress: downloadInProgress ?? this.downloadInProgress,
      isNew: isNew ?? this.isNew,
      isPopular: isPopular ?? this.isPopular,
      ageGroup: ageGroup ?? this.ageGroup,
      recommendedAgeRange: recommendedAgeRange ?? this.recommendedAgeRange,
      ageFilterTag: ageFilterTag ?? this.ageFilterTag,
      ageFilterTags: ageFilterTags ?? this.ageFilterTags,
      unsuitableForChildren:
          unsuitableForChildren ?? this.unsuitableForChildren,
      contentWarnings: contentWarnings ?? this.contentWarnings,
      isHeroFree: isHeroFree ?? this.isHeroFree,
      entitlementRequired: entitlementRequired ?? this.entitlementRequired,
      locked: locked ?? this.locked,
    );
  }

  String get displayTitle {
    final trimmed = title.trim();
    if (type != 'story') {
      return trimmed;
    }
    final stripped = trimmed.replaceFirst(_storyTitlePrefix, '').trim();
    return stripped.isEmpty ? trimmed : stripped;
  }
}
