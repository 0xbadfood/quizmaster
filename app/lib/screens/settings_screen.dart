import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../config/feature_flags.dart';
import '../providers/app_state.dart';
import '../startup/app_preparation.dart';
import '../startup/benchmark_preferences.dart';
import '../startup/startup_intro_preferences.dart';
import '../theme/app_theme.dart';
import '../voice/talk_voice_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedMode = 'production';
  String _selectedSandboxLabel = '';
  bool _busy = false;
  bool _initializedFromAppState = false;
  bool _forceBenchmarkNextBoot = false;
  bool _benchmarkPreferenceLoading = true;
  bool _startupIntroPreferenceLoading = true;
  bool _showStartupIntroNextBoot = false;
  DeviceTtsBenchmarkReport? _storedBenchmarkReport;
  DeviceTtsBenchmarkThresholds _benchmarkThresholds =
      deviceTtsBenchmarkThresholds;
  DeviceTtsBenchmarkThresholds _editingBenchmarkThresholds =
      deviceTtsBenchmarkThresholds;
  bool _benchmarkGateSaving = false;
  double _talkVoiceSpeed = talkVoiceSpeedDefault;
  int _talkVoicePrerollMs = talkVoicePrerollDefaultMs;
  TalkVoiceChunkBoundary _talkVoiceChunkBoundary =
      talkVoiceChunkBoundaryDefault;

  @override
  void initState() {
    super.initState();
    _loadBenchmarkPreference();
    _loadStartupIntroPreference();
    if (kEnableTalkFeature) {
      _loadTalkVoiceSpeedPreference();
      _loadTalkVoicePrerollPreference();
      _loadTalkVoiceChunkBoundaryPreference();
    }
  }

  Future<void> _loadTalkVoiceSpeedPreference() async {
    final double speed = await loadTalkVoiceSpeed();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoiceSpeed = speed;
    });
  }

  Future<void> _setTalkVoiceSpeed(double value) async {
    final double speed = clampTalkVoiceSpeed(value);
    setState(() {
      _talkVoiceSpeed = speed;
    });
    await saveTalkVoiceSpeed(speed);
  }

  Future<void> _loadTalkVoicePrerollPreference() async {
    final int prerollMs = await loadTalkVoicePrerollMs();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoicePrerollMs = prerollMs;
    });
  }

  Future<void> _setTalkVoicePrerollMs(double value) async {
    final int prerollMs = clampTalkVoicePrerollMs(value.round());
    setState(() {
      _talkVoicePrerollMs = prerollMs;
    });
    await saveTalkVoicePrerollMs(prerollMs);
  }

  Future<void> _loadTalkVoiceChunkBoundaryPreference() async {
    final TalkVoiceChunkBoundary boundary = await loadTalkVoiceChunkBoundary();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoiceChunkBoundary = boundary;
    });
  }

  Future<void> _setTalkVoiceChunkBoundary(
    TalkVoiceChunkBoundary boundary,
  ) async {
    setState(() {
      _talkVoiceChunkBoundary = boundary;
    });
    await saveTalkVoiceChunkBoundary(boundary);
  }

  Future<void> _loadStartupIntroPreference() async {
    final bool enabled = await showStartupIntroOnNextBoot();
    if (!mounted) {
      return;
    }
    setState(() {
      _showStartupIntroNextBoot = enabled;
      _startupIntroPreferenceLoading = false;
    });
  }

  Future<void> _setShowStartupIntroNextBoot(bool enabled) async {
    setState(() {
      _showStartupIntroNextBoot = enabled;
    });
    await setShowStartupIntroOnNextBoot(enabled);
  }

  Future<void> _loadBenchmarkPreference() async {
    final (
      bool enabled,
      DeviceTtsBenchmarkReport? report,
      DeviceTtsBenchmarkThresholds thresholds,
    ) = await (
      forceDeviceBenchmarkOnNextBoot(),
      AppPreparationController.loadStoredReport(),
      loadDeviceTtsBenchmarkThresholds(),
    ).wait;
    if (!mounted) {
      return;
    }
    setState(() {
      _forceBenchmarkNextBoot = enabled;
      _storedBenchmarkReport = report;
      _benchmarkThresholds = thresholds;
      _editingBenchmarkThresholds = thresholds;
      _benchmarkPreferenceLoading = false;
    });
  }

  Future<void> _setForceBenchmarkNextBoot(bool enabled) async {
    setState(() => _forceBenchmarkNextBoot = enabled);
    await setForceDeviceBenchmarkOnNextBoot(enabled);
  }

  Future<void> _enableTalkRetryNow() async {
    final AppPreparationController preparation = context
        .read<AppPreparationController>();
    await preparation.enableTalkRetry();
    final DeviceTtsBenchmarkReport? report =
        await AppPreparationController.loadStoredReport();
    if (!mounted) {
      return;
    }
    setState(() {
      _storedBenchmarkReport = report;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Talk is enabled for a fresh check.')),
    );
  }

  bool get _benchmarkGatesDirty =>
      _editingBenchmarkThresholds.cacheKey != _benchmarkThresholds.cacheKey;

  Future<void> _saveBenchmarkGateSettings(
    DeviceTtsBenchmarkThresholds thresholds,
  ) async {
    if (_benchmarkGateSaving) {
      return;
    }
    setState(() => _benchmarkGateSaving = true);
    try {
      final AppPreparationController preparation = context
          .read<AppPreparationController>();
      await preparation.saveBenchmarkThresholds(thresholds);
      await setForceDeviceBenchmarkOnNextBoot(true);
      if (!mounted) {
        return;
      }
      setState(() {
        _benchmarkThresholds = thresholds;
        _editingBenchmarkThresholds = thresholds;
        _storedBenchmarkReport = null;
        _forceBenchmarkNextBoot = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Benchmark gates saved. Talk can be checked again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _benchmarkGateSaving = false);
      }
    }
  }

  void _editBenchmarkThresholds(DeviceTtsBenchmarkThresholds thresholds) {
    setState(() => _editingBenchmarkThresholds = thresholds);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.read<AppState>();
    if (!_initializedFromAppState) {
      _selectedMode = appState.contentEnvironmentMode;
      _selectedSandboxLabel = appState.sandboxLabel;
      _initializedFromAppState = true;
    }
    if (appState.availableSandboxes.isEmpty &&
        !appState.sandboxDirectoryLoading) {
      appState.refreshSandboxDirectory();
    }
  }

  Future<void> _apply(AppState appState) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await appState.setContentEnvironment(
        mode: _selectedMode,
        sandboxLabel: _selectedMode == 'sandbox' ? _selectedSandboxLabel : '',
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update content environment: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final AppPreparationController preparation = context
        .watch<AppPreparationController>();
    final DeviceTtsBenchmarkReport? benchmarkReport =
        preparation.report ?? _storedBenchmarkReport;
    final sandboxes = appState.availableSandboxes;
    return Scaffold(
      backgroundColor: SunshineColors.deepBlue,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Sunshine World',
            style: GoogleFonts.nunito(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: SunshineColors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'App settings and evaluator tools.',
            style: GoogleFonts.nunito(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: SunshineColors.white.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: sunshineCardDecoration().copyWith(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Content Environment',
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.purpleText,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Switching environment deletes downloaded content and reloads the catalog.',
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: SunshineColors.purpleText.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _selectedMode,
                  decoration: const InputDecoration(labelText: 'Environment'),
                  items: const [
                    DropdownMenuItem(
                      value: 'production',
                      child: Text('Production'),
                    ),
                    DropdownMenuItem(value: 'sandbox', child: Text('Sandbox')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() {
                            _selectedMode = value ?? 'production';
                            if (_selectedMode != 'sandbox') {
                              _selectedSandboxLabel = '';
                            }
                          });
                        },
                ),
                if (_selectedMode == 'sandbox') ...[
                  const SizedBox(height: 12),
                  if (appState.sandboxDirectoryLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: LinearProgressIndicator(),
                    ),
                  if (appState.sandboxDirectoryError != null) ...[
                    Text(
                      'Failed to load sandboxes: ${appState.sandboxDirectoryError}',
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.red.shade300,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  DropdownButtonFormField<String>(
                    initialValue: _selectedSandboxLabel.isNotEmpty
                        ? _selectedSandboxLabel
                        : null,
                    decoration: const InputDecoration(labelText: 'Sandbox'),
                    items: sandboxes
                        .map(
                          (sandbox) => DropdownMenuItem<String>(
                            value: (sandbox['label'] ?? '').toString(),
                            child: Text((sandbox['label'] ?? '').toString()),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _busy
                        ? null
                        : (value) {
                            setState(() {
                              _selectedSandboxLabel = value ?? '';
                            });
                          },
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        _busy ||
                            (_selectedMode == 'sandbox' &&
                                _selectedSandboxLabel.isEmpty)
                        ? null
                        : () => _apply(appState),
                    child: Text(_busy ? 'Applying...' : 'Apply Environment'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _buildStartupVideoCard(),
          if (kEnableTalkFeature) ...[
            const SizedBox(height: 18),
            _buildTalkVoiceCard(),
            const SizedBox(height: 18),
            _buildVoiceBenchmarkStatsCard(
              benchmarkReport,
              _benchmarkThresholds,
            ),
            const SizedBox(height: 18),
            _buildBenchmarkGatesCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildStartupVideoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: sunshineCardDecoration().copyWith(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Startup Video',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Play the StoryVault intro video once on the next app boot. This is off by default and resets automatically after the boot starts.',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: SunshineColors.purpleText.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Show video on next boot',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: SunshineColors.purpleText,
              ),
            ),
            subtitle: Text(
              _showStartupIntroNextBoot
                  ? 'Enabled for the next launch only'
                  : 'Disabled',
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: SunshineColors.purpleText.withValues(alpha: 0.75),
              ),
            ),
            value: _showStartupIntroNextBoot,
            onChanged: _startupIntroPreferenceLoading
                ? null
                : (bool value) => _setShowStartupIntroNextBoot(value),
          ),
        ],
      ),
    );
  }

  Widget _buildTalkVoiceCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: sunshineCardDecoration().copyWith(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Talk Voice',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Controls the local PocketTTS speaking speed and initial silence for wizard prompts and generated stories.',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: SunshineColors.purpleText.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 14),
          _BenchmarkGateSlider(
            label: 'Voice speed',
            value: _talkVoiceSpeed,
            min: talkVoiceSpeedMin,
            max: talkVoiceSpeedMax,
            divisions: 10,
            displayValue: '${_talkVoiceSpeed.toStringAsFixed(2)}x',
            onChanged: _setTalkVoiceSpeed,
          ),
          const SizedBox(height: 10),
          _BenchmarkGateSlider(
            label: 'First-word guard',
            value: _talkVoicePrerollMs.toDouble(),
            min: talkVoicePrerollMinMs.toDouble(),
            max: talkVoicePrerollMaxMs.toDouble(),
            divisions: 6,
            displayValue: '${_talkVoicePrerollMs}ms',
            onChanged: _setTalkVoicePrerollMs,
          ),
          const SizedBox(height: 14),
          Text(
            'Chunk boundary',
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final TalkVoiceChunkBoundary boundary
                  in TalkVoiceChunkBoundary.values)
                ChoiceChip(
                  label: Text(talkVoiceChunkBoundaryLabel(boundary)),
                  selected: _talkVoiceChunkBoundary == boundary,
                  onSelected: (_) => _setTalkVoiceChunkBoundary(boundary),
                  labelStyle: GoogleFonts.nunito(
                    fontWeight: FontWeight.w900,
                    color: _talkVoiceChunkBoundary == boundary
                        ? SunshineColors.white
                        : SunshineColors.purpleText,
                  ),
                  selectedColor: SunshineColors.lavender,
                  backgroundColor: SunshineColors.white.withValues(alpha: 0.7),
                  side: BorderSide(
                    color: SunshineColors.purpleText.withValues(alpha: 0.16),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceBenchmarkStatsCard(
    DeviceTtsBenchmarkReport? report,
    DeviceTtsBenchmarkThresholds thresholds,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: sunshineCardDecoration().copyWith(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Talk Device Benchmark',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Last device result compared with the saved benchmark gates.',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: SunshineColors.purpleText.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 14),
          _BenchmarkRow(
            label: 'Last decision',
            value: report == null
                ? 'Not tested'
                : _benchmarkStatusLabel(report.status),
            passed: report?.status == DeviceTtsCapabilityStatus.localPreferred,
          ),
          if (report != null) ...[
            _BenchmarkRow(
              label: 'Completed',
              value: _formatDateTime(report.completedAt),
            ),
            _BenchmarkRow(label: 'Reason', value: report.reason),
            _BenchmarkRow(
              label: 'Selected threads',
              value: report.selectedThreads.toString(),
            ),
            _BenchmarkRow(
              label: 'Model init',
              value: '${report.modelInitializationMs.toStringAsFixed(0)} ms',
            ),
          ],
          const Divider(height: 24),
          _BenchmarkRow(
            label: 'First generated chunk p95',
            value: report == null
                ? 'Diagnostic only'
                : '${report.firstAudioP95Ms.toStringAsFixed(0)} ms',
          ),
          _BenchmarkRow(
            label: 'Warm RTF p95',
            value: report == null
                ? '<= ${thresholds.maximumWarmRtfP95.toStringAsFixed(2)}'
                : '${report.warmRtfP95.toStringAsFixed(2)} / '
                      '<= ${thresholds.maximumWarmRtfP95.toStringAsFixed(2)}',
            passed: report == null
                ? null
                : report.warmRtfP95 <= thresholds.maximumWarmRtfP95,
          ),
          _BenchmarkRow(
            label: 'Sustained RTF p95',
            value: report == null
                ? '<= ${thresholds.maximumSustainedRtfP95.toStringAsFixed(2)}'
                : '${report.sustainedRtfP95.toStringAsFixed(2)} / '
                      '<= ${thresholds.maximumSustainedRtfP95.toStringAsFixed(2)}',
            passed: report == null
                ? null
                : report.sustainedRtfP95 <= thresholds.maximumSustainedRtfP95,
          ),
          _BenchmarkRow(
            label: 'Thermal degradation',
            value: report == null
                ? '<= ${_formatPercent(thresholds.maximumThermalDegradation)}'
                : '${_formatPercent(report.thermalDegradation)} / '
                      '<= ${_formatPercent(thresholds.maximumThermalDegradation)}',
            passed: report == null
                ? null
                : report.thermalDegradation <=
                      thresholds.maximumThermalDegradation,
          ),
          _BenchmarkRow(
            label: 'Peak app memory',
            value: report == null
                ? '<= ${_formatPercent(thresholds.maximumProcessMemoryRatio)}'
                : '${_formatPercent(report.peakProcessMemoryRatio)} / '
                      '<= ${_formatPercent(thresholds.maximumProcessMemoryRatio)}',
            passed: report == null
                ? null
                : report.peakProcessMemoryRatio <=
                      thresholds.maximumProcessMemoryRatio,
          ),
          _BenchmarkRow(
            label: 'Generation failures',
            value: report == null
                ? '= ${thresholds.maximumGenerationFailures}'
                : '${report.generationFailures} / '
                      '= ${thresholds.maximumGenerationFailures}',
            passed: report == null
                ? null
                : report.generationFailures <=
                      thresholds.maximumGenerationFailures,
          ),
          _BenchmarkRow(
            label: 'Min free memory',
            value: _formatBytes(thresholds.minimumAvailableMemoryBytes),
          ),
        ],
      ),
    );
  }

  Widget _buildBenchmarkGatesCard() {
    final DeviceTtsBenchmarkThresholds gates = _editingBenchmarkThresholds;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: sunshineCardDecoration().copyWith(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Benchmark Gates',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Saved as local JSON. Changing these clears the old Talk decision and forces a fresh check.',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: SunshineColors.purpleText.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 14),
          _BenchmarkGateSlider(
            label: 'Warm RTF p95',
            value: gates.maximumWarmRtfP95,
            min: 0.30,
            max: 1.50,
            divisions: 24,
            displayValue: gates.maximumWarmRtfP95.toStringAsFixed(2),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(maximumWarmRtfP95: value),
            ),
          ),
          _BenchmarkGateSlider(
            label: 'Sustained RTF p95',
            value: gates.maximumSustainedRtfP95,
            min: 0.30,
            max: 2.00,
            divisions: 34,
            displayValue: gates.maximumSustainedRtfP95.toStringAsFixed(2),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(maximumSustainedRtfP95: value),
            ),
          ),
          _BenchmarkGateSlider(
            label: 'Thermal degradation',
            value: gates.maximumThermalDegradation,
            min: 0.05,
            max: 1.00,
            divisions: 19,
            displayValue: _formatPercent(gates.maximumThermalDegradation),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(maximumThermalDegradation: value),
            ),
          ),
          _BenchmarkGateSlider(
            label: 'Peak app memory',
            value: gates.maximumProcessMemoryRatio,
            min: 0.10,
            max: 0.80,
            divisions: 14,
            displayValue: _formatPercent(gates.maximumProcessMemoryRatio),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(maximumProcessMemoryRatio: value),
            ),
          ),
          _BenchmarkGateSlider(
            label: 'Min free memory',
            value: gates.minimumAvailableMemoryBytes / (1024 * 1024),
            min: 128,
            max: 2048,
            divisions: 15,
            displayValue: _formatBytes(gates.minimumAvailableMemoryBytes),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(
                minimumAvailableMemoryBytes: (value * 1024 * 1024).round(),
              ),
            ),
          ),
          _BenchmarkGateSlider(
            label: 'Allowed failures',
            value: gates.maximumGenerationFailures.toDouble(),
            min: 0,
            max: 3,
            divisions: 3,
            displayValue: gates.maximumGenerationFailures.toString(),
            onChanged: (double value) => _editBenchmarkThresholds(
              gates.copyWith(maximumGenerationFailures: value.round()),
            ),
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Re-benchmark on next launch',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: SunshineColors.purpleText,
              ),
            ),
            subtitle: Text(
              'Allows Talk to run a fresh device check after restart.',
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: SunshineColors.purpleText.withValues(alpha: 0.8),
              ),
            ),
            value: _forceBenchmarkNextBoot,
            onChanged: _benchmarkPreferenceLoading
                ? null
                : _setForceBenchmarkNextBoot,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _benchmarkGateSaving
                      ? null
                      : () => _saveBenchmarkGateSettings(
                          deviceTtsBenchmarkThresholds,
                        ),
                  child: const Text('Reset defaults'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _benchmarkGateSaving || !_benchmarkGatesDirty
                      ? null
                      : () => _saveBenchmarkGateSettings(gates),
                  child: Text(_benchmarkGateSaving ? 'Saving...' : 'Save'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _enableTalkRetryNow,
              child: const Text('Enable Talk retry now'),
            ),
          ),
        ],
      ),
    );
  }

  String _benchmarkStatusLabel(DeviceTtsCapabilityStatus status) {
    return switch (status) {
      DeviceTtsCapabilityStatus.localPreferred => 'Compatible',
      DeviceTtsCapabilityStatus.unsupported => 'Not compatible',
      DeviceTtsCapabilityStatus.verificationDeferred => 'Deferred',
    };
  }

  String _formatPercent(double value) {
    return '${(value * 100).toStringAsFixed(0)}%';
  }

  String _formatBytes(int bytes) {
    final double mb = bytes / (1024 * 1024);
    if (mb < 1024) {
      return '${mb.toStringAsFixed(0)} MB';
    }
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  String _formatDateTime(DateTime value) {
    final DateTime local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _BenchmarkRow extends StatelessWidget {
  const _BenchmarkRow({required this.label, required this.value, this.passed});

  final String label;
  final String value;
  final bool? passed;

  @override
  Widget build(BuildContext context) {
    final Color? stateColor = passed == null
        ? null
        : passed!
        ? const Color(0xFF1E8E5A)
        : const Color(0xFFC0392B);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: SunshineColors.purpleText.withValues(alpha: 0.78),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (stateColor != null) ...[
            Icon(
              passed! ? Icons.check_circle : Icons.cancel,
              size: 17,
              color: stateColor,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            flex: 7,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: stateColor ?? SunshineColors.purpleText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenchmarkGateSlider extends StatelessWidget {
  const _BenchmarkGateSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.purpleText,
                  ),
                ),
              ),
              Text(
                displayValue,
                style: GoogleFonts.nunito(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: SunshineColors.purpleText.withValues(alpha: 0.82),
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: displayValue,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
