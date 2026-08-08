import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../data/quiz_bundle_repository.dart';
import '../data/visual_quiz_progress_repository.dart';
import '../models/quiz_bundle.dart';
import '../models/visual_quiz_progress.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/content_image.dart';
import '../widgets/filter_chip_row.dart';
import 'subscription_paywall_screen.dart';
import 'visual_quiz_screen.dart';

class QuizLibraryScreen extends StatefulWidget {
  const QuizLibraryScreen({
    required this.active,
    this.onOpenSettings,
    this.progressStore,
    super.key,
  });

  final bool active;
  final VoidCallback? onOpenSettings;
  final VisualQuizProgressStore? progressStore;

  @override
  State<QuizLibraryScreen> createState() => _QuizLibraryScreenState();
}

class _QuizLibraryScreenState extends State<QuizLibraryScreen> {
  final QuizBundleRepository _repository = QuizBundleRepository.instance;
  late final VisualQuizProgressStore _progressStore;
  List<QuizCategorySummary> _categories = const [];
  QuizCategorySummary? _selectedCategory;
  DownloadedQuizCategory? _downloadedCategory;
  bool _loadingCatalog = true;
  bool _downloading = false;
  double _downloadProgress = 0;
  String? _error;
  Map<String, VisualQuizAttempt> _attemptsByQuizId = const {};
  String _selectedStatusFilter = 'All';
  String _selectedDifficultyFilter = 'All';

  @override
  void initState() {
    super.initState();
    _progressStore =
        widget.progressStore ?? SqliteVisualQuizProgressStore.instance;
    _loadCatalog();
  }

