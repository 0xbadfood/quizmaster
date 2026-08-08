import 'dart:io';

class QuizCategorySummary {
  const QuizCategorySummary({
    required this.id,
    required this.name,
    required this.displayTitle,
    this.displayTag = '',
    required this.selectorUrl,
    this.cachedSelectorImagePath,
    required this.bundleVersion,
    required this.contentHash,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.minimumRendererVersion,
    required this.quizCount,
    required this.questionCount,
    required this.bundleDownloadUrl,
    this.hasFullAccess = false,
    this.freeQuizLimit = 1,
    this.freeQuizDifficulty = 'beginner',
  });

  final String id;
  final String name;
  final String displayTitle;
  final String displayTag;
  String get selectorLabel => displayTag.trim().isEmpty ? name : displayTag;
  final String selectorUrl;
  final String? cachedSelectorImagePath;
  final int bundleVersion;
  final String contentHash;
  final int archiveBytes;
  final String archiveSha256;
  final int minimumRendererVersion;
  final int quizCount;
  final int questionCount;
  final String bundleDownloadUrl;
  final bool hasFullAccess;
  final int freeQuizLimit;
  final String freeQuizDifficulty;

  factory QuizCategorySummary.fromJson(Map<String, dynamic> json) {
    final category = _map(json['category']);
    final result = QuizCategorySummary(
      id: _text(category['id']),
      name: _text(category['name']),
      displayTitle: _text(category['display_title']),
      displayTag: _text(category['display_tag']),
      selectorUrl: _text(json['selector_url']),
      bundleVersion: _integer(json['bundle_version']),
      contentHash: _text(json['content_hash']),
      archiveBytes: _integer(json['archive_bytes']),
      archiveSha256: _text(json['archive_sha256']),
      minimumRendererVersion: _integer(json['minimum_renderer_version']),
      quizCount: _integer(json['quiz_count']),
      questionCount: _integer(json['question_count']),
      bundleDownloadUrl: _text(json['bundle_download_url']),
      hasFullAccess: _map(json['access'])['has_full_access'] == true,
      freeQuizLimit: _integer(
        _map(json['access'])['free_quiz_limit'],
        fallback: 1,
      ),
      freeQuizDifficulty: _text(
        _map(json['access'])['free_quiz_difficulty'],
        fallback: 'beginner',
      ),
    );
    if (result.id.isEmpty ||
        result.bundleVersion < 1 ||
        result.archiveSha256.isEmpty ||
        result.bundleDownloadUrl.isEmpty) {
      throw const FormatException('Quiz category metadata is incomplete.');
    }
    return result;
  }

  QuizCategorySummary copyWith({String? cachedSelectorImagePath}) {
    return QuizCategorySummary(
      id: id,
      name: name,
      displayTitle: displayTitle,
      displayTag: displayTag,
      selectorUrl: selectorUrl,
      cachedSelectorImagePath:
          cachedSelectorImagePath ?? this.cachedSelectorImagePath,
      bundleVersion: bundleVersion,
      contentHash: contentHash,
      archiveBytes: archiveBytes,
      archiveSha256: archiveSha256,
      minimumRendererVersion: minimumRendererVersion,
      quizCount: quizCount,
      questionCount: questionCount,
      bundleDownloadUrl: bundleDownloadUrl,
      hasFullAccess: hasFullAccess,
      freeQuizLimit: freeQuizLimit,
      freeQuizDifficulty: freeQuizDifficulty,
    );
  }
}

class DownloadedQuizCategory {
  const DownloadedQuizCategory({
    required this.directory,
    required this.definition,
    required this.bundleVersion,
    required this.contentHash,
  });

  final Directory directory;
  final QuizCategoryDefinition definition;
  final int bundleVersion;
  final String contentHash;

  String resolvePath(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.startsWith('/') ||
        segments.any((segment) => segment.isEmpty || segment == '..')) {
      throw const FormatException('Unsafe quiz asset path.');
    }
    return '${directory.path}/$normalized';
  }
}

