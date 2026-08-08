import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/visual_quiz_progress_repository.dart';
import '../models/quiz_bundle.dart';
import '../models/visual_quiz_progress.dart';

typedef QuizAnswerAudioPlayer =
    Future<void> Function(bool isCorrect, VisualQuizQuestion question);

class VisualQuizScreen extends StatefulWidget {
  const VisualQuizScreen({
    required this.category,
    required this.summary,
    required this.quiz,
    required this.progressStyle,
    required this.progressStore,
    this.initialAttempt,
    this.onOpenSettings,
    this.answerAudioPlayerOverride,
    this.waitForExplanationAudio = true,
    super.key,
  });

  final DownloadedQuizCategory category;
  final QuizSetSummary summary;
  final VisualQuizDocument quiz;
  final QuizProgressStyle progressStyle;
  final VisualQuizProgressStore progressStore;
  final VisualQuizAttempt? initialAttempt;
  final VoidCallback? onOpenSettings;
  final bool waitForExplanationAudio;
  @visibleForTesting
  final QuizAnswerAudioPlayer? answerAudioPlayerOverride;

  @override
  State<VisualQuizScreen> createState() => _VisualQuizScreenState();
}

class _VisualQuizScreenState extends State<VisualQuizScreen> {
  static const _correctSfxAsset = 'audio/quiz_correct_sfx.mp3';
  static const _incorrectSfxAsset = 'audio/quiz_incorrect_sfx.mp3';

  late List<int?> _answers;
  late List<List<int>> _choiceOrders;
  final Random _random = Random();
  final AudioPlayer _feedbackPlayer = AudioPlayer();
  final AudioPlayer _narrationPlayer = AudioPlayer();
  late final Future<void> _audioReady;
  int _questionIndex = 0;
  int _audioSequence = 0;
  bool _soundEnabled = true;
  bool _finished = false;
  Future<void> _saveChain = Future<void>.value();
  VisualQuizAttempt? _latestAttempt;

