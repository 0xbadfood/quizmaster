import 'dart:convert';

enum VisualQuizRunStatus { inProgress, finished }

class VisualQuizAttempt {
  const VisualQuizAttempt({
    required this.categoryId,
    required this.quizId,
    required this.status,
    required this.currentQuestionIndex,
    required this.answers,
    required this.choiceOrders,
    required this.updatedAtMillis,
    this.firstCorrectCount,
    this.firstQuestionCount,
    this.firstCompletedAtMillis,
  });

  final String categoryId;
  final String quizId;
  final VisualQuizRunStatus status;
  final int currentQuestionIndex;
  final List<int?> answers;
  final List<List<int>> choiceOrders;
  final int? firstCorrectCount;
  final int? firstQuestionCount;
  final int? firstCompletedAtMillis;
  final int updatedAtMillis;

  bool get hasFirstScore =>
      firstCorrectCount != null && firstQuestionCount != null;

  VisualQuizAttempt copyWith({
    VisualQuizRunStatus? status,
    int? currentQuestionIndex,
    List<int?>? answers,
    List<List<int>>? choiceOrders,
    int? firstCorrectCount,
    int? firstQuestionCount,
    int? firstCompletedAtMillis,
    int? updatedAtMillis,
  }) {
    return VisualQuizAttempt(
      categoryId: categoryId,
      quizId: quizId,
      status: status ?? this.status,
      currentQuestionIndex: currentQuestionIndex ?? this.currentQuestionIndex,
      answers: answers ?? this.answers,
      choiceOrders: choiceOrders ?? this.choiceOrders,
      firstCorrectCount: firstCorrectCount ?? this.firstCorrectCount,
      firstQuestionCount: firstQuestionCount ?? this.firstQuestionCount,
      firstCompletedAtMillis:
          firstCompletedAtMillis ?? this.firstCompletedAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    );
  }

  Map<String, Object?> toDatabaseRow() {
    return {
      'category_id': categoryId,
      'quiz_id': quizId,
      'run_status': status.name,
      'current_question_index': currentQuestionIndex,
      'answers_json': jsonEncode(answers),
      'choice_orders_json': jsonEncode(choiceOrders),
      'first_correct_count': firstCorrectCount,
      'first_question_count': firstQuestionCount,
      'first_completed_at_millis': firstCompletedAtMillis,
      'updated_at_millis': updatedAtMillis,
    };
  }

  factory VisualQuizAttempt.fromDatabaseRow(Map<String, Object?> row) {
    final statusName = row['run_status'] as String?;
    return VisualQuizAttempt(
      categoryId: row['category_id'] as String,
      quizId: row['quiz_id'] as String,
      status: VisualQuizRunStatus.values.firstWhere(
        (value) => value.name == statusName,
        orElse: () => VisualQuizRunStatus.inProgress,
      ),
      currentQuestionIndex: row['current_question_index'] as int,
      answers: (jsonDecode(row['answers_json'] as String) as List<dynamic>)
          .map((value) => value as int?)
          .toList(growable: false),
      choiceOrders:
          (jsonDecode(row['choice_orders_json'] as String) as List<dynamic>)
              .map(
                (order) => (order as List<dynamic>)
                    .map((value) => value as int)
                    .toList(growable: false),
              )
              .toList(growable: false),
      firstCorrectCount: row['first_correct_count'] as int?,
      firstQuestionCount: row['first_question_count'] as int?,
      firstCompletedAtMillis: row['first_completed_at_millis'] as int?,
      updatedAtMillis: row['updated_at_millis'] as int,
    );
  }
}

VisualQuizAttempt preserveVisualQuizFirstScore(
  VisualQuizAttempt attempt,
  VisualQuizAttempt? existing,
) {
  if (existing == null || !existing.hasFirstScore) {
    return attempt;
  }
  return VisualQuizAttempt(
    categoryId: attempt.categoryId,
    quizId: attempt.quizId,
    status: attempt.status,
    currentQuestionIndex: attempt.currentQuestionIndex,
    answers: attempt.answers,
    choiceOrders: attempt.choiceOrders,
    firstCorrectCount: existing.firstCorrectCount,
    firstQuestionCount: existing.firstQuestionCount,
    firstCompletedAtMillis: existing.firstCompletedAtMillis,
    updatedAtMillis: attempt.updatedAtMillis,
  );
}

VisualQuizAttempt completeVisualQuizAttempt(
  VisualQuizAttempt attempt,
  VisualQuizAttempt? existing, {
  required int correctCount,
  required int questionCount,
  required int completedAtMillis,
}) {
  final merged = preserveVisualQuizFirstScore(attempt, existing);
  return VisualQuizAttempt(
    categoryId: merged.categoryId,
    quizId: merged.quizId,
    status: VisualQuizRunStatus.finished,
    currentQuestionIndex: merged.currentQuestionIndex,
    answers: merged.answers,
    choiceOrders: merged.choiceOrders,
    firstCorrectCount: merged.firstCorrectCount ?? correctCount,
    firstQuestionCount: merged.firstQuestionCount ?? questionCount,
    firstCompletedAtMillis: merged.firstCompletedAtMillis ?? completedAtMillis,
    updatedAtMillis: completedAtMillis,
  );
}
