import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Numeric keypad for PIN entry
class PinKeypad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;

  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildRow(['1', '2', '3']),
        const SizedBox(height: 10),
        _buildRow(['4', '5', '6']),
        const SizedBox(height: 10),
        _buildRow(['7', '8', '9']),
        const SizedBox(height: 10),
        _buildRow(['', '0', 'DEL']),
      ],
    );
  }

  Widget _buildRow(List<String> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: keys.map((key) {
        if (key.isEmpty) {
          return const SizedBox(width: 76, height: 56);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _KeyButton(
            label: key,
            onTap: key == 'DEL' ? () => onDelete() : () => onDigit(key),
            isDelete: key == 'DEL',
          ),
        );
      }).toList(),
    );
  }
}

class _KeyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isDelete;

  const _KeyButton({
    required this.label,
    required this.onTap,
    this.isDelete = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 76,
        height: 56,
        decoration: BoxDecoration(
          color: isDelete
              ? SunshineColors.warmOrange.withValues(alpha: 0.15)
              : SunshineColors.cream,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: isDelete
              ? const Icon(
                  Icons.backspace_rounded,
                  color: SunshineColors.warmOrange,
                  size: 22,
                )
              : Text(
                  label,
                  style: GoogleFonts.nunito(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: SunshineColors.purpleText,
                  ),
                ),
        ),
      ),
    );
  }
}
