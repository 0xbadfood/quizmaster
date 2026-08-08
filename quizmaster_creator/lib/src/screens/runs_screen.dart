import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class RunsScreen extends StatefulWidget {
  const RunsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<RunsScreen> createState() => _RunsScreenState();
}

class _RunsScreenState extends State<RunsScreen> {
  String _filter = 'all';

  List<Map<String, dynamic>> get _filteredBundles {
    if (_filter == 'all') return widget.controller.bundles;
    return widget.controller.bundles
        .where((item) => item['status'] == _filter)
        .toList();
  }

  Future<void> _confirmDeploy(
    BuildContext context,
    Map<String, dynamic> bundle,
  ) async {
    final category = bundle['category'] as Map? ?? const {};
    final latest = bundle['latest'] as Map? ?? const {};
    final slug = category['slug']?.toString() ?? '';
    final version = int.tryParse(latest['bundle_version']?.toString() ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deploy this bundle?'),
        content: Text(
          '${category['name'] ?? slug} version ${version ?? 'latest'} will become the active '
          'version served to Quizmaster clients.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.publish),
            label: const Text('Deploy'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.deployBundle(slug, version: version);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final job = controller.currentJob;
    return RefreshIndicator(
      onRefresh: controller.refreshStatus,
      child: MobilePage(
        children: [
          ScreenHeading(
            title: 'Production runs',
            subtitle:
                'Return to active work, review completed bundles, and deploy explicitly.',
            trailing: IconButton.filledTonal(
              onPressed: () => controller.refreshStatus(),
              tooltip: 'Refresh status',
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(
              message: controller.errorMessage!,
              onDismiss: controller.clearError,
            ),
          ],
          const SizedBox(height: 18),
          if (job != null)
            _CurrentRunCard(job: job, locked: controller.pipelineBusy)
          else
            EmptyState(
              icon: Icons.schedule_outlined,
              title: 'No generation selected',
              message: controller.pipelineBusy
                  ? 'A server-side generation is running. Pull to refresh its status.'
                  : 'Start a category or select a past generation below.',
              action: controller.pipelineBusy
                  ? null
                  : FilledButton.icon(
                      onPressed: () => controller.selectScreen(0),
                      icon: const Icon(Icons.add),
                      label: const Text('New generation'),
                    ),
            ),
          const SizedBox(height: 24),
          SectionHeading(
            title: 'Bundles',
            subtitle: '${controller.bundles.length} category workspaces',
            action: controller.pipelineBusy
                ? const StatusPill(
                    label: 'Pipeline locked',
                    tone: StatusTone.warning,
                  )
                : null,
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final item in const [
                  ('all', 'All'),
                  ('deployable', 'Ready'),
                  ('deployed', 'Deployed'),
                  ('not_built', 'Not built'),
                ]) ...[
                  FilterChip(
                    label: Text(item.$2),
                    selected: _filter == item.$1,
                    onSelected: (_) => setState(() => _filter = item.$1),
                  ),
                  const SizedBox(width: 7),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_filteredBundles.isEmpty)
            const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Nothing in this view',
              message: 'Choose another status filter.',
            )
          else
            for (final bundle in _filteredBundles) ...[
              _BundleCard(
                bundle: bundle,
                pipelineBusy: controller.pipelineBusy,
                onDeploy: () => _confirmDeploy(context, bundle),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 18),
          SectionHeading(
            title: 'Generation history',
            subtitle: '${controller.recentJobs.length} recent pipeline runs',
          ),
          const SizedBox(height: 10),
          if (controller.recentJobs.isEmpty)
            const EmptyState(
              icon: Icons.history,
              title: 'No recorded runs',
              message:
                  'Accepted generations will remain available after the app is closed.',
            )
          else
            for (final past in controller.recentJobs.take(20)) ...[
              _HistoryRow(
                job: past,
                selected: past['id'] == controller.currentJob?['id'],
                onTap: () => controller.selectJob(past['id'].toString()),
              ),
              const SizedBox(height: 8),
            ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: controller.pipelineBusy
                ? null
                : () => controller.selectScreen(0),
            icon: const Icon(Icons.add),
            label: const Text('Configure a new run'),
          ),
        ],
      ),
    );
  }
}

class _CurrentRunCard extends StatelessWidget {
  const _CurrentRunCard({required this.job, required this.locked});

  final Map<String, dynamic> job;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final status = job['status']?.toString() ?? 'unknown';
    final progress = (job['progress'] as num?)?.toDouble() ?? 0;
    final contextData = job['context'] as Map? ?? const {};
    final result = job['result'] as Map? ?? const {};
    final category =
        contextData['category_name']?.toString() ??
        result['category_slug']?.toString() ??
        'Category generation';
    final phases = _phaseRows(job['checkpoint'] as Map?);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _tone(status).$1,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(_statusIcon(status), color: _tone(status).$2),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        job['message']?.toString() ?? status,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                StatusPill(label: status, tone: _statusTone(status)),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: status == 'complete' ? 1 : progress.clamp(0, 1),
                backgroundColor: AppColors.line,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              status == 'complete'
                  ? '100% complete'
                  : '${(progress * 100).round()}% complete',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (phases.isNotEmpty) ...[
              const Divider(height: 24),
              for (var index = 0; index < phases.length; index++)
                _PhaseRow(
                  phase: phases[index],
                  last: index == phases.length - 1,
                ),
            ],
          ],
        ),
      ),
    );
  }

  static List<_Phase> _phaseRows(Map? checkpoint) {
    final phases = checkpoint?['phases'] as Map?;
    if (phases == null) return [];
    final output = <_Phase>[];
    void add(String key, String label, {String? detail}) {
      final value = phases[key] as Map?;
      if (value == null) return;
      output.add(
        _Phase(
          label: label,
          status: value['status']?.toString() ?? 'waiting',
          detail: detail ?? _phaseDetail(key, value),
        ),
      );
    }

    add('metadata', 'Category metadata');
    add('question_banks', 'Question bank');
    add('sets', 'Quiz set selection');
    add('background', 'Background artwork');
    add('audio', 'Narration and audit');
    add('visuals', 'Visual assets');
    add('publish', 'Bundle preparation');
    return output;
  }

  static String _phaseDetail(String key, Map value) {
    if (key == 'question_banks') {
      final levels = value['difficulties'] as Map? ?? const {};
      var current = 0;
      var target = 0;
      for (final level in levels.values.whereType<Map>()) {
        current += int.tryParse(level['total']?.toString() ?? '') ?? 0;
        target += int.tryParse(level['target']?.toString() ?? '') ?? 0;
      }
      if (target > 0) return '$current / $target questions retained';
    }
    if (key == 'sets') {
      final summary = value['summary'] as Map?;
      if (summary != null) return '${summary['total'] ?? 0} sets selected';
    }
    if (key == 'visuals') {
      final result = value['result'] as Map?;
      final summary = result?['summary'] as Map?;
      if (summary != null) {
        return '${summary['generated'] ?? 0} / ${summary['total'] ?? 0} images';
      }
      final category =
          int.tryParse(value['category_asset_count']?.toString() ?? '') ?? 0;
      final answers =
          int.tryParse(value['answer_asset_count']?.toString() ?? '') ?? 0;
      if (category + answers > 0) return '${category + answers} images planned';
    }
    if (key == 'audio') {
      final summary = value['summary'] as Map?;
      if (summary != null) {
        return '${summary['passed'] ?? 0} / ${summary['clips_total'] ?? 0} clips';
      }
    }
    if (key == 'publish') {
      final result = value['result'] as Map?;
      if (result != null) {
        return 'Version ${result['bundle_version'] ?? ''} ${result['deployment_status'] ?? ''}'
            .trim();
      }
    }
    return value['status']?.toString() ?? '';
  }

  static (Color, Color) _tone(String status) => switch (status) {
    'complete' => (AppColors.greenSoft, AppColors.green),
    'failed' || 'interrupted' => (AppColors.coralSoft, AppColors.coral),
    _ => (AppColors.blueSoft, AppColors.blue),
  };

  static IconData _statusIcon(String status) => switch (status) {
    'complete' => Icons.check,
    'failed' || 'interrupted' => Icons.error_outline,
    _ => Icons.sync,
  };
}

