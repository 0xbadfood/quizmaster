import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/background_scaffold.dart';

class RegisterToyScreen extends StatefulWidget {
  const RegisterToyScreen({super.key, this.onRedeemed});

  final VoidCallback? onRedeemed;

  @override
  State<RegisterToyScreen> createState() => _RegisterToyScreenState();
}

class _RegisterToyScreenState extends State<RegisterToyScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    if (_busy) {
      return;
    }
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the toy code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().redeemToyCode(code);
      if (!mounted) {
        return;
      }
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle,
                size: 64,
                color: SunshineColors.mintGreen,
              ),
              const SizedBox(height: 12),
              Text(
                'Toy Linked',
                style: GoogleFonts.nunito(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: SunshineColors.purpleText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Full library access is now active on this account.',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRedeemed?.call();
                },
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return BackgroundScaffold(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: SunshineColors.white,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Link Your Toy',
                        style: GoogleFonts.nunito(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: sunshineCardDecoration(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.smart_toy,
                        size: 58,
                        color: SunshineColors.lavender,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        appState.customerEntitled
                            ? 'Full library active'
                            : 'Redeem Toy Code',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.nunito(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.purpleText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        appState.hasCustomerSession
                            ? 'Enter the 8-character code bundled with the toy.'
                            : 'Sign in first, then return here to redeem the toy code.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.darkText.withValues(
                            alpha: 0.72,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Toy Code',
                        style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.darkText,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _codeController,
                        enabled:
                            appState.hasCustomerSession &&
                            !appState.customerEntitled &&
                            !_busy,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          hintText: 'Z54E5N4D',
                          suffixIcon: Icon(Icons.confirmation_number),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      ElevatedButton(
                        onPressed:
                            appState.hasCustomerSession &&
                                !appState.customerEntitled &&
                                !_busy
                            ? _redeem
                            : null,
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Redeem Code'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SunshineColors.cream.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 18,
                        color: SunshineColors.lavender,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Each toy code can be used once and attaches full-library access to the signed-in parent account.',
                          style: GoogleFonts.nunito(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
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
        ),
      ),
    );
  }
}