class QuizCategoryDefinition {
  const QuizCategoryDefinition({
    required this.id,
    required this.name,
    required this.displayTitle,
    this.displayTag = '',
    required this.presentation,
    required this.difficulties,
    required this.quizzes,
  });

  final String id;
  final String name;
  final String displayTitle;
  final String displayTag;
  final QuizPresentation presentation;
  final List<QuizDifficulty> difficulties;
  final List<QuizSetSummary> quizzes;

  factory QuizCategoryDefinition.fromJson(Map<String, dynamic> json) {
    final category = _map(json['category']);
    final result = QuizCategoryDefinition(
      id: _text(category['id']),
      name: _text(category['name']),
      displayTitle: _text(category['display_title']),
      displayTag: _text(category['display_tag']),
      presentation: QuizPresentation.fromJson(_map(json['presentation'])),
      difficulties: _maps(
        json['difficulties'],
      ).map(QuizDifficulty.fromJson).toList(growable: false),
      quizzes: _maps(
        json['quizzes'],
      ).map(QuizSetSummary.fromJson).toList(growable: false),
    );
    if (result.id.isEmpty || result.quizzes.isEmpty) {
      throw const FormatException('Quiz category bundle is incomplete.');
    }
    return result;
  }
}

class QuizPresentation {
  const QuizPresentation({
    required this.runtimeBackground,
    required this.settingsButton,
    required this.speakerOnButton,
    required this.speakerMutedButton,
    required this.progressStyle,
    this.audio,
  });

  final String runtimeBackground;
  final String settingsButton;
  final String speakerOnButton;
  final String speakerMutedButton;
  final String progressStyle;
  final QuizAudioPresentation? audio;

  factory QuizPresentation.fromJson(Map<String, dynamic> json) {
    final result = QuizPresentation(
      runtimeBackground: _text(json['runtime_background']),
      settingsButton: _text(json['settings_button']),
      speakerOnButton: _text(json['speaker_on_button']),
      speakerMutedButton: _text(json['speaker_muted_button']),
      progressStyle: _text(json['progress_style']),
      audio: _map(json['audio']).isEmpty
          ? null
          : QuizAudioPresentation.fromJson(_map(json['audio'])),
    );
    if (result.runtimeBackground.isEmpty || result.progressStyle.isEmpty) {
      throw const FormatException('Quiz presentation assets are incomplete.');
    }
    return result;
  }
}

class QuizAudioPresentation {
  const QuizAudioPresentation({
    required this.correctSfx,
    required this.incorrectSfx,
    required this.praiseClips,
  });

  final String correctSfx;
  final String incorrectSfx;
  final List<QuizPraiseClip> praiseClips;

  factory QuizAudioPresentation.fromJson(Map<String, dynamic> json) {
    final result = QuizAudioPresentation(
      correctSfx: _text(json['correct_sfx']),
      incorrectSfx: _text(json['incorrect_sfx']),
      praiseClips: _maps(
        json['praise_clips'],
      ).map(QuizPraiseClip.fromJson).toList(growable: false),
    );
    if (result.correctSfx.isEmpty ||
        result.incorrectSfx.isEmpty ||
        result.praiseClips.length < 5) {
      throw const FormatException('Quiz feedback audio is incomplete.');
    }
    return result;
  }
}

class QuizPraiseClip {
  const QuizPraiseClip({
    required this.id,
    required this.text,
    required this.file,
  });

  final String id;
  final String text;
  final String file;

  factory QuizPraiseClip.fromJson(Map<String, dynamic> json) {
    final result = QuizPraiseClip(
      id: _text(json['id']),
      text: _text(json['text']),
      file: _text(json['file']),
    );
    if (result.id.isEmpty || result.text.isEmpty || result.file.isEmpty) {
      throw const FormatException('Quiz praise clip is incomplete.');
    }
    return result;
  }
}