  VisualQuizQuestion get _question => widget.quiz.questions[_questionIndex];
  int? get _selectedIndex => _answers[_questionIndex];
  bool get _answered => _selectedIndex != null;
  bool get _isLast => _questionIndex == widget.quiz.questions.length - 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAttempt;
    if (_canResume(initial)) {
      _latestAttempt = initial;
      _answers = List<int?>.from(initial!.answers);
      _choiceOrders = initial.choiceOrders
          .map((order) => List<int>.from(order))
          .toList(growable: false);
      _questionIndex = initial.currentQuestionIndex.clamp(
        0,
        widget.quiz.questions.length - 1,
      );
    } else {
      _answers = List<int?>.filled(widget.quiz.questions.length, null);
      _choiceOrders = _createChoiceOrders();
    }
    _audioReady = _configureAudioPlayers();
    _queueProgressSave();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_answered) {
        unawaited(_showAnswerResult());
      } else {
        unawaited(_playQuestionNarration());
      }
    });
  }

  bool _canResume(VisualQuizAttempt? attempt) {
    if (attempt == null ||
        attempt.status != VisualQuizRunStatus.inProgress ||
        attempt.categoryId != widget.category.definition.id ||
        attempt.quizId != widget.summary.quizId ||
        attempt.answers.length != widget.quiz.questions.length ||
        attempt.choiceOrders.length != widget.quiz.questions.length) {
      return false;
    }
    for (
      var questionIndex = 0;
      questionIndex < widget.quiz.questions.length;
      questionIndex += 1
    ) {
      final choiceCount = widget.quiz.questions[questionIndex].choices.length;
      final order = attempt.choiceOrders[questionIndex];
      if (order.length != choiceCount ||
          order.toSet().length != choiceCount ||
          order.any((index) => index < 0 || index >= choiceCount)) {
        return false;
      }
      final answer = attempt.answers[questionIndex];
      if (answer != null && (answer < 0 || answer >= choiceCount)) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _audioSequence += 1;
    unawaited(_feedbackPlayer.dispose());
    unawaited(_narrationPlayer.dispose());
    super.dispose();
  }

  Future<void> _configureAudioPlayers() async {
    final context = AudioContext(
      iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
    );
    await Future.wait([
      _feedbackPlayer.setReleaseMode(ReleaseMode.stop),
      _narrationPlayer.setReleaseMode(ReleaseMode.stop),
      _feedbackPlayer.setAudioContext(context),
      _narrationPlayer.setAudioContext(context),
    ]);
  }

  List<List<int>> _createChoiceOrders({List<List<int>>? previous}) {
    return List.generate(widget.quiz.questions.length, (questionIndex) {
      final order = List<int>.generate(
        widget.quiz.questions[questionIndex].choices.length,
        (index) => index,
      )..shuffle(_random);
      final previousOrder = previous?[questionIndex];
      if (previousOrder != null &&
          order.length > 1 &&
          listEquals(order, previousOrder)) {
        order.add(order.removeAt(0));
      }
      return order;
    });
  }

  Future<void> _selectAnswer(int index) async {
    if (_answered) {
      return;
    }
    if (_soundEnabled && _question.audio == null) {
      SystemSound.play(SystemSoundType.click);
    }
    final question = _question;
    setState(() => _answers[_questionIndex] = index);
    _queueProgressSave();
    await _showAnswerResult(question: question);
  }

  Future<void> _showAnswerResult({VisualQuizQuestion? question}) async {
    if (!mounted || !_answered) {
      return;
    }
    final answeredQuestion = question ?? _question;
    final selectedIndex = _selectedIndex!;
    final isLast = _isLast;
    final isCorrect = selectedIndex == answeredQuestion.correctIndex;
    final audioCompletion = widget.answerAudioPlayerOverride != null
        ? widget.answerAudioPlayerOverride!(isCorrect, answeredQuestion)
        : _playAnswerResultSafely(isCorrect, answeredQuestion);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _AnswerResultDialog(
        question: answeredQuestion,
        selectedIndex: selectedIndex,
        actionLabel: isLast ? 'See My Score' : 'Next Question',
        audioCompletion: audioCompletion,
        waitForAudioCompletion: widget.waitForExplanationAudio,
        onContinue: () {
          Navigator.of(dialogContext).pop();
          unawaited(_continue());
        },
      ),
    );
  }

  Future<void> _continue() async {
    if (!_answered) {
      return;
    }
    if (_isLast) {
      _cancelAudio();
      await _saveChain;
      final correct = _correctAnswerCount;
      try {
        _latestAttempt = await widget.progressStore.completeAttempt(
          _snapshotAttempt(),
          correctCount: correct,
          questionCount: widget.quiz.questions.length,
        );
      } catch (error, stackTrace) {
        debugPrint('Could not save completed quiz: $error\n$stackTrace');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not save your score. Please try again.'),
            ),
          );
          await _showAnswerResult(question: _question);
        }
        return;
      }
      if (mounted) {
        setState(() => _finished = true);
      }
      return;
    }
    _cancelAudio();
    setState(() => _questionIndex += 1);
    _queueProgressSave();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_playQuestionNarration());
    });
  }

  Future<void> _restart() async {
    _cancelAudio();
    final previousOrders = _choiceOrders;
    setState(() {
      _answers = List<int?>.filled(widget.quiz.questions.length, null);
      _choiceOrders = _createChoiceOrders(previous: previousOrders);
      _questionIndex = 0;
      _finished = false;
    });
    try {
      _latestAttempt = await widget.progressStore.startRetake(
        _snapshotAttempt(),
      );
    } catch (error, stackTrace) {
      debugPrint('Could not save quiz retake: $error\n$stackTrace');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_playQuestionNarration());
    });
  }

  int get _correctAnswerCount =>
      List.generate(widget.quiz.questions.length, (index) {
        return _answers[index] == widget.quiz.questions[index].correctIndex;
      }).where((value) => value).length;

  VisualQuizAttempt _snapshotAttempt() {
    return VisualQuizAttempt(
      categoryId: widget.category.definition.id,
      quizId: widget.summary.quizId,
      status: VisualQuizRunStatus.inProgress,
      currentQuestionIndex: _questionIndex,
      answers: List<int?>.from(_answers),
      choiceOrders: _choiceOrders
          .map((order) => List<int>.from(order))
          .toList(growable: false),
      firstCorrectCount: _latestAttempt?.firstCorrectCount,
      firstQuestionCount: _latestAttempt?.firstQuestionCount,
      firstCompletedAtMillis: _latestAttempt?.firstCompletedAtMillis,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _queueProgressSave() {
    final snapshot = _snapshotAttempt();
    _saveChain = _saveChain.then((_) async {
      try {
        _latestAttempt = await widget.progressStore.saveProgress(snapshot);
      } catch (error, stackTrace) {
        debugPrint('Could not save quiz progress: $error\n$stackTrace');
      }
    });
  }

  void _cancelAudio() {
    _audioSequence += 1;
    unawaited(_feedbackPlayer.stop());
    unawaited(_narrationPlayer.stop());
  }

  Future<void> _playQuestionNarration() async {
    final audio = _question.audio;
    if (audio == null) {
      return;
    }
    final sequence = await _beginAudioSequence();
    await _playClip(
      player: _narrationPlayer,
      source: DeviceFileSource(widget.category.resolvePath(audio.question)),
      sequence: sequence,
    );
  }

  Future<void> _playAnswerResult(
    bool isCorrect,
    VisualQuizQuestion question,
  ) async {
    final questionAudio = question.audio;
    if (questionAudio == null) {
      return;
    }
    final sequence = await _beginAudioSequence();
    final sfxPlayed = await _playClip(
      player: _feedbackPlayer,
      source: AssetSource(isCorrect ? _correctSfxAsset : _incorrectSfxAsset),
      sequence: sequence,
    );
    if (!sfxPlayed) {
      return;
    }
    await _playClip(
      player: _narrationPlayer,
      source: DeviceFileSource(
        widget.category.resolvePath(questionAudio.explanation),
      ),
      sequence: sequence,
    );
  }

  Future<void> _playAnswerResultSafely(
    bool isCorrect,
    VisualQuizQuestion question,
  ) async {
    try {
      await _playAnswerResult(isCorrect, question);
    } catch (error, stackTrace) {
      debugPrint('Quiz answer audio sequence failed: $error\n$stackTrace');
    }
  }

  Future<int> _beginAudioSequence() async {
    final sequence = ++_audioSequence;
    await _audioReady;
    await Future.wait([_feedbackPlayer.stop(), _narrationPlayer.stop()]);
    return sequence;
  }

  Future<bool> _playClip({
    required AudioPlayer player,
    required Source source,
    required int sequence,
  }) async {
    if (!mounted || !_soundEnabled || sequence != _audioSequence) {
      return false;
    }
    try {
      final completed = player.onPlayerComplete.first;
      await player.play(source);
      await completed.timeout(const Duration(seconds: 90));
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return mounted && _soundEnabled && sequence == _audioSequence;
    } on TimeoutException {
      await player.stop();
      return false;
    } catch (error, stackTrace) {
      debugPrint('Quiz audio playback failed: $error\n$stackTrace');
      return false;
    }
  }

  void _toggleSound() {
    final enabled = !_soundEnabled;
    setState(() => _soundEnabled = enabled);
    if (!enabled) {
      _cancelAudio();
    } else if (!_answered && !_finished) {
      unawaited(_playQuestionNarration());
    }
  }

  Future<void> _leaveQuiz() async {
    _cancelAudio();
    await _saveChain;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.category.resolvePath(
      widget.category.definition.presentation.runtimeBackground,
    );
    return Scaffold(
      backgroundColor: const Color(0xFF052B22),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.file(File(background), fit: BoxFit.cover),
          ),
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.08)),
          ),
          SafeArea(
            child: _finished ? _buildFinished() : _buildQuestionRuntime(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionRuntime() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final topClearance = (constraints.maxHeight * 0.18).clamp(116.0, 190.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTopControls(),
                  SizedBox(height: topClearance),
                  _QuizProgress(
                    currentIndex: _questionIndex,
                    answers: _answers,
                    questions: widget.quiz.questions,
                    style: widget.progressStyle,
                  ),
                  const SizedBox(height: 12),
                  _QuestionBox(question: _question.question),
                  const SizedBox(height: 12),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.94,
                        ),
                    itemCount: _question.choices.length,
                    itemBuilder: (context, index) {
                      final choiceIndex = _choiceOrders[_questionIndex][index];
                      final choice = _question.choices[choiceIndex];
                      final imagePath =
                          widget.quiz.answerAssets[choice.animalKey]!;
                      return _AnswerImageTile(
                        choice: choice,
                        imageFile: File(widget.category.resolvePath(imagePath)),
                        selected: _selectedIndex == choiceIndex,
                        correct:
                            _answered && choiceIndex == _question.correctIndex,
                        locked: _answered,
                        onTap: () => _selectAnswer(choiceIndex),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopControls() {
    final presentation = widget.category.definition.presentation;
    return Row(
      children: [
        _RoundControl(
          tooltip: 'Back',
          onTap: _leaveQuiz,
          child: const Icon(
            Icons.arrow_back_rounded,
            color: Colors.white,
            size: 28,
          ),
        ),
        Expanded(
          child: Text(
            'Question ${_questionIndex + 1} of ${widget.quiz.questions.length}',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: GoogleFonts.nunito(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w900,
              shadows: const [Shadow(color: Color(0xCC052B22), blurRadius: 5)],
            ),
          ),
        ),
        _RoundControl(
          tooltip: _soundEnabled ? 'Mute sound' : 'Turn on sound',
          onTap: _toggleSound,
          child: Image.file(
            File(
              widget.category.resolvePath(
                _soundEnabled
                    ? presentation.speakerOnButton
                    : presentation.speakerMutedButton,
              ),
            ),
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(width: 8),
        _RoundControl(
          tooltip: 'Settings',
          onTap: widget.onOpenSettings ?? () {},
          child: Image.file(
            File(widget.category.resolvePath(presentation.settingsButton)),
            fit: BoxFit.contain,
          ),
        ),
      ],
    );
  }

  Widget _buildFinished() {
    final correct = _correctAnswerCount;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _RoundControl(
                      tooltip: 'Back',
                      onTap: _leaveQuiz,
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: (constraints.maxHeight * 0.28).clamp(180.0, 290.0),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDF6D8).withValues(alpha: 0.97),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFF5B91B),
                        width: 3,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x77000000),
                          blurRadius: 14,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.emoji_events_rounded,
                          color: Color(0xFFE69B14),
                          size: 64,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          correct >= 8
                              ? 'Jungle Expert!'
                              : correct >= 5
                              ? 'Great Exploring!'
                              : 'Good Adventure!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.nunito(
                            color: const Color(0xFF17482D),
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$correct out of ${widget.quiz.questions.length}',
                          style: GoogleFonts.nunito(
                            color: const Color(0xFF27663D),
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _ContinueButton(
                          label: 'Play Again',
                          onPressed: _restart,
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _leaveQuiz,
                          icon: const Icon(Icons.grid_view_rounded),
                          label: const Text('Back to Quizzes'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuestionBox extends StatelessWidget {
  const _QuestionBox({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 78),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF6D8).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF3B51B), width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        question,
        textAlign: TextAlign.center,
        style: GoogleFonts.nunito(
          color: const Color(0xFF153D28),
          fontSize: 20,
          height: 1.18,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _AnswerImageTile extends StatelessWidget {
  const _AnswerImageTile({
    required this.choice,
    required this.imageFile,
    required this.selected,
    required this.correct,
    required this.locked,
    required this.onTap,
  });

  final VisualQuizChoice choice;
  final File imageFile;
  final bool selected;
  final bool correct;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final incorrect = locked && selected && !correct;
    final borderColor = correct
        ? const Color(0xFF46B95F)
        : incorrect
        ? const Color(0xFFE1534C)
        : const Color(0xFFF2D06A);
    return Semantics(
      button: true,
      label: choice.label,
      selected: selected,
      child: Material(
        color: const Color(0xFFFDF6D8),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        elevation: selected || correct ? 8 : 3,
        child: InkWell(
          onTap: locked ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(imageFile, fit: BoxFit.cover),
                      if (correct || incorrect)
                        Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            margin: const EdgeInsets.all(7),
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: correct
                                  ? const Color(0xFF36A852)
                                  : const Color(0xFFD94B4B),
                              shape: BoxShape.circle,
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x66000000),
                                  blurRadius: 5,
                                ),
                              ],
                            ),
                            child: Icon(
                              correct
                                  ? Icons.check_rounded
                                  : Icons.close_rounded,
                              color: Colors.white,
                              size: 23,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: Center(
                    child: Text(
                      choice.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.nunito(
                        color: const Color(0xFF153D28),
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnswerResultDialog extends StatelessWidget {
  const _AnswerResultDialog({
    required this.question,
    required this.selectedIndex,
    required this.actionLabel,
    required this.audioCompletion,
    required this.waitForAudioCompletion,
    required this.onContinue,
  });

  final VisualQuizQuestion question;
  final int selectedIndex;
  final String actionLabel;
  final Future<void> audioCompletion;
  final bool waitForAudioCompletion;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final answer = question.choices[question.correctIndex].label;
    final isCorrect = selectedIndex == question.correctIndex;
    final accent = isCorrect
        ? const Color(0xFF36A852)
        : const Color(0xFFE1534C);
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: const Color(0xFFFDF6D8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isCorrect
                      ? Icons.check_circle_rounded
                      : Icons.lightbulb_rounded,
                  color: accent,
                  size: 50,
                ),
                const SizedBox(height: 8),
                Text(
                  isCorrect ? 'Correct!' : 'Good Try!',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    color: const Color(0xFF17482D),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Correct answer: $answer',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    color: const Color(0xFF216D35),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      question.explanation,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.nunito(
                        color: const Color(0xFF254A31),
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: waitForAudioCompletion
                      ? FutureBuilder<void>(
                          future: audioCompletion,
                          builder: (context, snapshot) {
                            final audioFinished =
                                snapshot.connectionState ==
                                ConnectionState.done;
                            return audioFinished
                                ? _ContinueButton(
                                    key: const Key('quiz-answer-continue'),
                                    label: actionLabel,
                                    onPressed: onContinue,
                                  )
                                : const Center(
                                    child: SizedBox(
                                      key: Key('quiz-answer-audio-waiting'),
                                      width: 26,
                                      height: 26,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: Color(0xFFE6A414),
                                      ),
                                    ),
                                  );
                          },
                        )
                      : _ContinueButton(
                          key: const Key('quiz-answer-continue'),
                          label: actionLabel,
                          onPressed: onContinue,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinueButton extends StatelessWidget {
  const _ContinueButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFE6A414),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFFFE48C), width: 2),
          ),
        ),
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(
          label,
          style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFF0B4C2B).withValues(alpha: 0.88),
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(width: 46, height: 46, child: Center(child: child)),
        ),
      ),
    );
  }
}

class _QuizProgress extends StatelessWidget {
  const _QuizProgress({
    required this.currentIndex,
    required this.answers,
    required this.questions,
    required this.style,
  });

  final int currentIndex;
  final List<int?> answers;
  final List<VisualQuizQuestion> questions;
  final QuizProgressStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = style.markerDiameter.clamp(
          24.0,
          (constraints.maxWidth - 36) / answers.length,
        );
        return Row(
          children: List.generate(answers.length * 2 - 1, (slot) {
            if (slot.isOdd) {
              final answered = answers[slot ~/ 2] != null;
              return Expanded(
                child: AnimatedContainer(
                  duration: Duration(milliseconds: style.animationMilliseconds),
                  height: style.connectorHeight,
                  color: _hexColor(
                    answered
                        ? style.answeredConnector
                        : style.unansweredConnector,
                  ),
                ),
              );
            }
            final index = slot ~/ 2;
            final answer = answers[index];
            final stateName = answer == null
                ? index == currentIndex
                      ? 'current'
                      : 'unanswered'
                : answer == questions[index].correctIndex
                ? 'correct'
                : 'incorrect';
            final state =
                style.states[stateName] ??
                style.states['unanswered'] ??
                const QuizProgressStateStyle(
                  fill: '#123F24',
                  border: '#A8D76F',
                  text: '#FFFFFF',
                );
            return AnimatedContainer(
              duration: Duration(milliseconds: style.animationMilliseconds),
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: _hexColor(state.fill),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _hexColor(state.border),
                  width: style.markerBorder,
                ),
                boxShadow: state.glow == null
                    ? null
                    : [
                        BoxShadow(
                          color: _hexColor(state.glow!).withValues(alpha: 0.78),
                          blurRadius: style.currentGlowBlur,
                        ),
                      ],
              ),
              alignment: Alignment.center,
              child: Text(
                '${index + 1}',
                style: GoogleFonts.nunito(
                  color: _hexColor(state.text),
                  fontSize: diameter <= 26 ? 10 : 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

Color _hexColor(String source) {
  final normalized = source.replaceFirst('#', '');
  final value = int.tryParse(normalized, radix: 16);
  if (value == null) {
    return Colors.white;
  }
  return Color(normalized.length == 6 ? 0xFF000000 | value : value);
}
