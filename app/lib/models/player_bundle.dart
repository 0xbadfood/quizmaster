import 'content_item.dart';
import 'quiz.dart';
import 'scene.dart';

class PlayerBundle {
  final ContentItem content;
  final List<Scene> scenes;
  final List<TranscriptLine> transcriptLines;
  final List<TranscriptWord> transcriptWords;
  final StoryQuiz? quiz;

  const PlayerBundle({
    required this.content,
    required this.scenes,
    required this.transcriptLines,
    required this.transcriptWords,
    this.quiz,
  });

  factory PlayerBundle.fromJson(Map<String, dynamic> json) {
    final scenesJson = (json['scenes'] as List<dynamic>? ?? const []);
    final transcriptLinesJson =
        (json['transcript_lines'] as List<dynamic>? ?? const []);
    final transcriptJson =
        (json['transcript_words'] as List<dynamic>? ?? const []);
    final quizJson = json['quiz'];
    return PlayerBundle(
      content: ContentItem.fromJson(
        (json['content'] as Map<dynamic, dynamic>? ?? const {})
            .cast<String, dynamic>(),
      ),
      scenes: scenesJson
          .whereType<Map<dynamic, dynamic>>()
          .map((scene) => Scene.fromJson(scene.cast<String, dynamic>()))
          .toList(),
      transcriptLines: transcriptLinesJson
          .whereType<Map<dynamic, dynamic>>()
          .map((line) => TranscriptLine.fromJson(line.cast<String, dynamic>()))
          .toList(),
      transcriptWords: transcriptJson
          .whereType<Map<dynamic, dynamic>>()
          .map((word) => TranscriptWord.fromJson(word.cast<String, dynamic>()))
          .where(
            (word) =>
                word.word.trim().isNotEmpty &&
                word.word.trim().toLowerCase() != '<unk>',
          )
          .toList(),
      quiz: quizJson is Map
          ? StoryQuiz.fromJson(quizJson.cast<String, dynamic>())
          : null,
    );
  }
}
