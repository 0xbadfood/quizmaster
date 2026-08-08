import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _slug = TextEditingController();
  final _title = TextEditingController();
  final _tag = TextEditingController();
  final _description = TextEditingController();
  final _brief = TextEditingController();

  RangeValues _ages = const RangeValues(5, 10);
  int _targetQuestions = 150;
  int _questionBatchSize = 50;
  int _maxBatches = 6;
  int _setsPerDifficulty = 10;
  int _whisperRetries = 3;
  String _strictness = 'strict';
  String _imageQuality = 'medium';
  bool _forceMedia = false;
  bool _forceBackground = false;
  bool _refreshBackgroundPlan = false;
  bool _forceNewBundle = false;
  bool _slugEdited = false;
  bool _titleEdited = false;
  bool _tagEdited = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_deriveIdentity);
  }

  void _deriveIdentity() {
    final value = _name.text.trim();
    if (!_slugEdited) {
      _slug.text = value
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
    }
    if (!_titleEdited) {
      _title.text = value.isEmpty ? '' : '${value.toUpperCase()} QUIZ';
    }
    if (!_tagEdited) {
      _tag.text = value.length <= 12 ? value : value.substring(0, 12).trim();
    }
  }

  @override
  void dispose() {
    _name.removeListener(_deriveIdentity);
    _name.dispose();
    _slug.dispose();
    _title.dispose();
    _tag.dispose();
    _description.dispose();
    _brief.dispose();
    super.dispose();
  }

  String? _required(String? value, int minimum, String label) {
    final clean = value?.trim() ?? '';
    if (clean.length < minimum) {
      return '$label must contain at least $minimum characters.';
    }
    return null;
  }

  Future<void> _generate() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_formKey.currentState!.validate()) return;
    if (widget.controller.pipelineBusy) {
      widget.controller.selectScreen(2);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start category generation?'),
        content: Text(
          '${_name.text.trim()} will request up to $_targetQuestions beginner and '
          '$_targetQuestions intermediate questions, then generate sets, visuals, and audio. '
          'Only one category can run at a time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.startGeneration(
      metadata: {
        'name': _name.text.trim(),
        'slug': _slug.text.trim().isEmpty ? null : _slug.text.trim(),
        'display_title': _title.text.trim(),
        'display_tag': _tag.text.trim(),
        'description': _description.text.trim(),
        'editorial_brief': _brief.text.trim(),
        'age_min': _ages.start.round(),
        'age_max': _ages.end.round(),
      },
      settings: {
        'target_questions': _targetQuestions,
        'question_batch_size': _questionBatchSize,
        'max_question_batches': _maxBatches,
        'sets_per_difficulty': _setsPerDifficulty,
        'strictness': _strictness,
        'seed': 20260805,
        'image_quality': _imageQuality,
        'whisper_retries': _whisperRetries,
        'audio_duration_seconds': 12,
        'audio_duration_retries': null,
        'force_media': _forceMedia,
        'force_background': _forceBackground,
        'refresh_background_plan': _refreshBackgroundPlan,
        'force_new_bundle': _forceNewBundle,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return MobilePage(
      children: [
        const ScreenHeading(
          title: 'Create a category',
          subtitle:
              'Define the same production metadata used by the automated pipeline.',
        ),
        if (controller.errorMessage != null) ...[
          const SizedBox(height: 14),
          ErrorBanner(
            message: controller.errorMessage!,
            onDismiss: controller.clearError,
          ),
        ],
        const SizedBox(height: 18),
        _RoutingSummary(controller: controller),
        const SizedBox(height: 24),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeading(
                title: 'Category metadata',
                subtitle:
                    'Identity remains stable after the category is created.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                validator: (value) => _required(value, 2, 'Category name'),
                decoration: const InputDecoration(
                  labelText: 'Category name',
                  hintText: 'Indian Independence',
                  prefixIcon: Icon(Icons.category_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _slug,
                autocorrect: false,
                onChanged: (_) => _slugEdited = true,
                validator: (value) {
                  final clean = value?.trim() ?? '';
                  if (clean.isEmpty) return null;
                  if (!RegExp(r'^[a-z][a-z0-9-]{1,79}$').hasMatch(clean)) {
                    return 'Use lowercase letters, numbers, and hyphens.';
                  }
                  return null;
                },
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Category slug',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _title,
                onChanged: (_) => _titleEdited = true,
                validator: (value) => _required(value, 2, 'Display title'),
                decoration: const InputDecoration(
                  labelText: 'Display title',
                  hintText: 'INDIAN INDEPENDENCE QUIZ',
                  prefixIcon: Icon(Icons.title),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tag,
                onChanged: (_) => _tagEdited = true,
                maxLength: 12,
                inputFormatters: [LengthLimitingTextInputFormatter(12)],
                validator: (value) => _required(value, 1, 'Display tag'),
                decoration: const InputDecoration(
                  labelText: 'Display tag',
                  hintText: 'Freedom',
                  prefixIcon: Icon(Icons.label_outline),
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _description,
                minLines: 2,
                maxLines: 3,
                maxLength: 300,
                validator: (value) => _required(value, 10, 'Description'),
                decoration: const InputDecoration(
                  labelText: 'Description',
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(bottom: 34),
                    child: Icon(Icons.notes_outlined),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _brief,
                minLines: 4,
                maxLines: 7,
                maxLength: 1200,
                validator: (value) => _required(value, 20, 'Editorial brief'),
                decoration: const InputDecoration(
                  labelText: 'Editorial brief',
                  hintText:
                      'Scope, factual boundaries, tone, and visual answer guidance',
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(bottom: 78),
                    child: Icon(Icons.assignment_outlined),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.child_care_outlined,
                            size: 20,
                            color: AppColors.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Audience age',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          StatusPill(
                            label:
                                '${_ages.start.round()}–${_ages.end.round()} years',
                          ),
                        ],
                      ),
                      RangeSlider(
                        values: _ages,
                        min: 3,
                        max: 15,
                        divisions: 12,
                        labels: RangeLabels(
                          _ages.start.round().toString(),
                          _ages.end.round().toString(),
                        ),
                        onChanged: (value) => setState(() => _ages = value),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _AdvancedSettings(
                targetQuestions: _targetQuestions,
                questionBatchSize: _questionBatchSize,
                maxBatches: _maxBatches,
                setsPerDifficulty: _setsPerDifficulty,
                whisperRetries: _whisperRetries,
                strictness: _strictness,
                imageQuality: _imageQuality,
                forceMedia: _forceMedia,
                forceBackground: _forceBackground,
                refreshBackgroundPlan: _refreshBackgroundPlan,
                forceNewBundle: _forceNewBundle,
                onChanged: (values) => setState(() {
                  _targetQuestions = values.targetQuestions;
                  _questionBatchSize = values.questionBatchSize;
                  _maxBatches = values.maxBatches;
                  _setsPerDifficulty = values.setsPerDifficulty;
                  _whisperRetries = values.whisperRetries;
                  _strictness = values.strictness;
                  _imageQuality = values.imageQuality;
                  _forceMedia = values.forceMedia;
                  _forceBackground = values.forceBackground;
                  _refreshBackgroundPlan = values.refreshBackgroundPlan;
                  _forceNewBundle = values.forceNewBundle;
                }),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed:
                    controller.startingPipeline || !controller.routingReady
                    ? null
                    : _generate,
                icon: controller.startingPipeline
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.rocket_launch_outlined),
                label: const Text('Generate category'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoutingSummary extends StatelessWidget {
  const _RoutingSummary({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final ready = controller.routingReady;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              ready ? Icons.check_circle_outline : Icons.tune_outlined,
              color: ready ? AppColors.green : AppColors.amber,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready
                        ? 'Pipeline routing ready'
                        : 'Pipeline routing incomplete',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    ready
                        ? '${pipelineRoles.length} production roles configured'
                        : 'Choose providers on the Setup screen',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => controller.selectScreen(0),
              child: const Text('Review'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedValues {
  const _AdvancedValues({
    required this.targetQuestions,
    required this.questionBatchSize,
    required this.maxBatches,
    required this.setsPerDifficulty,
    required this.whisperRetries,
    required this.strictness,
    required this.imageQuality,
    required this.forceMedia,
    required this.forceBackground,
    required this.refreshBackgroundPlan,
    required this.forceNewBundle,
  });

  final int targetQuestions;
  final int questionBatchSize;
  final int maxBatches;
  final int setsPerDifficulty;
  final int whisperRetries;
  final String strictness;
  final String imageQuality;
  final bool forceMedia;
  final bool forceBackground;
  final bool refreshBackgroundPlan;
  final bool forceNewBundle;
}

class _AdvancedSettings extends StatelessWidget {
  const _AdvancedSettings({
    required this.targetQuestions,
    required this.questionBatchSize,
    required this.maxBatches,
    required this.setsPerDifficulty,
    required this.whisperRetries,
    required this.strictness,
    required this.imageQuality,
    required this.forceMedia,
    required this.forceBackground,
    required this.refreshBackgroundPlan,
    required this.forceNewBundle,
    required this.onChanged,
  });

  final int targetQuestions;
  final int questionBatchSize;
  final int maxBatches;
  final int setsPerDifficulty;
  final int whisperRetries;
  final String strictness;
  final String imageQuality;
  final bool forceMedia;
  final bool forceBackground;
  final bool refreshBackgroundPlan;
  final bool forceNewBundle;
  final ValueChanged<_AdvancedValues> onChanged;

  void _emit({
    int? target,
    int? batch,
    int? batches,
    int? sets,
    int? repairs,
    String? strict,
    String? quality,
    bool? media,
    bool? background,
    bool? refresh,
    bool? bundle,
  }) => onChanged(
    _AdvancedValues(
      targetQuestions: target ?? targetQuestions,
      questionBatchSize: batch ?? questionBatchSize,
      maxBatches: batches ?? maxBatches,
      setsPerDifficulty: sets ?? setsPerDifficulty,
      whisperRetries: repairs ?? whisperRetries,
      strictness: strict ?? strictness,
      imageQuality: quality ?? imageQuality,
      forceMedia: media ?? forceMedia,
      forceBackground: background ?? forceBackground,
      refreshBackgroundPlan: refresh ?? refreshBackgroundPlan,
      forceNewBundle: bundle ?? forceNewBundle,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.tune_outlined),
        title: const Text('Advanced generation settings'),
        subtitle: const Text('Defaults match the production CLI'),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          _NumberRow(
            label: 'Questions per difficulty',
            value: targetQuestions,
            min: 10,
            max: 150,
            step: 10,
            onChanged: (value) => _emit(target: value),
          ),
          _NumberRow(
            label: 'Question batch size',
            value: questionBatchSize,
            min: 10,
            max: 50,
            step: 10,
            onChanged: (value) => _emit(batch: value),
          ),
          _NumberRow(
            label: 'Maximum batches',
            value: maxBatches,
            min: 1,
            max: 6,
            onChanged: (value) => _emit(batches: value),
          ),
          _NumberRow(
            label: 'Sets per difficulty',
            value: setsPerDifficulty,
            min: 1,
            max: 10,
            onChanged: (value) => _emit(sets: value),
          ),
          _NumberRow(
            label: 'Whisper repair attempts',
            value: whisperRetries,
            min: 0,
            max: 4,
            onChanged: (value) => _emit(repairs: value),
          ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: strictness,
                  decoration: const InputDecoration(
                    labelText: 'Set strictness',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'strict', child: Text('Strict')),
                    DropdownMenuItem(
                      value: 'balanced',
                      child: Text('Balanced'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) _emit(strict: value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: imageQuality,
                  decoration: const InputDecoration(labelText: 'Image quality'),
                  items: const [
                    DropdownMenuItem(value: 'low', child: Text('Low')),
                    DropdownMenuItem(value: 'medium', child: Text('Medium')),
                    DropdownMenuItem(value: 'high', child: Text('High')),
                  ],
                  onChanged: (value) {
                    if (value != null) _emit(quality: value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Regenerate media'),
            value: forceMedia,
            onChanged: (value) => _emit(media: value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Rerender background'),
            value: forceBackground,
            onChanged: (value) => _emit(background: value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Request a new background plan'),
            value: refreshBackgroundPlan,
            onChanged: (value) => _emit(refresh: value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Force a new bundle version'),
            value: forceNewBundle,
            onChanged: (value) => _emit(bundle: value),
          ),
        ],
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            onPressed: value > min
                ? () => onChanged((value - step).clamp(min, max).toInt())
                : null,
            tooltip: 'Decrease $label',
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 38,
            child: Text(
              value.toString(),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: value < max
                ? () => onChanged((value + step).clamp(min, max).toInt())
                : null,
            tooltip: 'Increase $label',
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}