class QuizDifficulty {
  const QuizDifficulty({
    required this.id,
    required this.label,
    required this.quizCount,
  });

  final String id;
  final String label;
  final int quizCount;

  factory QuizDifficulty.fromJson(Map<String, dynamic> json) {
    return QuizDifficulty(
      id: _text(json['id']),
      label: _text(json['label']),
      quizCount: _integer(json['quiz_count']),
    );
  }
}

class QuizSetSummary {
  const QuizSetSummary({
    required this.quizId,
    required this.number,
    required this.difficulty,
    required this.title,
    required this.questionCount,
    required this.tileAsset,
    required this.questionsFile,
  });

  final String quizId;
  final int number;
  final String difficulty;
  final String title;
  final int questionCount;
  final String tileAsset;
  final String questionsFile;

  factory QuizSetSummary.fromJson(Map<String, dynamic> json) {
    final result = QuizSetSummary(
      quizId: _text(json['quiz_id']),
      number: _integer(json['number']),
      difficulty: _text(json['difficulty']),
      title: _text(json['title']),
      questionCount: _integer(json['question_count']),
      tileAsset: _text(json['tile_asset']),
      questionsFile: _text(json['questions_file']),
    );
    if (result.quizId.isEmpty ||
        result.questionCount != 10 ||
        result.tileAsset.isEmpty ||
        result.questionsFile.isEmpty) {
      throw const FormatException('Quiz set metadata is incomplete.');
    }
    return result;
  }
}

class VisualQuizDocument {
  const VisualQuizDocument({
    required this.setId,
    required this.category,
    required this.difficulty,
    required this.questions,
    required this.answerAssets,
  });

  final String setId;
  final String category;
  final String difficulty;
  final List<VisualQuizQuestion> questions;
  final Map<String, String> answerAssets;

  factory VisualQuizDocument.fromJson(Map<String, dynamic> json) {
    final answerAssets = _map(
      json['answer_assets'],
    ).map((key, value) => MapEntry(key, _text(value)));
    final result = VisualQuizDocument(
      setId: _text(json['set_id']),
      category: _text(json['category']),
      difficulty: _text(json['difficulty']),
      questions: _maps(
        json['questions'],
      ).map(VisualQuizQuestion.fromJson).toList(growable: false),
      answerAssets: Map.unmodifiable(answerAssets),
    );
    if (result.setId.isEmpty || result.questions.length != 10) {
      throw const FormatException('A visual quiz must contain ten questions.');
    }
    for (final question in result.questions) {
      for (final choice in question.choices) {
        if ((result.answerAssets[choice.animalKey] ?? '').isEmpty) {
          throw FormatException(
            'Missing answer image for ${choice.animalKey}.',
          );
        }
      }
    }
    return result;
  }
}

class VisualQuizQuestion {
  const VisualQuizQuestion({
    required this.questionId,
    required this.question,
    required this.choices,
    required this.correctChoiceId,
    required this.explanation,
    this.audio,
  });

  final String questionId;
  final String question;
  final List<VisualQuizChoice> choices;
  final String correctChoiceId;
  final String explanation;
  final QuizQuestionAudio? audio;

  int get correctIndex =>
      choices.indexWhere((choice) => choice.choiceId == correctChoiceId);

  factory VisualQuizQuestion.fromJson(Map<String, dynamic> json) {
    final result = VisualQuizQuestion(
      questionId: _text(json['question_id']),
      question: _text(json['question']),
      choices: _maps(
        json['choices'],
      ).map(VisualQuizChoice.fromJson).toList(growable: false),
      correctChoiceId: _text(json['correct_choice_id']),
      explanation: _text(json['explanation']),
      audio: _map(json['audio']).isEmpty
          ? null
          : QuizQuestionAudio.fromJson(_map(json['audio'])),
    );
    if (result.questionId.isEmpty ||
        result.question.isEmpty ||
        result.choices.length != 4 ||
        result.correctIndex < 0) {
      throw const FormatException('Visual quiz question is incomplete.');
    }
    return result;
  }
}

