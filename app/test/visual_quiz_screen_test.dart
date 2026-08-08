import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunshine_app/data/visual_quiz_progress_repository.dart';
import 'package:sunshine_app/models/quiz_bundle.dart';
import 'package:sunshine_app/models/visual_quiz_progress.dart';
import 'package:sunshine_app/screens/visual_quiz_screen.dart';

void main() {
  testWidgets('shows the answer modal and advances from it', (tester) async {
    final progressStore = _MemoryProgressStore();
    final answerAudioCompletion = Completer<void>();
    final root = Directory.systemTemp.createTempSync('quiz_screen_test_');
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    for (final path in [
      'background.png',
      'settings.png',
      'speaker-on.png',
      'speaker-muted.png',
      'lion.png',
      'tiger.png',
      'zebra.png',
      'elephant.png',
    ]) {
      File('${root.path}/$path').writeAsBytesSync(image);
    }

    final category = DownloadedQuizCategory(
      directory: root,
      bundleVersion: 1,
      contentHash: 'hash',
      definition: const QuizCategoryDefinition(
        id: 'animals',
        name: 'Animals',
        displayTitle: 'ANIMAL QUIZ',
        presentation: QuizPresentation(
          runtimeBackground: 'background.png',
          settingsButton: 'settings.png',
          speakerOnButton: 'speaker-on.png',
          speakerMutedButton: 'speaker-muted.png',
          progressStyle: 'progress.json',
        ),
        difficulties: [
          QuizDifficulty(id: 'beginner', label: 'Beginner', quizCount: 1),
        ],
        quizzes: [],
      ),
    );
    final choices = const [
      VisualQuizChoice(choiceId: 'choice1', animalKey: 'lion', label: 'Lion'),
      VisualQuizChoice(choiceId: 'choice2', animalKey: 'tiger', label: 'Tiger'),
      VisualQuizChoice(choiceId: 'choice3', animalKey: 'zebra', label: 'Zebra'),
      VisualQuizChoice(
        choiceId: 'choice4',
        animalKey: 'elephant',
        label: 'Elephant',
      ),
    ];
    final questions = List.generate(
      10,
      (index) => VisualQuizQuestion(
        questionId: 'question_$index',
        question: 'Which animal is king of the jungle?',
        choices: choices,
        correctChoiceId: 'choice1',
        explanation: 'The lion is commonly called the king of the jungle.',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: VisualQuizScreen(
          category: category,
          summary: const QuizSetSummary(
            quizId: 'animals_beginner_001',
            number: 1,
            difficulty: 'beginner',
            title: 'ANIMAL QUIZ 1',
            questionCount: 10,
            tileAsset: 'tile.png',
            questionsFile: 'quiz.json',
          ),
          quiz: VisualQuizDocument(
            setId: 'animals_beginner_001',
            category: 'Animals',
            difficulty: 'beginner',
            questions: questions,
            answerAssets: const {
              'lion': 'lion.png',
              'tiger': 'tiger.png',
              'zebra': 'zebra.png',
              'elephant': 'elephant.png',
            },
          ),
          progressStyle: QuizProgressStyle.fromJson(_progressStyle),
          progressStore: progressStore,
          answerAudioPlayerOverride: (_, _) => answerAudioCompletion.future,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Correct answer:'), findsNothing);
    await tester.tap(find.byTooltip('Mute sound'));
    await tester.pump();
    await tester.ensureVisible(find.text('Lion'));
    await tester.pump();
    await tester.tap(find.text('Lion'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Correct answer: Lion'), findsOneWidget);
    expect(
      find.text('The lion is commonly called the king of the jungle.'),
      findsOneWidget,
    );
    expect(find.text('Question 1 of 10'), findsOneWidget);
    expect(find.byKey(const Key('quiz-answer-audio-waiting')), findsOneWidget);
    expect(find.text('Next Question'), findsNothing);

    answerAudioCompletion.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quiz-answer-audio-waiting')), findsNothing);
    expect(find.text('Next Question'), findsOneWidget);

    await tester.tap(find.text('Next Question'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Correct answer:'), findsNothing);
    expect(find.text('Question 2 of 10'), findsOneWidget);
    expect(progressStore.attempts.single.currentQuestionIndex, 1);
    expect(progressStore.attempts.single.answers.first, 0);
  });

  testWidgets('resumes the stored question and choice order', (tester) async {
    final fixture = _QuizFixture.create();
    addTearDown(fixture.dispose);
    final progressStore = _MemoryProgressStore();
    final answers = List<int?>.filled(10, null);
    answers[0] = 0;
    answers[1] = 1;
    final orders = List.generate(10, (_) => [0, 1, 2, 3]);
    orders[2] = [3, 2, 1, 0];
    final initialAttempt = VisualQuizAttempt(
      categoryId: 'animals',
      quizId: 'animals_beginner_001',
      status: VisualQuizRunStatus.inProgress,
      currentQuestionIndex: 2,
      answers: answers,
      choiceOrders: orders,
      updatedAtMillis: 100,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: VisualQuizScreen(
          category: fixture.category,
          summary: fixture.summary,
          quiz: fixture.quiz,
          progressStyle: QuizProgressStyle.fromJson(_progressStyle),
          progressStore: progressStore,
          initialAttempt: initialAttempt,
          answerAudioPlayerOverride: (_, _) async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Question 3 of 10'), findsOneWidget);
    await tester.ensureVisible(find.text('Elephant'));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Elephant')).dy,
      lessThan(tester.getTopLeft(find.text('Lion')).dy),
    );

    await tester.ensureVisible(find.byTooltip('Back'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(progressStore.attempts.single.currentQuestionIndex, 2);
    expect(progressStore.attempts.single.answers.take(2), [0, 1]);
    expect(progressStore.attempts.single.choiceOrders[2], [3, 2, 1, 0]);
  });

  testWidgets('can show Next before explanation audio completes', (
    tester,
  ) async {
    final fixture = _QuizFixture.create();
    addTearDown(fixture.dispose);
    final audioCompletion = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: VisualQuizScreen(
          category: fixture.category,
          summary: fixture.summary,
          quiz: fixture.quiz,
          progressStyle: QuizProgressStyle.fromJson(_progressStyle),
          progressStore: _MemoryProgressStore(),
          waitForExplanationAudio: false,
          answerAudioPlayerOverride: (_, _) => audioCompletion.future,
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Lion'));
    await tester.pump();
    await tester.tap(find.text('Lion'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('quiz-answer-audio-waiting')), findsNothing);
    expect(find.text('Next Question'), findsOneWidget);

    audioCompletion.complete();
  });
}

class _QuizFixture {
  _QuizFixture({
    required this.root,
    required this.category,
    required this.summary,
    required this.quiz,
  });

  final Directory root;
  final DownloadedQuizCategory category;
  final QuizSetSummary summary;
  final VisualQuizDocument quiz;

  static _QuizFixture create() {
    final root = Directory.systemTemp.createTempSync('quiz_resume_test_');
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    for (final path in [
      'background.png',
      'settings.png',
      'speaker-on.png',
      'speaker-muted.png',
      'lion.png',
      'tiger.png',
      'zebra.png',
      'elephant.png',
    ]) {
      File('${root.path}/$path').writeAsBytesSync(image);
    }
    const choices = [
      VisualQuizChoice(choiceId: 'choice1', animalKey: 'lion', label: 'Lion'),
      VisualQuizChoice(choiceId: 'choice2', animalKey: 'tiger', label: 'Tiger'),
      VisualQuizChoice(choiceId: 'choice3', animalKey: 'zebra', label: 'Zebra'),
      VisualQuizChoice(
        choiceId: 'choice4',
        animalKey: 'elephant',
        label: 'Elephant',
      ),
    ];
    final questions = List.generate(
      10,
      (index) => VisualQuizQuestion(
        questionId: 'question_$index',
        question: 'Which animal is king of the jungle?',
        choices: choices,
        correctChoiceId: 'choice1',
        explanation: 'The lion is commonly called the king of the jungle.',
      ),
    );
    const summary = QuizSetSummary(
      quizId: 'animals_beginner_001',
      number: 1,
      difficulty: 'beginner',
      title: 'ANIMAL QUIZ 1',
      questionCount: 10,
      tileAsset: 'tile.png',
      questionsFile: 'quiz.json',
    );
    final category = DownloadedQuizCategory(
      directory: root,
      bundleVersion: 1,
      contentHash: 'hash',
      definition: const QuizCategoryDefinition(
        id: 'animals',
        name: 'Animals',
        displayTitle: 'ANIMAL QUIZ',
        presentation: QuizPresentation(
          runtimeBackground: 'background.png',
          settingsButton: 'settings.png',
          speakerOnButton: 'speaker-on.png',
          speakerMutedButton: 'speaker-muted.png',
          progressStyle: 'progress.json',
        ),
        difficulties: [
          QuizDifficulty(id: 'beginner', label: 'Beginner', quizCount: 1),
        ],
        quizzes: [],
      ),
    );
    return _QuizFixture(
      root: root,
      category: category,
      summary: summary,
      quiz: VisualQuizDocument(
        setId: summary.quizId,
        category: 'Animals',
        difficulty: 'beginner',
        questions: questions,
        answerAssets: const {
          'lion': 'lion.png',
          'tiger': 'tiger.png',
          'zebra': 'zebra.png',
          'elephant': 'elephant.png',
        },
      ),
    );
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

class _MemoryProgressStore implements VisualQuizProgressStore {
  final Map<String, VisualQuizAttempt> _attempts = {};

  List<VisualQuizAttempt> get attempts => _attempts.values.toList();

  String _key(String categoryId, String quizId) => '$categoryId/$quizId';

  @override
  Future<VisualQuizAttempt> completeAttempt(
    VisualQuizAttempt attempt, {
    required int correctCount,
    required int questionCount,
  }) async {
    final key = _key(attempt.categoryId, attempt.quizId);
    final completed = completeVisualQuizAttempt(
      attempt,
      _attempts[key],
      correctCount: correctCount,
      questionCount: questionCount,
      completedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    _attempts[key] = completed;
    return completed;
  }

  @override
  Future<VisualQuizAttempt?> loadAttempt(
    String categoryId,
    String quizId,
  ) async {
    return _attempts[_key(categoryId, quizId)];
  }

  @override
  Future<Map<String, VisualQuizAttempt>> loadCategory(String categoryId) async {
    return {
      for (final attempt in _attempts.values)
        if (attempt.categoryId == categoryId) attempt.quizId: attempt,
    };
  }

  @override
  Future<VisualQuizAttempt> saveProgress(VisualQuizAttempt attempt) async {
    final key = _key(attempt.categoryId, attempt.quizId);
    final saved = preserveVisualQuizFirstScore(attempt, _attempts[key]);
    _attempts[key] = saved;
    return saved;
  }

  @override
  Future<VisualQuizAttempt> startRetake(VisualQuizAttempt attempt) {
    return saveProgress(attempt);
  }
}

const _progressStyle = <String, dynamic>{
  'question_count': 10,
  'geometry': {
    'marker_diameter_dp': 32,
    'marker_border_dp': 2,
    'connector_height_dp': 4,
    'current_glow_blur_dp': 10,
  },
  'states': {
    'unanswered': {'fill': '#123F24', 'border': '#A8D76F', 'text': '#F8F2D8'},
    'current': {'fill': '#F6B91A', 'border': '#FFF3A6', 'text': '#FFFFFF'},
    'correct': {'fill': '#36A852', 'border': '#B9F28A', 'text': '#FFFFFF'},
    'incorrect': {'fill': '#D94B4B', 'border': '#FFC0B7', 'text': '#FFFFFF'},
  },
  'connector': {'unanswered': '#78A94E', 'answered': '#D7B52E'},
  'animation_ms': 220,
};
