import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class RunSetupScreen extends StatelessWidget {
  const RunSetupScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _editServer(BuildContext context) async {
    final url = TextEditingController(text: controller.baseUrl);
    final token = TextEditingController(text: controller.token);
    var obscure = true;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            18,
            16,
            18 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Server access',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API URL',
                  prefixIcon: Icon(Icons.language),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: token,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API token',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    onPressed: () => setSheetState(() => obscure = !obscure),
                    tooltip: obscure ? 'Show token' : 'Hide token',
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.connecting
                    ? null
                    : () async {
                        final navigator = Navigator.of(context);
                        final ok = await controller.saveConnection(
                          url: url.text,
                          apiToken: token.text,
                        );
                        if (ok) navigator.pop(true);
                      },
                icon: controller.connecting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: const Text('Save and connect'),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true && context.mounted) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MobilePage(
      children: [
        const ScreenHeading(
          title: 'Configure this run',
          subtitle:
              'Choose from provider connections already maintained on the server.',
        ),
        const SizedBox(height: 18),
        _ServerStrip(
          controller: controller,
          onEdit: () => _editServer(context),
        ),
        if (controller.errorMessage != null) ...[
          const SizedBox(height: 12),
          ErrorBanner(
            message: controller.errorMessage!,
            onDismiss: controller.clearError,
          ),
        ],
        if (controller.pipelineBusy) ...[
          const SizedBox(height: 12),
          _BusyBanner(controller: controller),
        ],
        const SizedBox(height: 24),
        SectionHeading(
          title: 'Pipeline routing',
          subtitle: 'Selections apply only to the next category generation.',
          action: IconButton(
            onPressed: controller.connected && !controller.loadingProviders
                ? controller.refreshProviders
                : null,
            tooltip: 'Refresh configured providers',
            icon: controller.loadingProviders
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ),
        const SizedBox(height: 12),
        if (!controller.connected)
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'Connect to continue',
            message:
                'The provider catalog and pipeline lock are read from the Quizmaster API.',
            action: FilledButton.icon(
              onPressed: () => _editServer(context),
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('Configure server'),
            ),
          )
        else if (controller.providers.isEmpty)
          const EmptyState(
            icon: Icons.hub_outlined,
            title: 'No configured providers',
            message:
                'Configure providers in the Quizmaster web application, then refresh this screen.',
          )
        else ...[
          for (final role in pipelineRoles) ...[
            _RoleCard(controller: controller, role: role),
            const SizedBox(height: 10),
          ],
          TextFormField(
            key: const ValueKey('background-guidance'),
            initialValue: controller.backgroundGuidance,
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            onChanged: controller.setBackgroundGuidance,
            decoration: const InputDecoration(
              labelText: 'Background guidance (optional)',
              hintText:
                  'Category-specific art direction appended to the editorial brief',
              alignLabelWithHint: true,
              prefixIcon: Padding(
                padding: EdgeInsets.only(bottom: 42),
                child: Icon(Icons.wallpaper_outlined),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: controller.connecting || !controller.routingReady
                ? null
                : controller.prepareRun,
            icon: controller.connecting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward),
            label: Text(
              controller.pipelineBusy ? 'View running generation' : 'Continue',
            ),
          ),
        ],
      ],
    );
  }
}

class _ServerStrip extends StatelessWidget {
  const _ServerStrip({required this.controller, required this.onEdit});

  final AppController controller;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: controller.connected
                    ? AppColors.greenSoft
                    : AppColors.coralSoft,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                controller.connected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: controller.connected ? AppColors.green : AppColors.coral,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.connected
                        ? 'Server available'
                        : 'Server not connected',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    controller.baseUrl.replaceFirst(RegExp(r'^https?://'), ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onEdit,
              tooltip: 'Server access',
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusyBanner extends StatelessWidget {
  const _BusyBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final holder = controller.lockState['holder'] as Map?;
    final category =
        holder?['category']?.toString() ??
        holder?['category_slug']?.toString() ??
        'another category';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amberSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8C68C)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_clock_outlined, color: AppColors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The pipeline is generating $category. You can view its progress, but cannot start another run.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.controller, required this.role});

  final AppController controller;
  final PipelineRole role;

  @override
  Widget build(BuildContext context) {
    final candidates = controller.providersForRole(role);
    final selected = controller.providerSelections[role.providerField];
    final provider = controller.providerById(selected);
    final model = role.modelField == null
        ? ''
        : controller.modelSelections[role.modelField!] ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_roleIcon(role.id), size: 20, color: AppColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    role.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (provider != null)
                  StatusPill(
                    label:
                        provider['health_status']?.toString() ?? 'configured',
                    tone: provider['health_status'] == 'healthy'
                        ? StatusTone.good
                        : StatusTone.neutral,
                  ),
              ],
            ),
            const SizedBox(height: 11),
            DropdownButtonFormField<String>(
              initialValue: candidates.any((item) => item['id'] == selected)
                  ? selected
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Provider connection',
              ),
              items: [
                for (final item in candidates)
                  DropdownMenuItem(
                    value: item['id'].toString(),
                    child: Text(
                      item['name']?.toString() ?? item['id'].toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) controller.setRoleProvider(role, value);
              },
            ),
            if (role.modelField != null) ...[
              const SizedBox(height: 10),
              _ModelField(
                key: ValueKey('${role.id}-$selected'),
                value: model,
                label: role.id == 'question' ? 'Text model' : 'Model',
                suggestions: controller.modelsForRole(role),
                onChanged: (value) => controller.setRoleModel(role, value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _roleIcon(String id) => switch (id) {
    'question' => Icons.quiz_outlined,
    'qwen' => Icons.account_tree_outlined,
    'background' => Icons.wallpaper_outlined,
    'tile' => Icons.grid_view_outlined,
    'answer' => Icons.image_outlined,
    'audio' => Icons.record_voice_over_outlined,
    _ => Icons.tune,
  };
}

class _ModelField extends StatefulWidget {
  const _ModelField({
    super.key,
    required this.value,
    required this.label,
    required this.suggestions,
    required this.onChanged,
  });

  final String value;
  final String label;
  final List<String> suggestions;
  final ValueChanged<String> onChanged;

  @override
  State<_ModelField> createState() => _ModelFieldState();
}

class _ModelFieldState extends State<_ModelField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _ModelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text != widget.value) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          autocorrect: false,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.memory_outlined),
          ),
        ),
        if (widget.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final suggestion = widget.suggestions[index];
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(suggestion),
                  onPressed: () {
                    _controller.text = suggestion;
                    widget.onChanged(suggestion);
                  },
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