class QuizQuestionAudio {
  const QuizQuestionAudio({required this.question, required this.explanation});

  final String question;
  final String explanation;

  factory QuizQuestionAudio.fromJson(Map<String, dynamic> json) {
    final result = QuizQuestionAudio(
      question: _text(json['question']),
      explanation: _text(json['explanation']),
    );
    if (result.question.isEmpty || result.explanation.isEmpty) {
      throw const FormatException('Question narration audio is incomplete.');
    }
    return result;
  }
}

class VisualQuizChoice {
  const VisualQuizChoice({
    required this.choiceId,
    required this.animalKey,
    required this.label,
  });

  final String choiceId;
  final String animalKey;
  final String label;

  factory VisualQuizChoice.fromJson(Map<String, dynamic> json) {
    return VisualQuizChoice(
      choiceId: _text(json['choice_id']),
      animalKey: _text(json['animal_key']),
      label: _text(json['label']),
    );
  }
}

class QuizProgressStyle {
  const QuizProgressStyle({
    required this.questionCount,
    required this.markerDiameter,
    required this.markerBorder,
    required this.connectorHeight,
    required this.currentGlowBlur,
    required this.animationMilliseconds,
    required this.states,
    required this.unansweredConnector,
    required this.answeredConnector,
  });

  final int questionCount;
  final double markerDiameter;
  final double markerBorder;
  final double connectorHeight;
  final double currentGlowBlur;
  final int animationMilliseconds;
  final Map<String, QuizProgressStateStyle> states;
  final String unansweredConnector;
  final String answeredConnector;

  factory QuizProgressStyle.fromJson(Map<String, dynamic> json) {
    final geometry = _map(json['geometry']);
    final connectors = _map(json['connector']);
    final states = _map(json['states']).map(
      (key, value) =>
          MapEntry(key, QuizProgressStateStyle.fromJson(_map(value))),
    );
    return QuizProgressStyle(
      questionCount: _integer(json['question_count'], fallback: 10),
      markerDiameter: _decimal(geometry['marker_diameter_dp'], fallback: 32),
      markerBorder: _decimal(geometry['marker_border_dp'], fallback: 2),
      connectorHeight: _decimal(geometry['connector_height_dp'], fallback: 4),
      currentGlowBlur: _decimal(geometry['current_glow_blur_dp'], fallback: 10),
      animationMilliseconds: _integer(json['animation_ms'], fallback: 220),
      states: Map.unmodifiable(states),
      unansweredConnector: _text(connectors['unanswered'], fallback: '#78A94E'),
      answeredConnector: _text(connectors['answered'], fallback: '#D7B52E'),
    );
  }
}

class QuizProgressStateStyle {
  const QuizProgressStateStyle({
    required this.fill,
    required this.border,
    required this.text,
    this.glow,
  });

  final String fill;
  final String border;
  final String text;
  final String? glow;

  factory QuizProgressStateStyle.fromJson(Map<String, dynamic> json) {
    final glow = _text(json['glow']);
    return QuizProgressStateStyle(
      fill: _text(json['fill'], fallback: '#123F24'),
      border: _text(json['border'], fallback: '#A8D76F'),
      text: _text(json['text'], fallback: '#FFFFFF'),
      glow: glow.isEmpty ? null : glow,
    );
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> _maps(dynamic value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

String _text(dynamic value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

int _integer(dynamic value, {int fallback = 0}) {
  return value is num ? value.round() : int.tryParse('$value') ?? fallback;
}

double _decimal(dynamic value, {double fallback = 0}) {
  return value is num
      ? value.toDouble()
      : double.tryParse('$value') ?? fallback;
}
