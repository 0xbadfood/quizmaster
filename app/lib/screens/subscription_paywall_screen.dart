import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/content_item.dart';
import '../theme/app_theme.dart';

class SubscriptionPaywallScreen extends StatefulWidget {
  const SubscriptionPaywallScreen({super.key, this.lockedItem});

  final ContentItem? lockedItem;

  @override
  State<SubscriptionPaywallScreen> createState() =>
      _SubscriptionPaywallScreenState();
}

class _SubscriptionPaywallScreenState extends State<SubscriptionPaywallScreen> {
  static const _plans = <_SubscriptionPlan>[
    _SubscriptionPlan(
      id: 'monthly',
      title: 'Monthly',
      indiaPrice: '₹199',
      globalPrice: r'$2',
      cadence: 'per month',
      asset: 'assets/paywall/paywall_v2_monthly_plan.png',
    ),
    _SubscriptionPlan(
      id: 'yearly',
      title: 'Yearly',
      indiaPrice: '₹1799',
      globalPrice: r'$18',
      cadence: 'per year',
      asset: 'assets/paywall/paywall_v2_yearly_plan.png',
      badge: 'BEST VALUE',
    ),
  ];

  String _selectedPlanId = 'yearly';

  bool _isIndiaMarket(BuildContext context) {
    final countryCode = Localizations.localeOf(context).countryCode;
    return countryCode?.toUpperCase() == 'IN';
  }

  _SubscriptionPlan get _selectedPlan => _plans.firstWhere(
    (plan) => plan.id == _selectedPlanId,
    orElse: () => _plans.last,
  );

