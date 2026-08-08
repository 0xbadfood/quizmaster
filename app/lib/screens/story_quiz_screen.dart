import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/content_item.dart';
import '../models/quiz.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/background_scaffold.dart';

class StoryQuizScreen extends StatefulWidget {
  final ContentItem item;
  final StoryQuiz quiz;

  const StoryQuizScreen({super.key, required this.item, required this.quiz});

  @override
  State<StoryQuizScreen> createState() => _StoryQuizScreenState();
}

class _StoryQuizScreenState extends State<StoryQuizScreen> {
  int _questionIndex = 0;
  bool _saving = false;
  QuizAttemptResult? _result;
  final Map<String, int> _selectedIndexes = {};

  QuizQuestion get _question => widget.quiz.questions[_questionIndex];

  bool get _isLastQuestion =>
      _questionIndex >= widget.quiz.questions.length - 1;

  void _selectOption(int index) {
    final key = _question.key;
    if (_selectedIndexes.containsKey(key) || _saving) {
      return;
    }
    setState(() => _selectedIndexes[key] = index);
  }

  Future<void> _finishQuiz() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    final result = await context.read<AppState>().recordQuizAttempt(
      item: widget.item,
      quiz: widget.quiz,
      selectedIndexes: _selectedIndexes,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _result = result;
      _saving = false;
    });
  }

  void _goNext() {
    if (!_selectedIndexes.containsKey(_question.key)) {
      return;
    }
    if (_isLastQuestion) {
      _finishQuiz();
      return;
    }
    setState(() => _questionIndex += 1);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.quiz.questions.isEmpty) {
      return _buildEmptyQuiz();
    }

    final previousAttempt = context.watch<AppState>().quizAttemptFor(
      widget.item,
    );
    final completedResult = _result ?? previousAttempt;
    if (completedResult != null) {
      return _buildFinished(completedResult);
    }

    return BackgroundScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _CircleAction(
                  icon: Icons.close,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: SunshineColors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'Question ${_questionIndex + 1}/${widget.quiz.questions.length}',
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: sunshineCardDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          gradient: SunshineColors.purpleGradient,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.quiz,
                          color: SunshineColors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Story Quiz',
                          style: GoogleFonts.nunito(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: SunshineColors.darkText,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.item.displayTitle,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.purpleText,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _question.question,
                    style: GoogleFonts.nunito(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.darkText,
                      height: 1.22,
                    ),
                  ),
                  const SizedBox(height: 18),
                  ...List.generate(_question.options.length, (index) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _QuizOption(
                        label: _optionLabel(index),
                        text: _question.options[index],
                        selected: _selectedIndexes[_question.key] == index,
                        correct:
                            _selectedIndexes.containsKey(_question.key) &&
                            index == _question.correctIndex,
                        locked: _selectedIndexes.containsKey(_question.key),
                        onTap: () => _selectOption(index),
                      ),
                    );
                  }),
                  _buildFeedback(),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed:
                          _selectedIndexes.containsKey(_question.key) &&
                              !_saving
                          ? _goNext
                          : null,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isLastQuestion ? 'See My Score' : 'Next'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Only the first completed attempt is saved.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: SunshineColors.darkText.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyQuiz() {
    return BackgroundScaffold(
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(22),
          decoration: sunshineCardDecoration(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.quiz_outlined,
                color: SunshineColors.lavender,
                size: 46,
              ),
              const SizedBox(height: 12),
              Text(
                'Quiz not available yet.',
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: SunshineColors.darkText,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedback() {
    final selectedIndex = _selectedIndexes[_question.key];
    if (selectedIndex == null) {
      return const SizedBox(height: 8);
    }
    final isCorrect = selectedIndex == _question.correctIndex;
    final explanation = _question.explanation.trim();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (isCorrect ? SunshineColors.success : SunshineColors.error)
            .withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: (isCorrect ? SunshineColors.success : SunshineColors.error)
              .withValues(alpha: 0.32),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isCorrect
                ? 'You are correct!'
                : 'Correct answer: ${_question.correctOption}',
            style: GoogleFonts.nunito(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: isCorrect ? SunshineColors.success : SunshineColors.error,
            ),
          ),
          if (explanation.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              explanation,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: SunshineColors.darkText.withValues(alpha: 0.72),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFinished(QuizAttemptResult result) {
    final ratio = result.scoreRatio;
    final headline = ratio >= 0.8
        ? 'Excellent listening!'
        : ratio >= 0.5
        ? 'Good try!'
        : 'Nice effort!';
    return BackgroundScaffold(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(26),
            decoration: sunshineCardDecoration(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(
                    gradient: SunshineColors.pinkGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.emoji_events,
                    color: SunshineColors.white,
                    size: 46,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.darkText,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You scored ${result.correctCount} out of ${result.questionCount}.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.purpleText,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'This first score is saved for this story.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: SunshineColors.darkText.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 22),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to StoryVault'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _optionLabel(int index) {
    const labels = ['A', 'B', 'C', 'D', 'E', 'F'];
    if (index >= 0 && index < labels.length) {
      return labels[index];
    }
    return '${index + 1}';
  }
}

class _QuizOption extends StatelessWidget {
  final String label;
  final String text;
  final bool selected;
  final bool correct;
  final bool locked;
  final VoidCallback onTap;

  const _QuizOption({
    required this.label,
    required this.text,
    required this.selected,
    required this.correct,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color borderColor;
    final Color backgroundColor;
    final IconData? trailingIcon;
    if (correct) {
      borderColor = SunshineColors.success;
      backgroundColor = SunshineColors.success.withValues(alpha: 0.10);
      trailingIcon = Icons.check_circle;
    } else if (selected) {
      borderColor = SunshineColors.error;
      backgroundColor = SunshineColors.error.withValues(alpha: 0.08);
      trailingIcon = Icons.cancel;
    } else {
      borderColor = SunshineColors.deepBlue.withValues(alpha: 0.18);
      backgroundColor = SunshineColors.white;
      trailingIcon = null;
    }

    return GestureDetector(
      onTap: locked ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: SunshineColors.deepBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  label,
                  style: GoogleFonts.nunito(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.deepBlue,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: SunshineColors.darkText,
                ),
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 10),
              Icon(trailingIcon, color: borderColor, size: 22),
            ],
          ],
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleAction({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: SunshineColors.white.withValues(alpha: 0.24),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: SunshineColors.white, size: 20),
      ),
    );
  }
}
