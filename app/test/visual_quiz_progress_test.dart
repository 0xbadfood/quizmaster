import 'package:flutter_test/flutter_test.dart';
import 'package:sunshine_app/models/visual_quiz_progress.dart';

void main() {
  test('database row round trip preserves an in-progress quiz', () {
    final attempt = _attempt(updatedAtMillis: 100);

    final restored = VisualQuizAttempt.fromDatabaseRow(attempt.toDatabaseRow());

    expect(restored.categoryId, 'animals');
    expect(restored.quizId, 'animals_beginner_001');
    expect(restored.status, VisualQuizRunStatus.inProgress);
    expect(restored.currentQuestionIndex, 1);
    expect(restored.answers, [2, null]);
    expect(restored.choiceOrders, [
      [2, 0, 1],
      [1, 2, 0],
    ]);
  });

  test('first completed score remains unchanged after a retake', () {
    final firstCompletion = completeVisualQuizAttempt(
      _attempt(updatedAtMillis: 100),
      null,
      correctCount: 7,
      questionCount: 10,
      completedAtMillis: 200,
    );
    final retake = preserveVisualQuizFirstScore(
      _attempt(updatedAtMillis: 300),
      firstCompletion,
    );
    final secondCompletion = completeVisualQuizAttempt(
      retake,
      firstCompletion,
      correctCount: 10,
      questionCount: 10,
      completedAtMillis: 400,
    );

    expect(secondCompletion.status, VisualQuizRunStatus.finished);
    expect(secondCompletion.firstCorrectCount, 7);
    expect(secondCompletion.firstQuestionCount, 10);
    expect(secondCompletion.firstCompletedAtMillis, 200);
  });
}

VisualQuizAttempt _attempt({required int updatedAtMillis}) {
  return VisualQuizAttempt(
    categoryId: 'animals',
    quizId: 'animals_beginner_001',
    status: VisualQuizRunStatus.inProgress,
    currentQuestionIndex: 1,
    answers: const [2, null],
    choiceOrders: const [
      [2, 0, 1],
      [1, 2, 0],
    ],
    updatedAtMillis: updatedAtMillis,
  );
}