  @override
  void didUpdateWidget(covariant QuizLibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      unawaited(_selectInitialCategory());
    }
  }

  Future<void> _loadCatalog() async {
    if (mounted) {
      setState(() {
        _loadingCatalog = true;
        _error = null;
      });
    }
    try {
      final categories = await _repository.loadCategories();
      if (!mounted) {
        return;
      }
      setState(() {
        _categories = categories;
        _loadingCatalog = false;
      });
      if (widget.active) {
        await _selectInitialCategory();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingCatalog = false;
        _error = friendlyContentLoadMessage(error, 'quizzes');
      });
    }
  }

  Future<void> _selectInitialCategory() async {
    if (!mounted) {
      return;
    }
    final category = initialQuizCategoryForActivation(
      active: widget.active,
      selectedCategory: _selectedCategory,
      downloading: _downloading,
      categories: _categories,
    );
    if (category != null) {
      await _selectCategory(category);
    }
  }

  Future<void> _selectCategory(QuizCategorySummary category) async {
    if (_downloading) {
      return;
    }
    setState(() {
      _selectedCategory = category;
      _downloadedCategory = null;
      _attemptsByQuizId = const {};
      _selectedDifficultyFilter = 'All';
      _downloading = true;
      _downloadProgress = 0;
      _error = null;
    });
    try {
      final downloaded = await _repository.ensureDownloaded(
        category,
        onProgress: (progress) {
          if (mounted && _selectedCategory?.id == category.id) {
            setState(() => _downloadProgress = progress);
          }
        },
      );
      if (!mounted || _selectedCategory?.id != category.id) {
        return;
      }
      final attempts = await _progressStore.loadCategory(category.id);
      if (!mounted || _selectedCategory?.id != category.id) {
        return;
      }
      setState(() {
        _downloadedCategory = downloaded;
        _attemptsByQuizId = attempts;
        _downloading = false;
        _downloadProgress = 1;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _downloading = false;
        _error = friendlyDownloadMessage(error);
      });
    }
  }

  Future<void> _openQuiz(QuizSetSummary summary) async {
    final category = _downloadedCategory;
    if (category == null) {
      return;
    }
    if (_isQuizLocked(category, summary)) {
      _openQuizPaywall();
      return;
    }
    final attempt = _attemptsByQuizId[summary.quizId];
    if (attempt?.status == VisualQuizRunStatus.finished &&
        attempt!.hasFirstScore) {
      final retake = await _showFinishedQuizDialog(attempt);
      if (retake != true || !mounted) {
        return;
      }
      await _launchQuiz(category, summary, initialAttempt: null);
      return;
    }
    await _launchQuiz(category, summary, initialAttempt: attempt);
  }

  void _openQuizPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const SubscriptionPaywallScreen(),
      ),
    );
  }

  Future<void> _launchQuiz(
    DownloadedQuizCategory category,
    QuizSetSummary summary, {
    required VisualQuizAttempt? initialAttempt,
  }) async {
    try {
      final quiz = await _repository.loadQuiz(category, summary);
      final progressStyle = await _repository.loadProgressStyle(category);
      if (!mounted) {
        return;
      }
      final waitForExplanationAudio = context
          .read<AppState>()
          .waitForQuizExplanationAudio;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VisualQuizScreen(
            category: category,
            summary: summary,
            quiz: quiz,
            progressStyle: progressStyle,
            progressStore: _progressStore,
            initialAttempt: initialAttempt,
            waitForExplanationAudio: waitForExplanationAudio,
            onOpenSettings: widget.onOpenSettings,
          ),
        ),
      );
      await _refreshAttempts(category.definition.id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyContentLoadMessage(error, 'quiz'))),
      );
    }
  }

  Future<void> _refreshAttempts(String categoryId) async {
    try {
      final attempts = await _progressStore.loadCategory(categoryId);
      if (!mounted || _downloadedCategory?.definition.id != categoryId) {
        return;
      }
      setState(() => _attemptsByQuizId = attempts);
    } catch (error, stackTrace) {
      debugPrint('Could not refresh quiz progress: $error\n$stackTrace');
    }
  }

  Future<bool?> _showFinishedQuizDialog(VisualQuizAttempt attempt) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: const Color(0xFFFDF6D8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.emoji_events_rounded,
                  color: Color(0xFFE69B14),
                  size: 58,
                ),
                const SizedBox(height: 8),
                Text(
                  'Quiz Finished',
                  style: GoogleFonts.nunito(
                    color: const Color(0xFF17482D),
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'You scored ${attempt.firstCorrectCount} out of '
                  '${attempt.firstQuestionCount}.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    color: const Color(0xFF27663D),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2D8C4A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Retake Quiz'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Not Now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackgroundScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Quiz',
                    style: GoogleFonts.nunito(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.white,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: widget.onOpenSettings,
                  style: IconButton.styleFrom(
                    backgroundColor: SunshineColors.white.withValues(
                      alpha: 0.28,
                    ),
                    foregroundColor: SunshineColors.white,
                  ),
                  icon: const Icon(Icons.settings_rounded),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 112,
            child: _loadingCatalog
                ? const Center(
                    child: CircularProgressIndicator(
                      color: SunshineColors.white,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) {
                      final category = _categories[index];
                      return _QuizCategoryButton(
                        category: category,
                        imagePath:
                            category.cachedSelectorImagePath ??
                            _repository.resolveUrl(category.selectorUrl),
                        selected: category.id == _selectedCategory?.id,
                        onTap: () => _selectCategory(category),
                      );
                    },
                  ),
          ),
          if (_downloading) _buildDownloadProgress(),
          if (_error != null) _buildError(),
          if (_downloadedCategory != null) _buildFilters(),
          Expanded(child: _buildLibrary()),
        ],
      ),
    );
  }

  Widget _buildDownloadProgress() {
    final category = _selectedCategory;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Downloading ${category?.name ?? 'quiz'} '
            '${(_downloadProgress * 100).round()}%',
            style: GoogleFonts.nunito(
              color: SunshineColors.white,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: _downloadProgress > 0 ? _downloadProgress : null,
              backgroundColor: SunshineColors.white.withValues(alpha: 0.28),
              color: SunshineColors.sunshineYellow,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      child: Material(
        color: const Color(0xFF6A2929).withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                color: SunshineColors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.nunito(
                    color: SunshineColors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Retry',
                onPressed: _selectedCategory == null
                    ? _loadCatalog
                    : () => _selectCategory(_selectedCategory!),
                color: SunshineColors.white,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    final difficultyFilters = [
      'All',
      ..._downloadedCategory!.definition.difficulties.map(
        (difficulty) => difficulty.label,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilterChipRow(
            selectedFilter: _selectedStatusFilter,
            onFilterChanged: (filter) {
              setState(() => _selectedStatusFilter = filter);
            },
            filters: const ['All', 'New', 'In Progress', 'Finished'],
          ),
          const SizedBox(height: 6),
          FilterChipRow(
            selectedFilter: _selectedDifficultyFilter,
            onFilterChanged: (filter) {
              setState(() => _selectedDifficultyFilter = filter);
            },
            filters: difficultyFilters,
          ),
        ],
      ),
    );
  }

  Widget _buildLibrary() {
    final category = _downloadedCategory;
    if (category == null) {
      if (_categories.isEmpty && !_loadingCatalog && _error == null) {
        return Center(
          child: Text(
            'No quizzes available',
            style: GoogleFonts.nunito(
              color: SunshineColors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      }
      return const SizedBox.expand();
    }
    final quizzes = category.definition.quizzes
        .where((quiz) {
          final difficulty = category.definition.difficulties.firstWhere(
            (item) => item.id == quiz.difficulty,
          );
          final matchesDifficulty =
              _selectedDifficultyFilter == 'All' ||
              difficulty.label == _selectedDifficultyFilter;
          return matchesDifficulty && _matchesStatusFilter(quiz);
        })
        .toList(growable: false);
    if (quizzes.isEmpty) {
      return Center(
        child: Text(
          'No quizzes match these filters',
          style: GoogleFonts.nunito(
            color: SunshineColors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final appState = context.watch<AppState>();
        final hasFullQuizAccess =
            appState.sandboxMode ||
            appState.customerEntitled ||
            (_selectedCategory?.hasFullAccess == true);
        final columns = constraints.maxWidth >= 900
            ? 5
            : constraints.maxWidth >= 620
            ? 4
            : 2;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1,
          ),
          itemCount: quizzes.length,
          itemBuilder: (context, index) {
            final quiz = quizzes[index];
            final locked =
                !hasFullQuizAccess && _isQuizLockedForFreeUser(category, quiz);
            return _QuizTile(
              imageFile: File(category.resolvePath(quiz.tileAsset)),
              title: quiz.title,
              attempt: _attemptsByQuizId[quiz.quizId],
              locked: locked,
              onTap: () => _openQuiz(quiz),
            );
          },
        );
      },
    );
  }

  bool _isQuizLocked(DownloadedQuizCategory category, QuizSetSummary quiz) {
    final appState = context.read<AppState>();
    if (appState.sandboxMode ||
        appState.customerEntitled ||
        (_selectedCategory?.hasFullAccess == true)) {
      return false;
    }
    return _isQuizLockedForFreeUser(category, quiz);
  }

  bool _isQuizLockedForFreeUser(
    DownloadedQuizCategory category,
    QuizSetSummary quiz,
  ) {
    final freeIds = _freeQuizIdsFor(category);
    return !freeIds.contains(quiz.quizId);
  }

  Set<String> _freeQuizIdsFor(DownloadedQuizCategory category) {
    final selected = _selectedCategory;
    final rawLimit = selected?.freeQuizLimit ?? 1;
    final limit = rawLimit < 1 ? 1 : rawLimit;
    final difficulty = (selected?.freeQuizDifficulty ?? 'beginner')
        .trim()
        .toLowerCase();
    final matches = category.definition.quizzes
        .where((quiz) => _quizMatchesDifficulty(category, quiz, difficulty))
        .take(limit)
        .map((quiz) => quiz.quizId)
        .toSet();
    if (matches.isNotEmpty) {
      return matches;
    }
    return category.definition.quizzes
        .take(limit)
        .map((quiz) => quiz.quizId)
        .toSet();
  }

  bool _quizMatchesDifficulty(
    DownloadedQuizCategory category,
    QuizSetSummary quiz,
    String difficulty,
  ) {
    if (difficulty.isEmpty || quiz.difficulty.toLowerCase() == difficulty) {
      return true;
    }
    final matchingDifficulty = category.definition.difficulties.where(
      (item) =>
          item.id == quiz.difficulty &&
          item.label.trim().toLowerCase() == difficulty,
    );
    return matchingDifficulty.isNotEmpty;
  }

  bool _matchesStatusFilter(QuizSetSummary quiz) {
    final status = _attemptsByQuizId[quiz.quizId]?.status;
    return switch (_selectedStatusFilter) {
      'New' => status == null,
      'In Progress' => status == VisualQuizRunStatus.inProgress,
      'Finished' => status == VisualQuizRunStatus.finished,
      _ => true,
    };
  }
}

QuizCategorySummary? initialQuizCategoryForActivation({
  required bool active,
  required QuizCategorySummary? selectedCategory,
  required bool downloading,
  required List<QuizCategorySummary> categories,
}) {
  if (!active ||
      selectedCategory != null ||
      downloading ||
      categories.isEmpty) {
    return null;
  }
  final animals = categories.where((category) {
    final id = category.id.trim().toLowerCase();
    final name = category.name.trim().toLowerCase();
    return id == 'animals' || name == 'animals';
  });
  return animals.isNotEmpty ? animals.first : categories.first;
}

class _QuizCategoryButton extends StatelessWidget {
  const _QuizCategoryButton({
    required this.category,
    required this.imagePath,
    required this.selected,
    required this.onTap,
  });

  final QuizCategorySummary category;
  final String imagePath;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: category.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(38),
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 70,
                height: 70,
                padding: EdgeInsets.all(selected ? 3 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? SunshineColors.sunshineYellow : null,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: buildContentImage(
                    imagePath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: SunshineColors.cream,
                      child: Icon(
                        Icons.quiz_rounded,
                        color: SunshineColors.deepBlue,
                        size: 34,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                category.selectorLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(
                  color: SunshineColors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuizTile extends StatelessWidget {
  const _QuizTile({
    required this.imageFile,
    required this.title,
    required this.attempt,
    required this.locked,
    required this.onTap,
  });

  final File imageFile;
  final String title;
  final VisualQuizAttempt? attempt;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = switch (attempt?.status) {
      VisualQuizRunStatus.inProgress => const _QuizTileStatus(
        label: 'IN PROGRESS',
        icon: Icons.schedule_rounded,
        color: Color(0xFFD96B20),
      ),
      VisualQuizRunStatus.finished => const _QuizTileStatus(
        label: 'FINISHED',
        icon: Icons.check_circle_rounded,
        color: Color(0xFF278547),
      ),
      null => const _QuizTileStatus(
        label: 'NEW',
        icon: Icons.auto_awesome_rounded,
        color: Color(0xFF176A9A),
      ),
    };
    return Semantics(
      button: true,
      label: '$title, ${locked ? 'locked, ' : ''}${status.label.toLowerCase()}',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        elevation: 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Ink.image(
              image: FileImage(imageFile),
              fit: BoxFit.cover,
              child: InkWell(onTap: onTap),
            ),
            if (locked)
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    margin: const EdgeInsets.all(7),
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0xDD17223A),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: SunshineColors.sunshineYellow,
                        width: 1.6,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 5,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.lock_rounded,
                      color: SunshineColors.sunshineYellow,
                      size: 18,
                    ),
                  ),
                ),
              ),
            IgnorePointer(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  margin: const EdgeInsets.all(7),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: status.color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white, width: 1.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 5,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(status.icon, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        status.label,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
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
    );
  }
}

class _QuizTileStatus {
  const _QuizTileStatus({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}
