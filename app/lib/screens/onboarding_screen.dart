import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../customer/customer_auth_service.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/background_scaffold.dart';
import 'settings_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _parentNameController = TextEditingController();
  final TextEditingController _childNameController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();
  String _ageGroup = '5-8';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _parentNameController.dispose();
    _childNameController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() {
    return _run((appState) => appState.signInWithGoogle());
  }

  Future<void> _signInWithApple() {
    return _run((appState) => appState.signInWithApple());
  }

  Future<void> _run(Future<void> Function(AppState appState) action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(context.read<AppState>());
    } on CustomerAuthCanceledException {
      // Provider sheet was dismissed or account resolution was canceled.
      // Keep the user on the login screen without showing an error.
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = friendlyConnectionMessage(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _saveParent() {
    final name = _parentNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the parent name.');
      return Future<void>.value();
    }
    return _run((appState) => appState.updateParentProfile(name));
  }

  Future<void> _saveChild() {
    final name = _childNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the child name.');
      return Future<void>.value();
    }
    return _run(
      (appState) =>
          appState.createChildProfile(nickname: name, ageGroup: _ageGroup),
    );
  }

  Future<void> _savePin() {
    final pin = _pinController.text.trim();
    final confirm = _confirmPinController.text.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      setState(() => _error = 'PIN must be exactly 4 digits.');
      return Future<void>.value();
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN confirmation does not match.');
      return Future<void>.value();
    }
    return _run((appState) => appState.setParentPin(pin));
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final profile = appState.customerProfile;

    final Widget body;
    if (!appState.hasCustomerSession) {
      body = _AuthStep(
        showApple: defaultTargetPlatform == TargetPlatform.iOS,
        showGoogle:
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS,
        busy: _busy,
        error: _error,
        onApple: _signInWithApple,
        onGoogle: _signInWithGoogle,
        onSettings: _openSettings,
      );
    } else if (profile == null) {
      body = _ProfileLoadStep(
        error: appState.customerSessionError,
        onRetry: () => _run((appState) => appState.refreshCustomerProfile()),
        onSignOut: () => _run((appState) => appState.signOutCustomer()),
      );
    } else if (profile.parentDisplayName.trim().isEmpty) {
      body = _FormStep(
        title: 'Parent Setup',
        subtitle: 'Add the parent name used for account and support screens.',
        icon: Icons.supervisor_account,
        error: _error,
        busy: _busy,
        buttonText: 'Continue',
        onPressed: _saveParent,
        children: [
          _InputLabel('Parent Name'),
          TextField(
            controller: _parentNameController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(hintText: 'Your name'),
          ),
        ],
      );
    } else if (profile.children.isEmpty) {
      body = _FormStep(
        title: 'Child Profile',
        subtitle: 'StoryVault uses this age band for story filters.',
        icon: Icons.child_care,
        error: _error,
        busy: _busy,
        buttonText: 'Create Profile',
        onPressed: _saveChild,
        children: [
          _InputLabel('Child Name'),
          TextField(
            controller: _childNameController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: 'Nickname'),
          ),
          const SizedBox(height: 14),
          _InputLabel('Age Range'),
          DropdownButtonFormField<String>(
            initialValue: _ageGroup,
            items: const [
              DropdownMenuItem(value: '3-5', child: Text('3-5 years')),
              DropdownMenuItem(value: '5-8', child: Text('5-8 years')),
              DropdownMenuItem(value: '8-10', child: Text('8-10 years')),
              DropdownMenuItem(value: '10-12', child: Text('10-12 years')),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _ageGroup = value);
              }
            },
          ),
        ],
      );
    } else if (!profile.pinSet) {
      body = _FormStep(
        title: 'Parent PIN',
        subtitle: 'Protect purchases, settings, and parent controls.',
        icon: Icons.lock,
        error: _error,
        busy: _busy,
        buttonText: 'Finish Setup',
        onPressed: _savePin,
        children: [
          _InputLabel('PIN'),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              hintText: '4 digits',
              counterText: '',
            ),
          ),
          const SizedBox(height: 14),
          _InputLabel('Confirm PIN'),
          TextField(
            controller: _confirmPinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              hintText: 'Repeat PIN',
              counterText: '',
            ),
          ),
        ],
      );
    } else {
      body = _ProfileLoadStep(
        error: null,
        onRetry: () => _run((appState) => appState.refreshCustomerProfile()),
        onSignOut: () => _run((appState) => appState.signOutCustomer()),
      );
    }

    return BackgroundScaffold(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'StoryVault',
                        style: GoogleFonts.nunito(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _openSettings,
                      icon: const Icon(
                        Icons.settings,
                        color: SunshineColors.white,
                      ),
                      tooltip: 'Settings',
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Set up a parent account before opening the production library.',
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: SunshineColors.white.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: 22),
                body,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthStep extends StatelessWidget {
  const _AuthStep({
    required this.showApple,
    required this.showGoogle,
    required this.busy,
    required this.error,
    required this.onApple,
    required this.onGoogle,
    required this.onSettings,
  });

  final bool showApple;
  final bool showGoogle;
  final bool busy;
  final String? error;
  final Future<void> Function() onApple;
  final Future<void> Function() onGoogle;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: sunshineCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.auto_stories,
            size: 58,
            color: SunshineColors.lavender,
          ),
          const SizedBox(height: 14),
          Text(
            'Create your parent account',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Production access uses Apple or Google sign-in. Toy codes and subscriptions attach to this account.',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: SunshineColors.darkText.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 22),
          if (showApple)
            ElevatedButton.icon(
              onPressed: busy ? null : () => onApple(),
              icon: const Icon(Icons.apple),
              label: const Text('Continue with Apple'),
            ),
          if (showGoogle)
            ElevatedButton.icon(
              onPressed: busy ? null : () => onGoogle(),
              icon: const Icon(Icons.g_mobiledata, size: 28),
              label: const Text('Continue with Google'),
            ),
          if (!showApple && !showGoogle)
            Text(
              'Production sign-in is enabled on Android and iOS devices.',
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SunshineColors.darkText.withValues(alpha: 0.72),
              ),
            ),
          if (busy) ...[
            const SizedBox(height: 14),
            const Center(child: CircularProgressIndicator()),
          ],
          if (error != null) ...[
            const SizedBox(height: 14),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: SunshineColors.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextButton(
            onPressed: onSettings,
            child: const Text('Use sandbox for testing'),
          ),
        ],
      ),
    );
  }
}

