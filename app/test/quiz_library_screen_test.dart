import 'package:flutter_test/flutter_test.dart';
import 'package:sunshine_app/models/quiz_bundle.dart';
import 'package:sunshine_app/screens/quiz_library_screen.dart';

void main() {
  final birds = _category('birds');
  final animals = _category('animals');

  test('does not select or download a category while Quiz is inactive', () {
    expect(
      initialQuizCategoryForActivation(
        active: false,
        selectedCategory: null,
        downloading: false,
        categories: [birds, animals],
      ),
      isNull,
    );
  });

  test('prefers Animals on the first Quiz activation', () {
    expect(
      initialQuizCategoryForActivation(
        active: true,
        selectedCategory: null,
        downloading: false,
        categories: [birds, animals],
      ),
      same(animals),
    );
  });

  test('preserves the category selected by the child', () {
    expect(
      initialQuizCategoryForActivation(
        active: true,
        selectedCategory: birds,
        downloading: false,
        categories: [birds, animals],
      ),
      isNull,
    );
  });

  test('uses the short display tag for the category selector', () {
    final category = QuizCategorySummary.fromJson({
      'category': {
        'id': 'world-history',
        'name': 'World History',
        'display_title': 'WORLD HISTORY QUIZ',
        'display_tag': 'History',
      },
      'selector_url': '/world-history-selector.webp',
      'bundle_version': 2,
      'content_hash': 'history-content',
      'archive_bytes': 100,
      'archive_sha256': List.filled(64, 'c').join(),
      'minimum_renderer_version': 1,
      'quiz_count': 20,
      'question_count': 200,
      'bundle_download_url': '/world-history-download',
    });

    expect(category.selectorLabel, 'History');
  });

  test('falls back to the category name for older catalogs', () {
    expect(_category('animals').selectorLabel, 'Animals');
  });
}

QuizCategorySummary _category(String id) {
  return QuizCategorySummary(
    id: id,
    name: id == 'animals' ? 'Animals' : 'Birds',
    displayTitle: '${id.toUpperCase()} QUIZ',
    selectorUrl: '/$id-selector.webp',
    bundleVersion: 1,
    contentHash: '${id}_content_hash',
    archiveBytes: 100,
    archiveSha256: List.filled(64, id == 'animals' ? 'a' : 'b').join(),
    minimumRendererVersion: 1,
    quizCount: 20,
    questionCount: 200,
    bundleDownloadUrl: '/$id-download',
  );
}
