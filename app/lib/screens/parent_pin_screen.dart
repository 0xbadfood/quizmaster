import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../customer/customer_auth_service.dart';
import '../data/usb_playlist_exporter.dart';
import '../models/playlist.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../providers/app_state.dart';
import '../widgets/background_scaffold.dart';
import '../widgets/pin_keypad.dart';

enum _PinResetProvider { google, apple }

const int _maxPinAttemptsBeforeCooldown = 10;
const Duration _pinCooldownDuration = Duration(minutes: 5);
const String _pinFailedAttemptsKey = 'parent_pin_failed_attempts_v1';
const String _pinCooldownUntilKey = 'parent_pin_cooldown_until_ms_v1';

class ParentPinScreen extends StatefulWidget {
  final VoidCallback? onUnlocked;
  final VoidCallback? onManagePlaylists;
  final VoidCallback? onRegisterToy;
  final VoidCallback? onBack;
  final VoidCallback? onOpenSettings;
  const ParentPinScreen({
    super.key,
    this.onUnlocked,
    this.onManagePlaylists,
    this.onRegisterToy,
    this.onBack,
    this.onOpenSettings,
  });

  @override
  State<ParentPinScreen> createState() => _ParentPinScreenState();
}

class _ParentPinScreenState extends State<ParentPinScreen>
    with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _error;
  bool _checking = false;
  bool _resetPinMode = false;
  int _failedPinAttempts = 0;
  DateTime? _pinCooldownUntil;
  Timer? _pinCooldownTimer;
  final TextEditingController _newPinController = TextEditingController();
  final TextEditingController _confirmNewPinController =
      TextEditingController();
  late AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    unawaited(_loadPinGuardState());
  }

  @override
  void dispose() {
    _pinCooldownTimer?.cancel();
    _shakeController.dispose();
    _newPinController.dispose();
    _confirmNewPinController.dispose();
    super.dispose();
  }

  bool get _pinCooldownActive {
    final until = _pinCooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Duration get _pinCooldownRemaining {
    final until = _pinCooldownUntil;
    if (until == null) {
      return Duration.zero;
    }
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _onDigit(String digit) {
    if (_checking || _pinCooldownActive || _pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  void _onDelete() {
    if (_checking || _pinCooldownActive || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  void _resetPinState() {
    if (_pin.isEmpty &&
        _error == null &&
        !_resetPinMode &&
        _newPinController.text.isEmpty &&
        _confirmNewPinController.text.isEmpty) {
      return;
    }
    setState(() {
      _pin = '';
      _error = null;
      _checking = false;
      _resetPinMode = false;
      _newPinController.clear();
      _confirmNewPinController.clear();
    });
  }

  void _handleBack() {
    if (_resetPinMode) {
      _resetPinState();
      return;
    }
    _resetPinState();
    widget.onBack?.call();
  }

  Future<void> _loadPinGuardState() async {
    final prefs = await SharedPreferences.getInstance();
    final attempts = prefs.getInt(_pinFailedAttemptsKey) ?? 0;
    final cooldownUntilMs = prefs.getInt(_pinCooldownUntilKey) ?? 0;
    final cooldownUntil = cooldownUntilMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(cooldownUntilMs)
        : null;
    final activeCooldown =
        cooldownUntil != null && DateTime.now().isBefore(cooldownUntil);
    if (!mounted) {
      return;
    }
    setState(() {
      _failedPinAttempts = activeCooldown
          ? attempts.clamp(0, _maxPinAttemptsBeforeCooldown)
          : 0;
      _pinCooldownUntil = activeCooldown ? cooldownUntil : null;
      _error = activeCooldown ? _pinCooldownMessage() : _error;
    });
    if (activeCooldown) {
      _startPinCooldownTimer();
    } else if (attempts > 0 || cooldownUntilMs > 0) {
      await _clearPinGuardState(notify: false);
    }
  }

  Future<void> _persistPinGuardState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pinFailedAttemptsKey, _failedPinAttempts);
    final until = _pinCooldownUntil;
    if (until == null) {
      await prefs.remove(_pinCooldownUntilKey);
    } else {
      await prefs.setInt(_pinCooldownUntilKey, until.millisecondsSinceEpoch);
    }
  }

  Future<void> _clearPinGuardState({bool notify = true}) async {
    _pinCooldownTimer?.cancel();
    _pinCooldownTimer = null;
    if (mounted && notify) {
      setState(() {
        _failedPinAttempts = 0;
        _pinCooldownUntil = null;
        _error = null;
      });
    } else {
      _failedPinAttempts = 0;
      _pinCooldownUntil = null;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinFailedAttemptsKey);
    await prefs.remove(_pinCooldownUntilKey);
  }

  Future<void> _registerFailedPinAttempt() async {
    final nextAttempts = _failedPinAttempts + 1;
    if (nextAttempts >= _maxPinAttemptsBeforeCooldown) {
      final cooldownUntil = DateTime.now().add(_pinCooldownDuration);
      setState(() {
        _failedPinAttempts = _maxPinAttemptsBeforeCooldown;
        _pinCooldownUntil = cooldownUntil;
        _checking = false;
        _pin = '';
        _error = _pinCooldownMessage();
      });
      _startPinCooldownTimer();
      await _persistPinGuardState();
      return;
    }

    final attemptsLeft = _maxPinAttemptsBeforeCooldown - nextAttempts;
    setState(() {
      _failedPinAttempts = nextAttempts;
      _checking = false;
      _error = 'Incorrect PIN. $attemptsLeft attempts left.';
    });
    await _persistPinGuardState();
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && !_pinCooldownActive) {
        setState(() => _pin = '');
      }
    });
  }

  void _startPinCooldownTimer() {
    _pinCooldownTimer?.cancel();
    _pinCooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _pinCooldownTimer?.cancel();
        return;
      }
      if (_pinCooldownActive) {
        setState(() => _error = _pinCooldownMessage());
      } else {
        unawaited(_clearPinGuardState());
      }
    });
  }

  String _pinCooldownMessage() {
    return 'Too many incorrect PIN attempts. Try again in ${_formatCooldown(_pinCooldownRemaining)}.';
  }

  String _formatCooldown(Duration duration) {
    final totalSeconds = duration.inSeconds <= 0 ? 0 : duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _checkPin() async {
    if (_checking) {
      return;
    }
    if (_pinCooldownActive) {
      setState(() => _error = _pinCooldownMessage());
      return;
    }
    if (_pin.length < 4) {
      setState(() => _error = 'Enter at least 4 digits.');
      return;
    }
    setState(() => _checking = true);
    try {
      await context.read<AppState>().verifyParentPin(_pin);
      if (!mounted) {
        return;
      }
      await _clearPinGuardState();
      _resetPinState();
      widget.onUnlocked?.call();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _shakeController.forward(from: 0);
      await _registerFailedPinAttempt();
    }
  }

  Future<void> _handleForgotPin() async {
    if (_checking) {
      return;
    }
    final appState = context.read<AppState>();
    if (appState.sandboxMode && !appState.hasCustomerSession) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sandbox PIN'),
          content: const Text('Use 1234 to unlock Parent Mode in sandbox.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final provider = await _choosePinResetProvider();
    if (provider == null || !mounted) {
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      if (provider == _PinResetProvider.apple) {
        await context.read<AppState>().reauthenticateWithAppleForPinReset();
      } else {
        await context.read<AppState>().reauthenticateWithGoogleForPinReset();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _checking = false;
        _resetPinMode = true;
        _pin = '';
        _error = null;
        _newPinController.clear();
        _confirmNewPinController.clear();
      });
    } on CustomerAuthCanceledException {
      if (mounted) {
        setState(() => _checking = false);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _checking = false;
        _error = friendlyConnectionMessage(error);
      });
    }
  }

  Future<_PinResetProvider?> _choosePinResetProvider() {
    final showGoogle =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final showApple = defaultTargetPlatform == TargetPlatform.iOS;
    return showDialog<_PinResetProvider>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset Parent PIN'),
        content: const Text(
          'Sign in again with the parent account, then set a new PIN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          if (showGoogle)
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PinResetProvider.google),
              child: const Text('Continue with Google'),
            ),
          if (showApple)
            FilledButton.tonal(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PinResetProvider.apple),
              child: const Text('Continue with Apple'),
            ),
        ],
      ),
    );
  }

  Future<void> _saveNewPin() async {
    if (_checking) {
      return;
    }
    final pin = _newPinController.text.trim();
    final confirm = _confirmNewPinController.text.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      setState(() => _error = 'PIN must be exactly 4 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN confirmation does not match.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final appState = context.read<AppState>();
      await appState.setParentPin(pin);
      if (!mounted) {
        return;
      }
      await _clearPinGuardState();
      _resetPinState();
      appState.unlockParentMode();
      widget.onUnlocked?.call();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _checking = false;
        _error = friendlyConnectionMessage(error);
      });
    }
  }

  Future<void> _confirmAndSignOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes the parent account from this device. You will need to sign in again to manage account access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (shouldSignOut != true || !mounted) {
      return;
    }
    final appState = context.read<AppState>();
    _resetPinState();
    appState.lockParentMode();
    await appState.signOutCustomer();
  }

  Future<void> _showUsbPlaylistExport() async {
    final playlists = context.read<AppState>().playlists;
    if (playlists.isEmpty) {
      _showUsbExportMessage('Create a playlist before copying to USB.');
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final proceed = await _confirmIosUsbFolderAccess();
      if (proceed != true || !mounted) {
        return;
      }
    }
    UsbStorageDeviceTarget? target;
    try {
      target = await UsbPlaylistExporter.instance.openStorageDevice();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showUsbExportMessage(_friendlyUsbLaunchError(error));
      return;
    }
    if (!mounted) {
      return;
    }
    if (target == null) {
      _showUsbExportMessage(
        'Storage access was not granted. Try again when ready.',
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _UsbPlaylistExportDialog(playlists: playlists, target: target!),
    );
  }

  Future<bool?> _confirmIosUsbFolderAccess() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: SunshineColors.deepBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.folder_open_rounded,
                color: SunshineColors.deepBlue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Choose USB Folder',
                style: GoogleFonts.nunito(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  color: SunshineColors.darkText,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'On iPhone and iPad, StoryVault needs you to choose the root folder of the USB storage device in Files. StoryVault will write numbered MP3 files there for simple USB speakers.',
          style: GoogleFonts.nunito(
            fontSize: 14,
            height: 1.35,
            fontWeight: FontWeight.w700,
            color: SunshineColors.darkText.withValues(alpha: 0.76),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.folder_rounded),
            label: const Text('Open Files'),
          ),
        ],
      ),
    );
  }

  void _showUsbExportMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  String _friendlyUsbLaunchError(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'no_usb_device':
          return 'Insert a StoryVault USB storage device, then try again.';
        case 'usb_permission_pending':
          return 'Please finish the storage permission request first.';
        case 'usb_open_failed':
          return 'Could not open this storage device. Remove it, plug it back in, and try again.';
        case 'unsupported_target':
          return 'Please choose the root folder of your StoryVault USB device.';
      }
    }
    if (error is UnsupportedError) {
      return 'USB playlist export is available on Android and iOS with a storage device.';
    }
    return 'Oops, something went wrong. Try again.';
  }

  Widget _buildResetPinCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(24),
      decoration: sunshineCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.lock_reset,
            size: 48,
            color: SunshineColors.lavender,
          ),
          const SizedBox(height: 12),
          Text(
            'Set a new parent PIN',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: SunshineColors.darkText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'You signed in again. Choose a new 4 digit PIN.',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: SunshineColors.darkText.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _newPinController,
            enabled: !_checking,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: 'New PIN',
              hintText: '4 digits',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmNewPinController,
            enabled: !_checking,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: 'Confirm PIN',
              hintText: 'Repeat PIN',
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: SunshineColors.error,
              ),
            ),
          ],
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: _checking ? null : _saveNewPin,
            child: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    'Save New PIN',
                    style: GoogleFonts.nunito(fontWeight: FontWeight.w900),
                  ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _checking ? null : _resetPinState,
            child: const Text('Back to PIN entry'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    const pinDotCount = 4;
    if (appState.parentMode) {
      return _ParentModeMenu(
        onPlaylistEditor: widget.onManagePlaylists,
        onRegisterToy: widget.onRegisterToy,
        onLock: () {
          _resetPinState();
          appState.lockParentMode();
          widget.onBack?.call();
        },
        onBack: _handleBack,
        onSignOut: _confirmAndSignOut,
        onExportPlaylist: _showUsbPlaylistExport,
      );
    }

    return BackgroundScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _handleBack,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: SunshineColors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        color: SunshineColors.white,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.lock, color: SunshineColors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    _resetPinMode ? 'Reset Parent PIN' : 'Parent Access',
                    style: GoogleFonts.nunito(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.white,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onOpenSettings,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: SunshineColors.white.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.settings,
                        color: SunshineColors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (_resetPinMode)
              _buildResetPinCard()
            else
              AnimatedBuilder(
                animation: _shakeController,
                builder: (context, child) {
                  final dx = _shakeController.isAnimating
                      ? 10 *
                            (0.5 - _shakeController.value).abs() *
                            (_shakeController.value < 0.5 ? -1 : 1)
                      : 0.0;
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(24),
                  decoration: sunshineCardDecoration(),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.shield,
                        size: 48,
                        color: SunshineColors.lavender,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Enter your parent PIN',
                        style: GoogleFonts.nunito(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.darkText,
                        ),
                      ),
                      Text(
                        '4 digits. 10 wrong tries pauses input for 5 minutes.',
                        style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: SunshineColors.darkText.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(pinDotCount, (i) {
                          final filled = i < _pin.length;
                          return Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: filled
                                  ? SunshineColors.lavender
                                  : Colors.transparent,
                              border: Border.all(
                                color: SunshineColors.lavender,
                                width: 2,
                              ),
                            ),
                          );
                        }),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: SunshineColors.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _checking || _pinCooldownActive || _pin.length < 4
                              ? null
                              : _checkPin,
                          child: _checking
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  'Unlock Parent Mode',
                                  style: GoogleFonts.nunito(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PinKeypad(onDigit: _onDigit, onDelete: _onDelete),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _checking ? null : _handleForgotPin,
                        child: const Text('Forgot PIN?'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // Info note
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SunshineColors.cream.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: SunshineColors.lavender,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Parent Mode allows playlist editing, downloads, and SD card export.',
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: SunshineColors.purpleText,
                      ),
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
}

class _ParentModeMenu extends StatelessWidget {
  final VoidCallback? onPlaylistEditor;
  final VoidCallback? onRegisterToy;
  final VoidCallback? onLock;
  final VoidCallback? onBack;
  final VoidCallback? onSignOut;
  final VoidCallback? onExportPlaylist;
  const _ParentModeMenu({
    this.onPlaylistEditor,
    this.onRegisterToy,
    this.onLock,
    this.onBack,
    this.onSignOut,
    this.onExportPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return BackgroundScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: onBack,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: SunshineColors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_back,
                      color: SunshineColors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    gradient: SunshineColors.purpleGradient,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '🔓 Parent Mode On',
                    style: GoogleFonts.nunito(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Parent Controls',
              style: GoogleFonts.nunito(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: SunshineColors.white,
              ),
            ),
            const SizedBox(height: 20),
            _MenuButton(
              icon: Icons.playlist_add,
              title: 'Manage Playlists',
              subtitle: 'Create, rename, reorder, and remove items',
              onTap: onPlaylistEditor,
            ),
            const SizedBox(height: 12),
            _MenuButton(
              icon: Icons.usb,
              title: 'Export Playlist to USB',
              subtitle: 'Copy one playlist to a StoryVault storage device',
              onTap: onExportPlaylist,
              color: SunshineColors.mintGreen,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: sunshineCardDecoration(),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: SunshineColors.deepBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.lock_clock,
                      color: SunshineColors.deepBlue,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Playlist Only for Kids',
                          style: GoogleFonts.nunito(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.darkText,
                          ),
                        ),
                        Text(
                          'Restrict child browsing to playlists only',
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: SunshineColors.darkText.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: appState.playlistOnlyForKids,
                    onChanged: (value) =>
                        context.read<AppState>().setPlaylistOnlyForKids(value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: sunshineCardDecoration(),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: SunshineColors.lavender.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.quiz,
                      color: SunshineColors.lavender,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Story Quiz',
                          style: GoogleFonts.nunito(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.darkText,
                          ),
                        ),
                        Text(
                          appState.quizEnabled
                              ? 'Ask after a completed story'
                              : 'Do not ask after stories',
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: SunshineColors.darkText.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: appState.quizEnabled,
                    onChanged: (value) =>
                        context.read<AppState>().setQuizEnabled(value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: sunshineCardDecoration(),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: SunshineColors.warmOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.record_voice_over_rounded,
                      color: SunshineColors.warmOrange,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Wait for Quiz Narration',
                          style: GoogleFonts.nunito(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.darkText,
                          ),
                        ),
                        Text(
                          appState.waitForQuizExplanationAudio
                              ? 'Show Next after the explanation finishes'
                              : 'Show Next while the explanation is playing',
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: SunshineColors.darkText.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: appState.waitForQuizExplanationAudio,
                    onChanged: (value) => context
                        .read<AppState>()
                        .setWaitForQuizExplanationAudio(value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _MenuButton(
              icon: Icons.toys,
              title: 'Register Toy',
              subtitle: 'Link your Sunshine toy',
              onTap: onRegisterToy,
            ),
            if (appState.hasCustomerSession) ...[
              const SizedBox(height: 12),
              _MenuButton(
                icon: Icons.logout,
                title: 'Sign Out',
                subtitle: 'Remove this account from this device',
                onTap: onSignOut,
                color: Colors.redAccent,
              ),
            ],
            const SizedBox(height: 12),
            _MenuButton(
              icon: Icons.lock,
              title: 'Exit Parent Mode',
              subtitle: 'Return to Kid Mode',
              onTap: onLock,
              color: SunshineColors.warmOrange,
            ),
          ],
        ),
      ),
    );
  }
}

class _UsbPlaylistExportDialog extends StatefulWidget {
  final List<Playlist> playlists;
  final UsbStorageDeviceTarget target;

  const _UsbPlaylistExportDialog({
    required this.playlists,
    required this.target,
  });

  @override
  State<_UsbPlaylistExportDialog> createState() =>
      _UsbPlaylistExportDialogState();
}

class _UsbPlaylistExportDialogState extends State<_UsbPlaylistExportDialog> {
  String? _selectedPlaylistId;
  bool _exporting = false;
  bool _cancelling = false;
  UsbPlaylistExportResult? _result;
  String? _error;
  UsbPlaylistExportProgress? _progress;
  String? _deviceLabel;
  bool _released = false;
  UsbPlaylistExportCancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    if (widget.playlists.isNotEmpty) {
      _selectedPlaylistId = widget.playlists.first.id;
    }
  }

  Playlist? get _selectedPlaylist {
    final selected = _selectedPlaylistId;
    if (selected == null) {
      return null;
    }
    try {
      return widget.playlists.firstWhere((playlist) => playlist.id == selected);
    } catch (_) {
      return null;
    }
  }

  bool _canExportPlaylistItem(PlaylistItem item) {
    return !item.content.locked;
  }

  Playlist? get _selectedExportablePlaylist {
    final selected = _selectedPlaylist;
    if (selected == null) {
      return null;
    }
    final exportableItems = selected.items
        .where(_canExportPlaylistItem)
        .toList(growable: false);
    return selected.copyWith(items: exportableItems);
  }

  int get _selectedLockedItemCount {
    final selected = _selectedPlaylist;
    if (selected == null) {
      return 0;
    }
    return selected.items.where((item) => !_canExportPlaylistItem(item)).length;
  }

  Future<void> _startExport() async {
    final playlist = _selectedExportablePlaylist;
    if (playlist == null || _exporting) {
      return;
    }
    if (playlist.items.isEmpty) {
      setState(() {
        _error =
            'This playlist has no unlocked rhymes or stories to copy. Register a toy or subscribe to unlock more content.';
      });
      return;
    }
    setState(() {
      _exporting = true;
      _cancelling = false;
      _result = null;
      _error = null;
      _progress = null;
      _deviceLabel = widget.target.label;
      _released = false;
    });
    final cancelToken = UsbPlaylistExportCancelToken();
    _cancelToken = cancelToken;
    try {
      final result = await UsbPlaylistExporter.instance.exportPlaylist(
        playlist,
        target: widget.target,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progress = progress;
            if (progress.deviceLabel != null) {
              _deviceLabel = progress.deviceLabel;
            }
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        if (result.cancelled) {
          _progress = UsbPlaylistExportProgress(
            message: 'Copy stopped safely.',
            completedItems: min(
              result.copied + result.skipped + result.repaired,
              result.totalItems,
            ),
            totalItems: result.totalItems,
            deviceLabel: result.deviceLabel,
            stage: UsbPlaylistExportStage.cancelled,
          );
        }
        if (result.deviceLabel != null) {
          _deviceLabel = result.deviceLabel;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = _friendlyUsbExportError(error);
        _progress = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _cancelling = false;
          _cancelToken = null;
        });
      }
    }
  }

  void _requestCancel() {
    if (!_exporting || _cancelling) {
      return;
    }
    _cancelToken?.cancel();
    setState(() {
      _cancelling = true;
      final current = _progress;
      if (current != null) {
        _progress = UsbPlaylistExportProgress(
          message: 'Cancelling after this step...',
          completedItems: current.completedItems,
          totalItems: current.totalItems,
          deviceLabel: current.deviceLabel,
          stage: current.stage,
        );
      }
    });
  }

  Future<void> _markSafeToRemove() async {
    final rootUri = _result?.rootUri;
    if (rootUri == null || rootUri.isEmpty || _released) {
      return;
    }
    try {
      await UsbPlaylistExporter.instance.releaseDevice(rootUri);
      if (!mounted) {
        return;
      }
      setState(() {
        _released = true;
        _progress = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _released = true;
        _progress = null;
      });
    }
  }

  Future<void> _closeDialog() async {
    if (!_released) {
      try {
        await UsbPlaylistExporter.instance.releaseDevice(widget.target.rootUri);
      } catch (_) {
        // The user-facing action is simply leaving the screen; release errors
        // are not actionable for parents.
      }
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _friendlyUsbExportError(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'no_usb_device':
          return 'Connect a StoryVault storage device and try again.';
        case 'usb_open_failed':
        case 'usb_export_failed':
        case 'copy_failed':
        case 'delete_failed':
        case 'list_failed':
        case 'read_failed':
        case 'write_failed':
        case 'device_info_failed':
          return 'Oops, something went wrong with the USB device. Remove it, plug it back in, and try exporting again.';
        case 'usb_permission_pending':
          return 'Please finish the storage permission request first.';
        case 'unsupported_target':
          return 'Please choose a StoryVault USB storage device.';
      }
    }
    if (error is UnsupportedError) {
      return 'Please choose a StoryVault USB storage device.';
    }
    if (error is StateError) {
      return error.message;
    }
    return 'Oops, something went wrong. Try again.';
  }

  int _stageIndex(UsbPlaylistExportStage? stage) {
    switch (stage) {
      case UsbPlaylistExportStage.downloading:
        return 0;
      case UsbPlaylistExportStage.preparing:
        return 1;
      case UsbPlaylistExportStage.clearing:
        return 2;
      case UsbPlaylistExportStage.copying:
        return 3;
      case UsbPlaylistExportStage.finalizing:
        return 4;
      case UsbPlaylistExportStage.complete:
      case UsbPlaylistExportStage.cancelled:
        return 5;
      case null:
        return -1;
    }
  }

  Widget _buildStageRow({
    required String label,
    required int index,
    required int activeIndex,
    required bool stopped,
  }) {
    final completed = activeIndex > index;
    final active = activeIndex == index && !stopped;
    final color = completed
        ? SunshineColors.success
        : active
        ? SunshineColors.deepBlue
        : SunshineColors.darkText.withValues(alpha: 0.28);
    final status = completed
        ? 'Done'
        : active
        ? 'Now'
        : 'Pending';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.check_circle_rounded
                : active
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SunshineColors.darkText,
              ),
            ),
          ),
          Text(
            status,
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SunshineColors.mintGreen.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: SunshineColors.mintGreen.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: SunshineColors.mintGreen.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.usb_rounded, color: SunshineColors.success),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Writing to',
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.darkText.withValues(alpha: 0.58),
                  ),
                ),
                Text(
                  _deviceLabel ?? widget.target.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.darkText,
                  ),
                ),
                Text(
                  widget.target.freeSpaceLabel,
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.success,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferCard(UsbPlaylistExportProgress? progress) {
    final total = progress?.totalItems ?? _selectedPlaylist?.items.length ?? 0;
    final completed = progress?.completedItems ?? 0;
    final fraction = total <= 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
    final percent = (fraction * 100).round();
    final stopped = progress?.stage == UsbPlaylistExportStage.cancelled;
    final finished = progress?.stage == UsbPlaylistExportStage.complete;
    final stage = progress?.stage;
    final activeIndex = _stageIndex(progress?.stage);
    final progressColor = finished
        ? SunshineColors.success
        : stopped
        ? SunshineColors.warmOrange
        : SunshineColors.deepBlue;
    final title = _cancelling
        ? 'Cancelling...'
        : stopped
        ? 'Stopped safely'
        : progress?.message ?? 'Ready to copy';
    final String subtitle;
    if (total <= 0) {
      subtitle = 'Preparing playlist';
    } else if (stage == UsbPlaylistExportStage.downloading) {
      subtitle = '$completed of $total files ready';
    } else if (stage == UsbPlaylistExportStage.preparing ||
        stage == UsbPlaylistExportStage.clearing ||
        stage == UsbPlaylistExportStage.finalizing) {
      subtitle = 'Getting the device ready';
    } else {
      subtitle = '$completed of $total items copied';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SunshineColors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: SunshineColors.deepBlue.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 86,
                height: 86,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: fraction <= 0 ? null : fraction,
                        strokeWidth: 8,
                        backgroundColor: SunshineColors.lavender.withValues(
                          alpha: 0.18,
                        ),
                        color: progressColor,
                      ),
                    ),
                    Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: SunshineColors.white.withValues(alpha: 0.96),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: SunshineColors.deepBlue.withValues(
                              alpha: 0.08,
                            ),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$percent%',
                          maxLines: 1,
                          style: GoogleFonts.nunito(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: progressColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.nunito(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: SunshineColors.darkText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: GoogleFonts.nunito(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SunshineColors.deepBlue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: total <= 0 ? null : fraction,
            minHeight: 7,
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 12),
          _buildStageRow(
            label: 'Downloading playlist files',
            index: 0,
            activeIndex: activeIndex,
            stopped: stopped,
          ),
          _buildStageRow(
            label: 'Preparing device',
            index: 1,
            activeIndex: activeIndex,
            stopped: stopped,
          ),
          _buildStageRow(
            label: 'Clearing old audio files',
            index: 2,
            activeIndex: activeIndex,
            stopped: stopped,
          ),
          _buildStageRow(
            label: 'Copying files',
            index: 3,
            activeIndex: activeIndex,
            stopped: stopped,
          ),
          _buildStageRow(
            label: 'Finalizing playlist',
            index: 4,
            activeIndex: activeIndex,
            stopped: stopped,
          ),
        ],
      ),
    );
  }

  Widget _buildResultNotice(UsbPlaylistExportResult result) {
    final success = !result.cancelled && result.failed == 0;
    final text = success
        ? 'Playlist copied successfully. Tap Safe to Remove before unplugging the device.'
        : result.usbIoFailure
        ? 'USB writing did not complete. Tap Safe to Remove, unplug the device, plug it back in, and try exporting again.'
        : 'Some playlist files could not be downloaded. Check your internet connection or content access, then try again.';
    final color = success
        ? SunshineColors.success
        : result.usbIoFailure
        ? SunshineColors.warmOrange
        : SunshineColors.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: GoogleFonts.nunito(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: success
              ? SunshineColors.success
              : SunshineColors.darkText.withValues(alpha: 0.76),
        ),
      ),
    );
  }

  Widget _buildUsbPrimaryButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    bool success = false,
    double minWidth = 172,
  }) {
    final enabled = onPressed != null;
    final colors = success
        ? [SunshineColors.success, SunshineColors.mintGreen]
        : [SunshineColors.deepBlue, SunshineColors.skyBlue];
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: enabled
              ? LinearGradient(colors: colors)
              : LinearGradient(
                  colors: [
                    SunshineColors.darkText.withValues(alpha: 0.16),
                    SunshineColors.darkText.withValues(alpha: 0.10),
                  ],
                ),
          borderRadius: BorderRadius.circular(999),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: colors.first.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 9),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: SunshineColors.white.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: SunshineColors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: SunshineColors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = UsbPlaylistExporter.instance.supported;
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final playlists = widget.playlists;
    final progress = _progress;
    final result = _result;
    final canRemove =
        result != null && result.rootUri != null && !_released && !_exporting;
    final done = result != null && _released;
    final selectedPlaylist = _selectedPlaylist;
    final lockedCount = _selectedLockedItemCount;
    final accessibleCount = selectedPlaylist == null
        ? 0
        : selectedPlaylist.itemCount - lockedCount;
    final canExport =
        supported &&
        playlists.isNotEmpty &&
        !_exporting &&
        result == null &&
        accessibleCount > 0;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
      actionsPadding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      actionsAlignment: canRemove
          ? MainAxisAlignment.center
          : MainAxisAlignment.end,
      actionsOverflowAlignment: canRemove
          ? OverflowBarAlignment.center
          : OverflowBarAlignment.end,
      title: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: SunshineColors.lavender.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.library_music_rounded,
              color: SunshineColors.deepBlue,
              size: 30,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Copy Playlist to USB',
              style: GoogleFonts.nunito(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: SunshineColors.darkText,
              ),
            ),
          ),
          IconButton(
            onPressed: _exporting ? null : _closeDialog,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                supported
                    ? isIos
                          ? 'Choose one playlist. StoryVault writes numbered MP3 files to the USB root folder you selected in Files.'
                          : 'Choose one playlist. StoryVault writes numbered MP3 files for simple USB speakers.'
                    : 'USB playlist export is currently available on Android and iOS only.',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: SunshineColors.darkText.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SunshineColors.warmOrange.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: SunshineColors.warmOrange.withValues(alpha: 0.32),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: SunshineColors.warmOrange,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Root MP3/WAV files on this device may be replaced before copying. Other files and folders are left alone.',
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: SunshineColors.darkText.withValues(
                            alpha: 0.74,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildDeviceCard(),
              const SizedBox(height: 16),
              Text(
                'Select Playlist',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: SunshineColors.darkText,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _selectedPlaylistId,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: playlists
                    .map(
                      (playlist) => DropdownMenuItem<String>(
                        value: playlist.id,
                        child: Text(
                          '${playlist.title} (${playlist.itemCount})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _exporting || result != null
                    ? null
                    : (value) => setState(() {
                        _selectedPlaylistId = value;
                        _error = null;
                        _progress = null;
                        _result = null;
                        _released = false;
                      }),
              ),
              if (selectedPlaylist != null && lockedCount > 0) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SunshineColors.warmOrange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    accessibleCount > 0
                        ? 'You have access to $accessibleCount of ${selectedPlaylist.itemCount} rhymes/stories in this playlist. Only those will be copied.'
                        : 'You do not have access to any rhymes/stories in this playlist yet.',
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.darkText.withValues(alpha: 0.74),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: SunshineColors.error.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _error!,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.error,
                    ),
                  ),
                )
              else if (result != null && _released)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SunshineColors.deepBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'Safe to remove device.',
                    style: GoogleFonts.nunito(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: SunshineColors.deepBlue,
                    ),
                  ),
                )
              else if (progress != null || _exporting || result != null) ...[
                _buildTransferCard(progress),
                if (result != null) ...[
                  const SizedBox(height: 10),
                  _buildResultNotice(result),
                ],
              ] else
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SunshineColors.deepBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'Ready to copy. Keep the device connected until StoryVault says it is safe to remove.',
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.darkText.withValues(alpha: 0.70),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (_exporting)
          TextButton.icon(
            onPressed: _cancelling ? null : _requestCancel,
            icon: _cancelling
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.close_rounded),
            label: Text(_cancelling ? 'Cancelling...' : 'Cancel'),
          )
        else if (canRemove)
          _buildUsbPrimaryButton(
            onPressed: _markSafeToRemove,
            icon: Icons.eject_rounded,
            label: 'Safe to Remove Device',
            success: true,
            minWidth: 260,
          )
        else if (done)
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check_circle_rounded),
            label: const Text('Done'),
          )
        else ...[
          TextButton(onPressed: _closeDialog, child: const Text('Cancel')),
          _buildUsbPrimaryButton(
            onPressed: canExport ? _startExport : null,
            icon: Icons.file_upload_rounded,
            label: 'Start Copy',
          ),
        ],
      ],
    );
  }
}

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color color;
  const _MenuButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.color = SunshineColors.deepBlue,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: sunshineCardDecoration(),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.darkText,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: SunshineColors.darkText.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: SunshineColors.darkText.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
