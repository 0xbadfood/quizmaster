import 'package:flutter/material.dart';

/// Represents a content category (e.g. Animals, ABC, Bedtime)
class Category {
  final String id;
  final String label;
  final String type; // 'rhyme' or 'story'
  final String language; // 'english' or 'hindi'
  final int serverCategoryId;
  final IconData icon;
  final String? assetPath;
  final String? iconUrl;

  const Category({
    required this.id,
    required this.label,
    required this.type,
    this.language = 'english',
    required this.serverCategoryId,
    required this.icon,
    this.assetPath,
    this.iconUrl,
  });
}
