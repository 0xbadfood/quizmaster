import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sunshine_app/data/quiz_bundle_repository.dart';
import 'package:sunshine_app/models/quiz_bundle.dart';

void main() {
  late Directory storageRoot;

  setUp(() async {
    storageRoot = await Directory.systemTemp.createTemp('quiz_bundle_test_');
  });

  tearDown(() async {
    if (await storageRoot.exists()) {
      await storageRoot.delete(recursive: true);
    }
  });

  test(
    'downloads, verifies, extracts, and reuses an immutable release',
    () async {
      final fixture = _bundleFixture();
      var downloadCount = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/download')) {
          downloadCount += 1;
          return http.Response.bytes(fixture.archive, HttpStatus.ok);
        }
        return http.Response('not found', HttpStatus.notFound);
      });
      final repository = QuizBundleRepository(
        client: client,
        apiOrigin: 'https://quiz.test',
        storageRoot: storageRoot,
      );
      final summary = _summary(
        archiveBytes: fixture.archive.length,
        archiveSha256: sha256.convert(fixture.archive).toString(),
      );

      final first = await repository.ensureDownloaded(summary);
      final second = await repository.ensureDownloaded(summary);

      expect(first.definition.id, 'animals');
      expect(first.definition.quizzes.single.quizId, 'animals_beginner_001');
      expect(second.contentHash, summary.contentHash);
      expect(downloadCount, 1);
      expect(File(first.resolvePath('category.json')).existsSync(), isTrue);
    },
  );

  test('rejects a bundle whose archive hash does not match', () async {
    final fixture = _bundleFixture();
    final repository = QuizBundleRepository(
      client: MockClient(
        (_) async => http.Response.bytes(fixture.archive, HttpStatus.ok),
      ),
      apiOrigin: 'https://quiz.test',
      storageRoot: storageRoot,
    );

    expect(
      () => repository.ensureDownloaded(
        _summary(
          archiveBytes: fixture.archive.length,
          archiveSha256: List.filled(64, '0').join(),
        ),
      ),
      throwsA(isA<QuizBundleException>()),
    );
  });

  test('keeps the Quizmaster library fully accessible without login', () {
    final repository = QuizBundleRepository(
      client: MockClient((_) async => http.Response('', HttpStatus.notFound)),
      apiOrigin: 'https://quiz.test',
      storageRoot: storageRoot,
    );

    expect(repository.customerHasFullLibrary, isTrue);

    repository.setCustomerAccess(hasFullLibrary: false);

    expect(repository.customerHasFullLibrary, isTrue);
  });

  test('parses a four-image visual question with deterministic answer', () {
    final quiz = VisualQuizDocument.fromJson({
      'set_id': 'animals_beginner_001',
      'category': 'Animals',
      'difficulty': 'beginner',
      'questions': List.generate(10, (index) => _question(index)),
      'answer_assets': {
        'lion': 'assets/answers/lion.webp',
        'tiger': 'assets/answers/tiger.webp',
        'zebra': 'assets/answers/zebra.webp',
        'elephant': 'assets/answers/elephant.webp',
      },
    });

    expect(quiz.questions, hasLength(10));
    expect(quiz.questions.first.correctIndex, 0);
    expect(quiz.questions.first.choices, hasLength(4));
  });

  test('parses MP3 narration and prefixed feedback audio metadata', () {
    final presentation = QuizPresentation.fromJson({
      'runtime_background': 'assets/background.webp',
      'settings_button': 'assets/settings.webp',
      'speaker_on_button': 'assets/speaker-on.webp',
      'speaker_muted_button': 'assets/speaker-muted.webp',
      'progress_style': 'runtime/progress-style.json',
      'audio': {
        'correct_sfx': 'assets/audio/correct.mp3',
        'incorrect_sfx': 'assets/audio/incorrect.mp3',
        'praise_clips': List.generate(
          5,
          (index) => {
            'id': 'praise_$index',
            'text': 'Praise $index',
            'file': 'assets/audio/praise_$index.mp3',
          },
        ),
      },
    });
    final question = VisualQuizQuestion.fromJson({
      ..._question(0),
      'audio': {
        'question': 'assets/audio/question.mp3',
        'explanation': 'assets/audio/explanation.mp3',
      },
    });

    expect(presentation.audio?.correctSfx, endsWith('.mp3'));
    expect(presentation.audio?.incorrectSfx, endsWith('.mp3'));
    expect(presentation.audio?.praiseClips, hasLength(5));
    expect(question.audio?.question, endsWith('.mp3'));
    expect(question.audio?.explanation, endsWith('.mp3'));
  });
}

QuizCategorySummary _summary({
  required int archiveBytes,
  required String archiveSha256,
}) {
  return QuizCategorySummary.fromJson({
    'category': {
      'id': 'animals',
      'name': 'Animals',
      'display_title': 'ANIMAL QUIZ',
    },
    'selector_url': '/api/v1/categories/animals/selector',
    'bundle_version': 1,
    'content_hash': 'content-hash-1',
    'archive_bytes': archiveBytes,
    'archive_sha256': archiveSha256,
    'minimum_renderer_version': 1,
    'quiz_count': 1,
    'question_count': 10,
    'bundle_download_url': '/api/v1/categories/animals/bundles/1/download',
  });
}

({List<int> archive}) _bundleFixture() {
  final category = utf8.encode(
    jsonEncode({
      'category': {
        'id': 'animals',
        'name': 'Animals',
        'display_title': 'ANIMAL QUIZ',
      },
      'presentation': {
        'runtime_background': 'assets/category/background.png',
        'settings_button': 'assets/global/settings.webp',
        'speaker_on_button': 'assets/global/speaker-on.webp',
        'speaker_muted_button': 'assets/global/speaker-muted.webp',
        'progress_style': 'runtime/progress-style.json',
      },
      'difficulties': [
        {'id': 'beginner', 'label': 'Beginner', 'quiz_count': 1},
      ],
      'quizzes': [
        {
          'quiz_id': 'animals_beginner_001',
          'number': 1,
          'difficulty': 'beginner',
          'title': 'ANIMAL QUIZ 1',
          'question_count': 10,
          'tile_asset': 'assets/tiles/beginner_01.webp',
          'questions_file': 'quizzes/beginner/animals_beginner_001.json',
        },
      ],
    }),
  );
  final bundle = utf8.encode(
    jsonEncode({
      'bundle_version': 1,
      'content_hash': 'content-hash-1',
      'minimum_renderer_version': 1,
      'files': [
        {
          'path': 'category.json',
          'bytes': category.length,
          'sha256': sha256.convert(category).toString(),
        },
      ],
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('bundle.json', bundle.length, bundle))
    ..addFile(ArchiveFile('category.json', category.length, category));
  return (archive: ZipEncoder().encode(archive)!);
}

Map<String, dynamic> _question(int index) {
  return {
    'question_id': 'question_$index',
    'question': 'Which animal is the correct answer for clue $index?',
    'choices': [
      {'choice_id': 'choice1', 'animal_key': 'lion', 'label': 'Lion'},
      {'choice_id': 'choice2', 'animal_key': 'tiger', 'label': 'Tiger'},
      {'choice_id': 'choice3', 'animal_key': 'zebra', 'label': 'Zebra'},
      {'choice_id': 'choice4', 'animal_key': 'elephant', 'label': 'Elephant'},
    ],
    'correct_choice_id': 'choice1',
    'explanation': 'The lion is the correct animal for this clue.',
  };
}
