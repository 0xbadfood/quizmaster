import 'content_item.dart';

class StoryQuiz {
  final int storyId;
  final List<QuizQuestion> questions;

  const StoryQuiz({required this.storyId, required this.questions});

  bool get hasQuestions => questions.isNotEmpty;

  factory StoryQuiz.fromJson(Map<String, dynamic> json) {
    final questionsJson = json['questions'] as List<dynamic>? ?? const [];
    return StoryQuiz(
      storyId: ((json['story_id'] ?? 0) as num).round(),
      questions: questionsJson
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => QuizQuestion.fromJson(item.cast<String, dynamic>()))
          .where((question) {
            return question.question.trim().isNotEmpty &&
                question.options.length >= 2 &&
                question.correctIndex >= 0 &&
                question.correctIndex < question.options.length;
          })
          .toList(growable: false),
    );
  }
}

class QuizQuestion {
  final int id;
  final String stableQuestionKey;
  final String question;
  final List<String> options;
  final int correctIndex;
  final String correctAnswer;
  final String explanation;
  final String difficulty;
  final String questionType;

  const QuizQuestion({
    required this.id,
    required this.stableQuestionKey,
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.correctAnswer,
    required this.explanation,
    required this.difficulty,
    required this.questionType,
  });

  String get key {
    final stable = stableQuestionKey.trim();
    if (stable.isNotEmpty) {
      return stable;
    }
    if (id > 0) {
      return 'question_$id';
    }
    return question.trim();
  }

  String get correctOption {
    if (correctIndex >= 0 && correctIndex < options.length) {
      return options[correctIndex];
    }
    return correctAnswer;
  }

  factory QuizQuestion.fromJson(Map<String, dynamic> json) {
    final optionsJson = json['options'] as List<dynamic>? ?? const [];
    return QuizQuestion(
      id: ((json['id'] ?? 0) as num).round(),
      stableQuestionKey: (json['stable_question_key'] ?? '').toString(),
      question: (json['question'] ?? '').toString(),
      options: optionsJson
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
      correctIndex: ((json['correct_index'] ?? -1) as num).round(),
      correctAnswer: (json['correct_answer'] ?? '').toString(),
      explanation: (json['explanation'] ?? '').toString(),
      difficulty: (json['difficulty'] ?? '').toString(),
      questionType: (json['question_type'] ?? '').toString(),
    );
  }
}

class QuizAttemptResult {
  final String storyKey;
  final int storyId;
  final String storyTitle;
  final int questionCount;
  final int correctCount;
  final Map<String, int> selectedIndexes;
  final Map<String, int> correctIndexes;
  final int completedAtMillis;

  const QuizAttemptResult({
    required this.storyKey,
    required this.storyId,
    required this.storyTitle,
    required this.questionCount,
    required this.correctCount,
    required this.selectedIndexes,
    required this.correctIndexes,
    required this.completedAtMillis,
  });

  double get scoreRatio =>
      questionCount <= 0 ? 0 : correctCount / questionCount;

  factory QuizAttemptResult.fromJson(Map<String, dynamic> json) {
    Map<String, int> intMap(dynamic value) {
      if (value is! Map) {
        return const {};
      }
      return value.map((key, item) {
        return MapEntry(key.toString(), ((item ?? -1) as num).round());
      });
    }

    return QuizAttemptResult(
      storyKey: (json['story_key'] ?? '').toString(),
      storyId: ((json['story_id'] ?? 0) as num).round(),
      storyTitle: (json['story_title'] ?? '').toString(),
      questionCount: ((json['question_count'] ?? 0) as num).round(),
      correctCount: ((json['correct_count'] ?? 0) as num).round(),
      selectedIndexes: intMap(json['selected_indexes']),
      correctIndexes: intMap(json['correct_indexes']),
      completedAtMillis: ((json['completed_at_millis'] ?? 0) as num).round(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'story_key': storyKey,
      'story_id': storyId,
      'story_title': storyTitle,
      'question_count': questionCount,
      'correct_count': correctCount,
      'selected_indexes': selectedIndexes,
      'correct_indexes': correctIndexes,
      'completed_at_millis': completedAtMillis,
    };
  }

  static String storyKeyFor(ContentItem item) {
    if (item.serverContentId > 0) {
      return '${item.type}:${item.serverContentId}';
    }
    return '${item.type}:${item.id}';
  }
}