class _Phase {
  const _Phase({
    required this.label,
    required this.status,
    required this.detail,
  });

  final String label;
  final String status;
  final String detail;
}

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({required this.phase, required this.last});

  final _Phase phase;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final complete = phase.status == 'complete';
    final failed = phase.status == 'failed';
    final color = failed
        ? AppColors.coral
        : complete
        ? AppColors.green
        : AppColors.blue;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    failed
                        ? Icons.close
                        : complete
                        ? Icons.check
                        : Icons.more_horiz,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
                if (!last)
                  Expanded(child: Container(width: 2, color: AppColors.line)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    phase.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    phase.detail,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BundleCard extends StatelessWidget {
  const _BundleCard({
    required this.bundle,
    required this.pipelineBusy,
    required this.onDeploy,
  });

  final Map<String, dynamic> bundle;
  final bool pipelineBusy;
  final VoidCallback onDeploy;

  @override
  Widget build(BuildContext context) {
    final category = bundle['category'] as Map? ?? const {};
    final latest = bundle['latest'] as Map? ?? const {};
    final summary = bundle['summary'] as Map? ?? const {};
    final status = bundle['status']?.toString() ?? 'not_built';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    category['name']?.toString() ??
                        category['slug']?.toString() ??
                        'Category',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                StatusPill(label: _label(status), tone: _statusTone(status)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 5,
              children: [
                _Metric(
                  icon: Icons.layers_outlined,
                  text: '${summary['quiz_sets'] ?? 0} sets',
                ),
                _Metric(
                  icon: Icons.quiz_outlined,
                  text: '${summary['questions'] ?? 0} questions',
                ),
                if (latest.isNotEmpty)
                  _Metric(
                    icon: Icons.tag,
                    text: 'v${latest['bundle_version'] ?? '?'}',
                  ),
              ],
            ),
            if (status == 'deployable') ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: pipelineBusy ? null : onDeploy,
                  icon: const Icon(Icons.publish),
                  label: const Text('Deploy bundle'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _label(String status) => switch (status) {
    'deployable' => 'Ready to deploy',
    'deployed' => 'Deployed',
    'invalid' => 'Attention',
    _ => 'Not built',
  };
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppColors.muted),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.job,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> job;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final contextData = job['context'] as Map? ?? const {};
    final status = job['status']?.toString() ?? 'unknown';
    return Material(
      color: selected ? AppColors.greenSoft : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                _CurrentRunCard._statusIcon(status),
                color: _CurrentRunCard._tone(status).$2,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contextData['category_name']?.toString() ??
                          contextData['category_slug']?.toString() ??
                          'Category generation',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      _formatTime(job['updated_at']),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              StatusPill(label: status, tone: _statusTone(status)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatTime(dynamic raw) {
    final date = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
    if (date == null) return '';
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day}/${date.month}/${date.year}  ${date.hour}:$minute';
  }
}

StatusTone _statusTone(String status) => switch (status) {
  'complete' || 'deployed' => StatusTone.good,
  'deployable' || 'queued' => StatusTone.warning,
  'failed' || 'interrupted' || 'invalid' => StatusTone.danger,
  'running' => StatusTone.info,
  _ => StatusTone.neutral,
};
