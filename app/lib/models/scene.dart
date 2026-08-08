/// Represents a visual scene in the player timeline
class Scene {
  final String id;
  final int number;
  final double start;
  final double end;
  final String image;
  final String label;

  const Scene({
    required this.id,
    required this.number,
    required this.start,
    required this.end,
    required this.image,
    required this.label,
  });

  factory Scene.fromJson(Map<String, dynamic> json) {
    return Scene(
      id: (json['id'] ?? '').toString(),
      number: ((json['number'] ?? 0) as num).round(),
      start: ((json['start'] ?? 0) as num).toDouble(),
      end: ((json['end'] ?? 0) as num).toDouble(),
      image: (json['image'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
    );
  }
}

/// Represents a single word with timing for karaoke read-along
class TranscriptWord {
  final String word;
  final double start;
  final double end;
  final int line;

  const TranscriptWord({
    required this.word,
    required this.start,
    required this.end,
    required this.line,
  });

  factory TranscriptWord.fromJson(Map<String, dynamic> json) {
    return TranscriptWord(
      word: (json['word'] ?? '').toString(),
      start: ((json['start'] ?? 0) as num).toDouble(),
      end: ((json['end'] ?? 0) as num).toDouble(),
      line: ((json['line'] ?? 0) as num).round(),
    );
  }
}

/// Represents a single timed lyric line for gentle rhyme playback.
class TranscriptLine {
  final int line;
  final String text;
  final double start;
  final double end;

  const TranscriptLine({
    required this.line,
    required this.text,
    required this.start,
    required this.end,
  });

  factory TranscriptLine.fromJson(Map<String, dynamic> json) {
    return TranscriptLine(
      line: ((json['line'] ?? 0) as num).round(),
      text: (json['text'] ?? '').toString(),
      start: ((json['start'] ?? 0) as num).toDouble(),
      end: ((json['end'] ?? json['start'] ?? 0) as num).toDouble(),
    );
  }
}
