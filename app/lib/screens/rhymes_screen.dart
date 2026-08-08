import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../data/deployed_content_repository.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../models/category.dart';
import '../models/content_item.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/content_card.dart';
import '../widgets/category_icon.dart';
import '../widgets/filter_chip_row.dart';
import '../utils/content_access.dart';
import '../utils/user_facing_error.dart';

class RhymesScreen extends StatefulWidget {
  final void Function(ContentItem item, List<ContentItem> queue)? onPlayItem;
  final ValueChanged<ContentItem>? onLockedItem;
  final VoidCallback? onOpenSettings;
  const RhymesScreen({
    super.key,
    this.onPlayItem,
    this.onLockedItem,
    this.onOpenSettings,
  });

  @override
  State<RhymesScreen> createState() => _RhymesScreenState();
}

class _RhymesScreenState extends State<RhymesScreen> {
  String _selectedCategoryId = 'animals';
  String _selectedFilter = 'All';
  String _searchQuery = '';
  bool _loadingCategoryItems = false;
  String? _categoryLoadError;
  List<ContentItem> _categoryItems = const [];

  List<Category> _rhymeCategoriesFor(AppState appState) =>
      appState.rhymeCategoriesFor('english');

  @override
  void initState() {
    super.initState();
    _loadSelectedCategoryItems();
  }

  Future<void> _loadSelectedCategoryItems() async {
    final categories = context.read<AppState>().rhymeCategoriesFor('english');
    if (categories.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _categoryItems = const [];
        _categoryLoadError = null;
        _loadingCategoryItems = false;
      });
      return;
    }
    final category = categories.firstWhere(
      (item) => item.id == _selectedCategoryId,
      orElse: () => categories.first,
    );
    setState(() {
      _loadingCategoryItems = true;
      _categoryLoadError = null;
    });
    try {
      final items = await DeployedContentRepository.instance.loadCategoryItems(
        category,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _categoryItems = items;
        _loadingCategoryItems = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _categoryItems = const [];
        _loadingCategoryItems = false;
        _categoryLoadError = friendlyContentLoadMessage(error, 'rhymes');
      });
    }
  }

  void _handlePlay(ContentItem item) {
    final appState = context.read<AppState>();
    if (isContentLockedForCurrentUser(appState, item)) {
      widget.onLockedItem?.call(item);
      return;
    }
    final queue = _filteredItems
        .where(
          (candidate) => !isContentLockedForCurrentUser(appState, candidate),
        )
        .toList(growable: false);
    widget.onPlayItem?.call(item, queue);
  }

  List<ContentItem> get _filteredItems {
    var items = _categoryItems.where((item) {
      if (_searchQuery.isNotEmpty) {
        return item.title.toLowerCase().contains(_searchQuery.toLowerCase());
      }
      return true;
    }).toList();
    if (_selectedFilter == 'Popular') {
      items = items.where((i) => i.isPopular).toList();
    }
    if (_selectedFilter == 'New') {
      items = items.where((i) => i.isNew).toList();
    }
    if (_selectedFilter == 'Downloaded') {
      items = items.where((i) => i.downloaded).toList();
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final parentMode = appState.parentMode;
    final rhymeCategories = _rhymeCategoriesFor(appState);
    if (rhymeCategories.isEmpty &&
        (_selectedCategoryId.isNotEmpty ||
            _categoryItems.isNotEmpty ||
            _categoryLoadError != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _selectedCategoryId = '';
          _categoryItems = const [];
          _categoryLoadError = null;
          _loadingCategoryItems = false;
        });
      });
    }
    if (rhymeCategories.isNotEmpty &&
        !rhymeCategories.any((item) => item.id == _selectedCategoryId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() => _selectedCategoryId = rhymeCategories.first.id);
        _loadSelectedCategoryItems();
      });
    }
    return BackgroundScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: SunshineColors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      onChanged: (v) => setState(() => _searchQuery = v),
                      style: GoogleFonts.nunito(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search rhymes',
                        prefixIcon: const Icon(
                          Icons.search,
                          size: 20,
                          color: SunshineColors.lavender,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        hintStyle: GoogleFonts.nunito(
                          color: SunshineColors.darkText.withValues(alpha: 0.3),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: widget.onOpenSettings,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: SunshineColors.white.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.settings,
                      color: SunshineColors.white,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Text(
                  '🎵 Rhymes',
                  style: GoogleFonts.nunito(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.white,
                  ),
                ),
                if (parentMode) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: SunshineColors.cream.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'Parent Mode',
                      style: GoogleFonts.nunito(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: SunshineColors.deepBlue,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 90,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: rhymeCategories.length,
              itemBuilder: (context, index) {
                final cat = rhymeCategories[index];
                return CategoryIcon(
                  category: cat,
                  isSelected: cat.id == _selectedCategoryId,
                  onTap: () {
                    setState(() => _selectedCategoryId = cat.id);
                    _loadSelectedCategoryItems();
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          FilterChipRow(
            selectedFilter: _selectedFilter,
            onFilterChanged: (f) => setState(() => _selectedFilter = f),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loadingCategoryItems
                ? const Center(child: CircularProgressIndicator())
                : _filteredItems.isEmpty
                ? Center(
                    child: Text(
                      _categoryLoadError == null
                          ? 'No rhymes deployed yet'
                          : 'Could not load rhymes',
                      style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: SunshineColors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredItems.length,
                    itemBuilder: (context, index) {
                      final item = _filteredItems[index];
                      return ContentCard(
                        item: item,
                        onPlay: () => _handlePlay(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