  void _startSubscription(bool isIndiaMarket) {
    final plan = _selectedPlan;
    final price = plan.priceFor(isIndiaMarket);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Store checkout is not connected in this build yet. Selected: ${plan.title} at $price.',
        ),
      ),
    );
  }

  void _openLegal(String title, String body) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _LegalPlaceholderScreen(title: title, body: body),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isIndiaMarket = _isIndiaMarket(context);

    return Scaffold(
      backgroundColor: SunshineColors.deepBlue,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/paywall/paywall_background_fairy_garden.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    SunshineColors.deepBlue.withValues(alpha: 0.20),
                    SunshineColors.deepBlue.withValues(alpha: 0.04),
                    SunshineColors.deepBlue.withValues(alpha: 0.46),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 700;
                final horizontalPadding = constraints.maxWidth < 380
                    ? 12.0
                    : 16.0;
                final gap = compact ? 6.0 : 8.0;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    compact ? 8 : 10,
                    horizontalPadding,
                    compact ? 8 : 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _RoundIconButton(
                            icon: Icons.close_rounded,
                            compact: compact,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const Spacer(),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 10 : 12,
                              vertical: compact ? 6 : 7,
                            ),
                            decoration: BoxDecoration(
                              color: SunshineColors.white.withValues(
                                alpha: 0.92,
                              ),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              isIndiaMarket
                                  ? 'India preview pricing'
                                  : 'Global preview pricing',
                              style: GoogleFonts.nunito(
                                fontSize: compact ? 11 : 12,
                                fontWeight: FontWeight.w900,
                                color: SunshineColors.deepBlue,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: gap),
                      const Flexible(
                        flex: 58,
                        child: _ImagePlate(
                          asset: 'assets/paywall/paywall_v2_hero_info.png',
                          aspectRatio: 1080 / 660,
                        ),
                      ),
                      SizedBox(height: gap),
                      Flexible(
                        flex: 29,
                        child: _PlanImageCard(
                          plan: _plans[0],
                          selected: _selectedPlanId == _plans[0].id,
                          price: _plans[0].priceFor(isIndiaMarket),
                          compact: compact,
                          onTap: () =>
                              setState(() => _selectedPlanId = _plans[0].id),
                        ),
                      ),
                      SizedBox(height: gap),
                      Flexible(
                        flex: 29,
                        child: _PlanImageCard(
                          plan: _plans[1],
                          selected: _selectedPlanId == _plans[1].id,
                          price: _plans[1].priceFor(isIndiaMarket),
                          compact: compact,
                          onTap: () =>
                              setState(() => _selectedPlanId = _plans[1].id),
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 10),
                      ElevatedButton(
                        onPressed: () => _startSubscription(isIndiaMarket),
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, compact ? 50 : 56),
                          backgroundColor: SunshineColors.sunshineYellow,
                          foregroundColor: SunshineColors.darkText,
                          shadowColor: SunshineColors.warmOrange.withValues(
                            alpha: 0.45,
                          ),
                          elevation: 8,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: Text(
                          'Unlock Full Library',
                          style: GoogleFonts.nunito(
                            fontSize: compact ? 17 : 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      SizedBox(height: compact ? 4 : 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                            ),
                            child: Text(
                              'Not now',
                              style: GoogleFonts.nunito(
                                fontSize: compact ? 12 : 13,
                                fontWeight: FontWeight.w900,
                                color: SunshineColors.white,
                              ),
                            ),
                          ),
                          _LegalDivider(compact: compact),
                          _LegalLink(
                            label: 'Terms',
                            onTap: () =>
                                _openLegal('Terms of Use', _termsPlaceholder),
                          ),
                          _LegalDivider(compact: compact),
                          _LegalLink(
                            label: 'Privacy',
                            onTap: () => _openLegal(
                              'Privacy Policy',
                              _privacyPlaceholder,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Final prices and billing terms will come from Google Play or the App Store.',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.nunito(
                          fontSize: compact ? 9.5 : 10.5,
                          fontWeight: FontWeight.w800,
                          color: SunshineColors.white.withValues(alpha: 0.84),
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ImagePlate extends StatelessWidget {
  const _ImagePlate({required this.asset, required this.aspectRatio});

  final String asset;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: constraints.maxHeight,
            ),
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(asset, fit: BoxFit.cover),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlanImageCard extends StatelessWidget {
  const _PlanImageCard({
    required this.plan,
    required this.selected,
    required this.price,
    required this.compact,
    required this.onTap,
  });

  final _SubscriptionPlan plan;
  final bool selected;
  final String price;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${plan.title} subscription, $price ${plan.cadence}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: selected
                    ? SunshineColors.sunshineYellow
                    : SunshineColors.white.withValues(alpha: 0.55),
                width: selected ? 4 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: selected ? 0.24 : 0.14),
                  blurRadius: selected ? 18 : 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(plan.asset, fit: BoxFit.cover),
                  if (selected)
                    Positioned(
                      left: 10,
                      top: 10,
                      child: Container(
                        width: compact ? 26 : 30,
                        height: compact ? 26 : 30,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: SunshineColors.sunshineYellow,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: SunshineColors.darkText,
                        ),
                      ),
                    ),
                  Positioned(
                    right: 18,
                    top: 0,
                    bottom: 0,
                    width: 118,
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (plan.badge != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 3),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: SunshineColors.purpleText.withValues(
                                    alpha: 0.92,
                                  ),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  plan.badge!,
                                  style: GoogleFonts.nunito(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                    color: SunshineColors.white,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                            Text(
                              plan.title,
                              style: GoogleFonts.nunito(
                                fontSize: compact ? 15 : 16,
                                fontWeight: FontWeight.w900,
                                color: SunshineColors.deepBlue,
                                height: 0.9,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              price,
                              style: GoogleFonts.nunito(
                                fontSize: compact ? 25 : 29,
                                fontWeight: FontWeight.w900,
                                color: SunshineColors.purpleText,
                                height: 0.92,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              plan.cadence,
                              style: GoogleFonts.nunito(
                                fontSize: compact ? 10 : 11,
                                fontWeight: FontWeight.w900,
                                color: SunshineColors.darkText.withValues(
                                  alpha: 0.72,
                                ),
                              ),
                            ),
                          ],
                        ),
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
}

class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Text(
        label,
        style: GoogleFonts.nunito(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: SunshineColors.white,
        ),
      ),
    );
  }
}

class _LegalDivider extends StatelessWidget {
  const _LegalDivider({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Text(
      '|',
      style: TextStyle(
        fontSize: compact ? 11 : 12,
        color: SunshineColors.white.withValues(alpha: 0.6),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
    this.compact = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: SunshineColors.white.withValues(alpha: 0.88),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        constraints: BoxConstraints.tightFor(
          width: compact ? 38 : 44,
          height: compact ? 38 : 44,
        ),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, color: SunshineColors.deepBlue),
      ),
    );
  }
}

class _LegalPlaceholderScreen extends StatelessWidget {
  const _LegalPlaceholderScreen({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SunshineColors.skyBlue,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: SunshineColors.skyGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _RoundIconButton(
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: GoogleFonts.nunito(
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                          color: SunshineColors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: sunshineCardDecoration(
                      color: SunshineColors.creamLight,
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        body,
                        style: GoogleFonts.nunito(
                          fontSize: 15,
                          height: 1.45,
                          fontWeight: FontWeight.w700,
                          color: SunshineColors.darkText,
                        ),
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

class _SubscriptionPlan {
  const _SubscriptionPlan({
    required this.id,
    required this.title,
    required this.indiaPrice,
    required this.globalPrice,
    required this.cadence,
    required this.asset,
    this.badge,
  });

  final String id;
  final String title;
  final String indiaPrice;
  final String globalPrice;
  final String cadence;
  final String asset;
  final String? badge;

  String priceFor(bool isIndiaMarket) =>
      isIndiaMarket ? indiaPrice : globalPrice;
}

const String _termsPlaceholder = '''
These StoryVault Terms of Use are placeholder copy for internal validation. Final legal text will describe account use, subscription billing, renewal, cancellation, parental responsibility, acceptable use, and content availability.

Subscriptions will be processed through Google Play or the App Store where applicable. The store confirmation screen will show final pricing, renewal terms, and cancellation instructions before purchase.

StoryVault content is licensed for personal family use only. Downloaded bundles and exported playlists are meant for use by the registered family and compatible StoryVault toy workflows.
''';

const String _privacyPlaceholder = '''
This StoryVault Privacy Policy is placeholder copy for internal validation. Final legal text will describe what parent account, child profile, purchase entitlement, and app diagnostic data may be collected.

StoryVault avoids phone numbers for V1 onboarding. Child quiz attempts and local usage history are intended to remain on device unless a future parent-approved sync or leaderboard feature is added.

Authentication and entitlement checks are handled by the StoryVault server. Content downloads use the minimum account information needed to decide whether the selected item is free or requires full library access.
''';
