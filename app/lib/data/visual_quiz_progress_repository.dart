import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/visual_quiz_progress.dart';

abstract interface class VisualQuizProgressStore {
  Future<Map<String, VisualQuizAttempt>> loadCategory(String categoryId);

  Future<VisualQuizAttempt?> loadAttempt(String categoryId, String quizId);

  Future<VisualQuizAttempt> saveProgress(VisualQuizAttempt attempt);

  Future<VisualQuizAttempt> startRetake(VisualQuizAttempt attempt);

  Future<VisualQuizAttempt> completeAttempt(
    VisualQuizAttempt attempt, {
    required int correctCount,
    required int questionCount,
  });
}

class SqliteVisualQuizProgressStore implements VisualQuizProgressStore {
  SqliteVisualQuizProgressStore._();

  static final SqliteVisualQuizProgressStore instance =
      SqliteVisualQuizProgressStore._();

  static const _table = 'quiz_attempts';
  Database? _database;

  Future<Database> get _db async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }
    final database = await openDatabase(
      path.join(await getDatabasesPath(), 'visual_quiz_progress.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            category_id TEXT NOT NULL,
            quiz_id TEXT NOT NULL,
            run_status TEXT NOT NULL,
            current_question_index INTEGER NOT NULL,
            answers_json TEXT NOT NULL,
            choice_orders_json TEXT NOT NULL,
            first_correct_count INTEGER,
            first_question_count INTEGER,
            first_completed_at_millis INTEGER,
            updated_at_millis INTEGER NOT NULL,
            PRIMARY KEY (category_id, quiz_id)
          )
        ''');
      },
    );
    _database = database;
    return database;
  }

  @override
  Future<Map<String, VisualQuizAttempt>> loadCategory(String categoryId) async {
    final rows = await (await _db).query(
      _table,
      where: 'category_id = ?',
      whereArgs: [categoryId],
    );
    return {
      for (final row in rows)
        row['quiz_id'] as String: VisualQuizAttempt.fromDatabaseRow(row),
    };
  }

  @override
  Future<VisualQuizAttempt?> loadAttempt(
    String categoryId,
    String quizId,
  ) async {
    final rows = await (await _db).query(
      _table,
      where: 'category_id = ? AND quiz_id = ?',
      whereArgs: [categoryId, quizId],
      limit: 1,
    );
    return rows.isEmpty ? null : VisualQuizAttempt.fromDatabaseRow(rows.first);
  }

  @override
  Future<VisualQuizAttempt> saveProgress(VisualQuizAttempt attempt) async {
    final db = await _db;
    return db.transaction((transaction) async {
      final existing = await _loadFromExecutor(
        transaction,
        attempt.categoryId,
        attempt.quizId,
      );
      final saved = preserveVisualQuizFirstScore(attempt, existing).copyWith(
        status: VisualQuizRunStatus.inProgress,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await transaction.insert(
        _table,
        saved.toDatabaseRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return saved;
    });
  }

  @override
  Future<VisualQuizAttempt> startRetake(VisualQuizAttempt attempt) {
    return saveProgress(
      attempt.copyWith(status: VisualQuizRunStatus.inProgress),
    );
  }

  @override
  Future<VisualQuizAttempt> completeAttempt(
    VisualQuizAttempt attempt, {
    required int correctCount,
    required int questionCount,
  }) async {
    final db = await _db;
    return db.transaction((transaction) async {
      final existing = await _loadFromExecutor(
        transaction,
        attempt.categoryId,
        attempt.quizId,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final completed = completeVisualQuizAttempt(
        attempt,
        existing,
        correctCount: correctCount,
        questionCount: questionCount,
        completedAtMillis: now,
      );
      await transaction.insert(
        _table,
        completed.toDatabaseRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return completed;
    });
  }

  Future<VisualQuizAttempt?> _loadFromExecutor(
    DatabaseExecutor executor,
    String categoryId,
    String quizId,
  ) async {
    final rows = await executor.query(
      _table,
      where: 'category_id = ? AND quiz_id = ?',
      whereArgs: [categoryId, quizId],
      limit: 1,
    );
    return rows.isEmpty ? null : VisualQuizAttempt.fromDatabaseRow(rows.first);
  }
}
