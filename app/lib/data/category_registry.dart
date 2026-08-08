import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/category.dart';

class CategoryRegistry {
  final int version;
  final List<Category> _rhymeEnglish;
  final List<Category> _storyEnglish;
  final List<Category> _storyHindi;

  static CategoryRegistry? _instance;

  CategoryRegistry._({
    required this.version,
    required List<Category> rhymeEnglish,
    required List<Category> storyEnglish,
    required List<Category> storyHindi,
  }) : _rhymeEnglish = List.unmodifiable(rhymeEnglish),
       _storyEnglish = List.unmodifiable(storyEnglish),
       _storyHindi = List.unmodifiable(storyHindi);

  static CategoryRegistry get instance {
    final registry = _instance;
    if (registry == null) {
      throw StateError('CategoryRegistry has not been initialized.');
    }
    return registry;
  }

  static Future<void> initialize() async {
    _instance = await _loadFromAsset();
  }

  List<Category> rhymeCategoriesFor(String _) => _rhymeEnglish;

  List<Category> storyCategoriesFor(String language) =>
      _prioritizeStoryCategories(
        language.toLowerCase() == 'hindi' ? _storyHindi : _storyEnglish,
      );

  static Future<CategoryRegistry> _loadFromAsset() async {
    final raw = await rootBundle.loadString(
      'assets/config/category_registry.json',
    );
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    return CategoryRegistry._(
      version: (payload['version'] as num?)?.toInt() ?? 1,
      rhymeEnglish: _parseCategoryList(
        type: 'rhyme',
        language: 'english',
        source: payload['rhymes']?['english'],
      ),
      storyEnglish: _parseCategoryList(
        type: 'story',
        language: 'english',
        source: payload['stories']?['english'],
      ),
      storyHindi: _parseCategoryList(
        type: 'story',
        language: 'hindi',
        source: payload['stories']?['hindi'],
      ),
    );
  }

  static List<Category> _parseCategoryList({
    required String type,
    required String language,
    required dynamic source,
  }) {
    final items = (source as List<dynamic>? ?? const <dynamic>[]);
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (item) => Category(
            id: item['id']?.toString() ?? '',
            label: item['label']?.toString() ?? '',
            type: type,
            language: language,
            serverCategoryId:
                (item['server_category_id'] as num?)?.toInt() ?? 0,
            icon: _fallbackIconFor(item['id']?.toString() ?? '', type),
            assetPath: _assetPathFor(item['asset_key']?.toString()),
          ),
        )
        .where(
          (category) => category.id.isNotEmpty && category.serverCategoryId > 0,
        )
        .toList(growable: false);
  }

  static List<Category> _prioritizeStoryCategories(List<Category> categories) {
    final prioritized = categories.where((category) => category.id == 'morals');
    final remaining = categories.where((category) => category.id != 'morals');
    return List<Category>.unmodifiable([...prioritized, ...remaining]);
  }

  static String? _assetPathFor(String? assetKey) {
    final normalized = (assetKey ?? '').trim();
    if (normalized.isEmpty) {
      return null;
    }
    return 'assets/images/category_icons/$normalized.png';
  }

  static IconData fallbackIconFor(String id, String type) {
    switch (id) {
      case 'animals':
        return Icons.pets;
      case 'nature':
        return Icons.park;
      case 'action':
        return Icons.directions_run;
      case 'learning':
        return Icons.lightbulb;
      case 'routine':
      case 'everyday':
        return Icons.home;
      case 'family':
        return Icons.family_restroom;
      case 'vehicles':
        return Icons.directions_car;
      case 'moral':
      case 'morals':
      case 'emotions':
        return Icons.favorite;
      case 'fun':
      case 'funny':
        return Icons.sentiment_very_satisfied;
      case 'lullaby':
      case 'bedtime':
        return Icons.bedtime;
      case 'food':
        return Icons.restaurant;
      case 'magic':
        return Icons.auto_fix_high;
      case 'adventure':
        return Icons.explore;
      case 'science':
        return Icons.science;
      case 'mythology':
        return Icons.temple_hindu;
      case 'heroes':
        return Icons.shield;
      case 'festivals':
        return Icons.celebration;
      case 'interactive':
        return Icons.touch_app;
      default:
        return type == 'story' ? Icons.auto_stories : Icons.music_note;
    }
  }

  static IconData _fallbackIconFor(String id, String type) =>
      fallbackIconFor(id, type);
}
