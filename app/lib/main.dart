import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'data/category_registry.dart';
import 'theme/app_theme.dart';
import 'providers/app_state.dart';
import 'models/content_item.dart';
import 'models/playlist.dart';
import 'widgets/bottom_dock.dart';
import 'screens/home_screen.dart';
import 'screens/rhymes_screen.dart';
import 'screens/stories_screen.dart';
import 'screens/playlists_screen.dart';
import 'screens/parent_pin_screen.dart';
import 'screens/playlist_editor_screen.dart';
import 'screens/player_screen.dart';
import 'screens/register_toy_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/startup_intro_screen.dart';
import 'screens/subscription_paywall_screen.dart';
import 'screens/quiz_library_screen.dart';
import 'startup/app_preparation.dart';
import 'utils/content_access.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CategoryRegistry.initialize();
  final AppPreparationController preparation = AppPreparationController();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
        ChangeNotifierProvider<AppPreparationController>.value(
          value: preparation,
        ),
      ],
      child: SunshineApp(preparation: preparation),
    ),
  );
}

class SunshineApp extends StatelessWidget {
  const SunshineApp({required this.preparation, super.key});

  final AppPreparationController preparation;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quizmaster',
      debugShowCheckedModeBanner: false,
      theme: SunshineTheme.theme,
      home: const StartupIntroGate(child: AppRoot()),
    );
  }
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (appState.contentEnvironmentLoading) {
      return const _StartupLoadingScreen();
    }
    return const AppShell();
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: SunshineColors.skyGradient),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: sunshineCardDecoration().copyWith(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Opening Quizmaster...',
                  style: SunshineTheme.theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.purpleText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Main app shell with bottom dock navigation
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  DockItem _currentDockItem = DockItem.home;

  Set<DockItem> get _visibleDockItems => <DockItem>{
    DockItem.home,
    DockItem.rhymes,
    DockItem.stories,
    DockItem.quiz,
    DockItem.playlists,
    DockItem.parents,
  };

  int get _currentStackIndex {
    return switch (_currentDockItem) {
      DockItem.home => 0,
      DockItem.rhymes => 1,
      DockItem.stories => 2,
      DockItem.quiz => 3,
      DockItem.playlists => 4,
      DockItem.parents => 5,
    };
  }

  void _onNavTap(DockItem item) {
    final appState = context.read<AppState>();
    if (!appState.parentMode &&
        appState.playlistOnlyForKids &&
        (item == DockItem.rhymes || item == DockItem.stories)) {
      setState(() => _currentDockItem = DockItem.playlists);
      return;
    }
    setState(() => _currentDockItem = item);
  }

  void _openPlayer([
    ContentItem? item,
    PlaylistPlaybackContext? playlistContext,
    bool autoplay = false,
  ]) {
    final appState = context.read<AppState>();
    final selectedItem = item ?? appState.lastPlayedItem;
    if (selectedItem == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No content selected yet.')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: selectedItem,
          playlistContext: playlistContext,
          autoplay: autoplay,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  bool _isLocked(ContentItem item) {
    return isContentLockedForCurrentUser(context.read<AppState>(), item);
  }

  void _openPaywall(ContentItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SubscriptionPaywallScreen(lockedItem: item),
      ),
    );
  }

  void _openContentItem(ContentItem? item) {
    final nextItem = item;
    if (nextItem == null) {
      return;
    }
    if (_isLocked(nextItem)) {
      _openPaywall(nextItem);
      return;
    }
    _openPlayer(nextItem, null, true);
  }

  void _openCategoryQueueItem(ContentItem item, List<ContentItem> queue) {
    if (_isLocked(item)) {
      _openPaywall(item);
      return;
    }
    final appState = context.read<AppState>();
    final playableQueue = queue
        .where((candidate) => !_isLocked(candidate))
        .toList(growable: false);
    final startIndex = playableQueue.indexWhere(
      (candidate) =>
          playlistItemIdentity(candidate) == playlistItemIdentity(item),
    );
    if (startIndex < 0) {
      _openPlayer(item, null, true);
      return;
    }
    final queueTitle = item.category.trim().isEmpty
        ? (item.type == 'story' ? 'Stories' : 'Rhymes')
        : item.category.trim();
    final playbackContext = appState.createPlaybackQueue(
      title: queueTitle,
      items: playableQueue,
      startIndex: startIndex,
    );
    _openPlayer(playableQueue[startIndex], playbackContext, true);
  }

  Future<void> _openPlaylist(
    Playlist playlist, {
    int startIndex = 0,
    bool autoplay = true,
  }) async {
    await _openPlaylistContext(
      PlaylistPlaybackContext(playlistId: playlist.id, itemIndex: startIndex),
      fallbackItem: _playlistItemAt(playlist, startIndex)?.content,
      autoplay: autoplay,
    );
  }

  PlaylistItem? _playlistItemAt(Playlist playlist, int index) {
    if (index < 0 || index >= playlist.items.length) {
      return null;
    }
    return playlist.items[index];
  }

  Future<void> _openPlaylistContext(
    PlaylistPlaybackContext playlistContext, {
    ContentItem? fallbackItem,
    bool autoplay = false,
  }) async {
    final appState = context.read<AppState>();
    final firstItem =
        appState
            .playlistItemAt(
              playlistContext.playlistId,
              playlistContext.itemIndex,
            )
            ?.content ??
        fallbackItem;
    if (firstItem == null) {
      return;
    }
    if (_isLocked(firstItem)) {
      _openPaywall(firstItem);
      return;
    }
    _openPlayer(firstItem, playlistContext, autoplay);
  }

  Future<void> _continueListening() async {
    final appState = context.read<AppState>();
    final item = appState.lastPlayedItem;
    final playlistContext = appState.lastPlayedPlaylistContext;
    if (playlistContext != null) {
      await _openPlaylistContext(playlistContext, fallbackItem: item);
      return;
    }
    if (!appState.parentMode && appState.playlistOnlyForKids) {
      _onNavTap(DockItem.playlists);
      return;
    }
    _openPlayer(item);
  }

  void _openPlaylistEditor() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PlaylistEditorScreen(onBack: () => Navigator.of(context).pop()),
      ),
    );
  }

  void _openRegisterToy() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RegisterToyScreen(
          onRedeemed: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            setState(() => _currentDockItem = DockItem.home);
          },
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/bg_sunshine_world.png',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const DecoratedBox(
                decoration: BoxDecoration(gradient: SunshineColors.skyGradient),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    SunshineColors.deepBlue.withValues(alpha: 0.10),
                    SunshineColors.skyBlueLight.withValues(alpha: 0.06),
                    SunshineColors.deepBlue.withValues(alpha: 0.16),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 92),
            child: IndexedStack(
              index: _currentStackIndex,
              children: [
                HomeScreen(
                  onRhymes: () => _onNavTap(DockItem.rhymes),
                  onStories: () => _onNavTap(DockItem.stories),
                  onPlaylists: () => _onNavTap(DockItem.playlists),
                  onOpenSettings: _openSettings,
                  onOpenPlaylist: _openPlaylist,
                  onContinueListening: _continueListening,
                  onPlayer: _openContentItem,
                ),
                RhymesScreen(
                  onPlayItem: _openCategoryQueueItem,
                  onLockedItem: _openPaywall,
                  onOpenSettings: _openSettings,
                ),
                StoriesScreen(
                  onPlayItem: _openCategoryQueueItem,
                  onLockedItem: _openPaywall,
                  onOpenSettings: _openSettings,
                ),
                QuizLibraryScreen(
                  active: _currentDockItem == DockItem.quiz,
                  onOpenSettings: _openSettings,
                ),
                PlaylistsScreen(
                  onOpenPlaylist: _openPlaylist,
                  onManagePlaylists: _openPlaylistEditor,
                  onOpenSettings: _openSettings,
                ),
                ParentPinScreen(
                  onUnlocked: () {},
                  onManagePlaylists: _openPlaylistEditor,
                  onRegisterToy: () => _openRegisterToy(),
                  onBack: () => _onNavTap(DockItem.home),
                  onOpenSettings: _openSettings,
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: BottomDock(
              selectedItem: _currentDockItem,
              onTap: _onNavTap,
              visibleItems: _visibleDockItems,
            ),
          ),
        ],
      ),
    );
  }
}
