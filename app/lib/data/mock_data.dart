import '../models/content_item.dart';
import '../models/playlist.dart';
import '../models/scene.dart';

// ===== RHYME ITEMS =====
final List<ContentItem> rhymeItems = [
  const ContentItem(
    id: 'rhyme_jungle_friends',
    type: 'rhyme',
    language: 'english',
    title: 'Jungle Friends Song',
    category: 'animals',
    duration: '1:45',
    durationSeconds: 105,
    thumbnail: 'assets/images/thumb_jungle_friends.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
    isPopular: true,
  ),
  const ContentItem(
    id: 'rhyme_hop_bunny',
    type: 'rhyme',
    language: 'english',
    title: 'Hop Bunny Hop',
    category: 'animals',
    duration: '1:28',
    durationSeconds: 88,
    thumbnail: 'assets/images/thumb_hop_bunny.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
  ),
  const ContentItem(
    id: 'rhyme_butterfly_dance',
    type: 'rhyme',
    language: 'english',
    title: 'Butterfly Dance',
    category: 'animals',
    duration: '1:32',
    durationSeconds: 92,
    thumbnail: 'assets/images/thumb_butterfly_dance.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
    isNew: true,
  ),
  const ContentItem(
    id: 'rhyme_elephant_march',
    type: 'rhyme',
    language: 'english',
    title: 'Ellie Elephant March',
    category: 'animals',
    duration: '1:36',
    durationSeconds: 96,
    thumbnail: 'assets/images/thumb_elephant_march.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
  const ContentItem(
    id: 'rhyme_lion_roar',
    type: 'rhyme',
    language: 'english',
    title: 'Lion Roar Song',
    category: 'animals',
    duration: '1:30',
    durationSeconds: 90,
    thumbnail: 'assets/images/thumb_lion_roar.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
    isPopular: true,
  ),
];

// ===== STORY ITEMS =====
final List<ContentItem> storyItems = [
  const ContentItem(
    id: 'story_little_lion',
    type: 'story',
    language: 'english',
    title: 'The Little Lion Learns to Roar',
    category: 'animals',
    duration: '4:12',
    durationSeconds: 252,
    thumbnail: 'assets/images/thumb_little_lion_story.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
    isPopular: true,
  ),
  const ContentItem(
    id: 'story_kind_elephant',
    type: 'story',
    language: 'english',
    title: 'Ellie the Kind Elephant',
    category: 'morals',
    duration: '5:08',
    durationSeconds: 308,
    thumbnail: 'assets/images/thumb_kind_elephant.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
  const ContentItem(
    id: 'story_brave_bunny',
    type: 'story',
    language: 'english',
    title: 'The Brave Little Bunny',
    category: 'adventure',
    duration: '4:36',
    durationSeconds: 276,
    thumbnail: 'assets/images/thumb_brave_bunny.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
    isNew: true,
  ),
  const ContentItem(
    id: 'story_milo_monkey',
    type: 'story',
    language: 'english',
    title: 'Milo Monkey Shares',
    category: 'morals',
    duration: '3:58',
    durationSeconds: 238,
    thumbnail: 'assets/images/thumb_milo_monkey.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
  const ContentItem(
    id: 'story_butterfly_big_day',
    type: 'story',
    language: 'english',
    title: "The Butterfly's Big Day",
    category: 'nature',
    duration: '4:45',
    durationSeconds: 285,
    thumbnail: 'assets/images/thumb_butterfly_big_day.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
  ),
];

// ===== SPECIAL ITEMS FOR PLAYER / PLAYLISTS =====
const twinkleItem = ContentItem(
  id: 'rhyme_twinkle',
  type: 'rhyme',
  language: 'english',
  title: 'Twinkle Twinkle Little Star',
  category: 'bedtime',
  duration: '1:45',
  durationSeconds: 105,
  thumbnail: 'assets/images/scene_twinkle_1.png',
  audioSrc: 'assets/audio/placeholder.wav',
  downloaded: true,
);

const teapotItem = ContentItem(
  id: 'rhyme_teapot',
  type: 'rhyme',
  language: 'english',
  title: "I'm a Little Teapot",
  category: 'action',
  duration: '1:32',
  durationSeconds: 92,
  thumbnail: 'assets/images/thumb_teapot.png',
  audioSrc: 'assets/audio/placeholder.wav',
  downloaded: false,
  isNew: true,
);

const threePigsItem = ContentItem(
  id: 'story_three_pigs',
  type: 'story',
  language: 'english',
  title: 'The Three Little Pigs',
  category: 'morals',
  duration: '6:12',
  durationSeconds: 372,
  thumbnail: 'assets/images/thumb_three_pigs.png',
  audioSrc: 'assets/audio/placeholder.wav',
  downloaded: false,
  isNew: true,
);

// ===== PLAYLIST EDITOR ITEMS =====
final List<ContentItem> playlistEditorItems = [
  twinkleItem,
  const ContentItem(
    id: 'rhyme_sleepy_moon',
    type: 'rhyme',
    language: 'english',
    title: 'Sleepy Moon Song',
    category: 'lullaby',
    duration: '1:38',
    durationSeconds: 98,
    thumbnail: 'assets/images/scene_twinkle_2.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
  const ContentItem(
    id: 'rhyme_sleepy_bunny',
    type: 'rhyme',
    language: 'english',
    title: 'The Sleepy Bunny',
    category: 'lullaby',
    duration: '1:27',
    durationSeconds: 87,
    thumbnail: 'assets/images/thumb_hop_bunny.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: false,
  ),
  const ContentItem(
    id: 'story_starry_night',
    type: 'story',
    language: 'english',
    title: 'Starry Night Story',
    category: 'bedtime',
    duration: '6:12',
    durationSeconds: 372,
    thumbnail: 'assets/images/scene_twinkle_3.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
  const ContentItem(
    id: 'rhyme_soft_cloud',
    type: 'rhyme',
    language: 'english',
    title: 'Soft Cloud Lullaby',
    category: 'lullaby',
    duration: '1:52',
    durationSeconds: 112,
    thumbnail: 'assets/images/scene_twinkle_1.png',
    audioSrc: 'assets/audio/placeholder.wav',
    downloaded: true,
  ),
];

// ===== PLAYLISTS =====
List<Playlist> getInitialPlaylists() {
  return [
    Playlist.create(
      id: 'playlist_bedtime',
      title: 'Bedtime Mix',
      fallbackCoverImage: 'assets/images/playlist_bedtime_mix.png',
      items: [
        PlaylistItem.fromContent(twinkleItem),
        PlaylistItem.fromContent(teapotItem),
        PlaylistItem.fromContent(threePigsItem),
        PlaylistItem.fromContent(storyItems.first),
        PlaylistItem.fromContent(playlistEditorItems.last),
      ],
    ),
    Playlist.create(
      id: 'playlist_animal_fun',
      title: 'Animal Fun',
      fallbackCoverImage: 'assets/images/playlist_animal_fun.png',
      items: [
        PlaylistItem.fromContent(playlistEditorItems.first),
        PlaylistItem.fromContent(playlistEditorItems[1]),
        PlaylistItem.fromContent(playlistEditorItems[2]),
        PlaylistItem.fromContent(storyItems[1]),
        PlaylistItem.fromContent(storyItems[2]),
      ],
    ),
    Playlist.create(
      id: 'playlist_abc_time',
      title: 'ABC Time',
      fallbackCoverImage: 'assets/images/playlist_abc_time.png',
    ),
    Playlist.create(
      id: 'playlist_travel',
      title: 'Travel Tunes',
      fallbackCoverImage: 'assets/images/playlist_travel_tunes.png',
    ),
    Playlist.create(
      id: 'playlist_story_favorites',
      title: 'Story Favorites',
      fallbackCoverImage: 'assets/images/playlist_story_favorites.png',
    ),
  ];
}

// ===== PLAYER SCENES =====
final List<Scene> twinkleScenes = [
  const Scene(
    id: 'scene_1',
    number: 1,
    start: 0,
    end: 15,
    image: 'assets/images/scene_twinkle_1.png',
    label: 'Little Star',
  ),
  const Scene(
    id: 'scene_2',
    number: 2,
    start: 15,
    end: 35,
    image: 'assets/images/scene_twinkle_2.png',
    label: 'Night Sky',
  ),
  const Scene(
    id: 'scene_3',
    number: 3,
    start: 35,
    end: 55,
    image: 'assets/images/scene_twinkle_3.png',
    label: 'River Glow',
  ),
  const Scene(
    id: 'scene_4',
    number: 4,
    start: 55,
    end: 75,
    image: 'assets/images/scene_twinkle_4.png',
    label: 'Flower Hills',
  ),
  const Scene(
    id: 'scene_5',
    number: 5,
    start: 75,
    end: 105,
    image: 'assets/images/scene_twinkle_5.png',
    label: 'Good Night',
  ),
];

// ===== TRANSCRIPT WORDS =====
final List<TranscriptWord> twinkleTranscript = [
  const TranscriptWord(word: 'Twinkle', start: 16.0, end: 16.6, line: 1),
  const TranscriptWord(word: 'twinkle', start: 16.6, end: 17.2, line: 1),
  const TranscriptWord(word: 'little', start: 17.2, end: 17.8, line: 1),
  const TranscriptWord(word: 'star', start: 17.8, end: 18.6, line: 1),
  const TranscriptWord(word: 'How', start: 19.0, end: 19.5, line: 2),
  const TranscriptWord(word: 'I', start: 19.5, end: 19.8, line: 2),
  const TranscriptWord(word: 'wonder', start: 19.8, end: 20.5, line: 2),
  const TranscriptWord(word: 'what', start: 20.5, end: 21.0, line: 2),
  const TranscriptWord(word: 'you', start: 21.0, end: 21.3, line: 2),
  const TranscriptWord(word: 'are', start: 21.3, end: 22.0, line: 2),
];

/// Lookup helper
ContentItem? findItemById(String id) {
  final allItems = [...rhymeItems, ...storyItems, twinkleItem, teapotItem, threePigsItem, ...playlistEditorItems];
  try {
    return allItems.firstWhere((item) => item.id == id);
  } catch (_) {
    return null;
  }
}