class _ProfileLoadStep extends StatelessWidget {
  const _ProfileLoadStep({
    required this.error,
    required this.onRetry,
    required this.onSignOut,
  });

  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: sunshineCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.cloud_sync,
            size: 54,
            color: SunshineColors.lavender,
          ),
          const SizedBox(height: 14),
          Text(
            'Loading account',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error ?? 'Checking your StoryVault profile...',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: error == null
                  ? SunshineColors.darkText.withValues(alpha: 0.72)
                  : SunshineColors.error,
            ),
          ),
          const SizedBox(height: 18),
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onSignOut, child: const Text('Sign Out')),
        ],
      ),
    );
  }
}

class _FormStep extends StatelessWidget {
  const _FormStep({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
    required this.buttonText,
    required this.onPressed,
    required this.busy,
    this.error,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;
  final String buttonText;
  final Future<void> Function() onPressed;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: sunshineCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, size: 54, color: SunshineColors.lavender),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: SunshineColors.purpleText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: SunshineColors.darkText.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 20),
          ...children,
          if (error != null) ...[
            const SizedBox(height: 14),
            Text(
              error!,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: SunshineColors.error,
              ),
            ),
          ],
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: busy ? null : () => onPressed(),
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(buttonText),
          ),
        ],
      ),
    );
  }
}

class _InputLabel extends StatelessWidget {
  const _InputLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: GoogleFonts.nunito(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: SunshineColors.darkText,
        ),
      ),
    );
  }
}
