class StoryWizardAssets {
  const StoryWizardAssets._();

  static const String _spaceCaptainRoot =
      'assets/story_wizards/space_adventure_captain';

  static const Set<String> _spaceChoiceStems = <String>{
    'companion_astro_bot',
    'companion_bubble_alien',
    'companion_glow_bug_swarm',
    'companion_meteor_dragon',
    'companion_moon_mouse',
    'companion_space_whale_calf',
    'companion_star_owl',
    'companion_talking_comet',
    'companion_tiny_telescope',
    'companion_wise_satellite',
    'feel_brave',
    'feel_cozy',
    'feel_exciting',
    'feel_gentle',
    'feel_mysterious',
    'feel_silly',
    'feel_teamwork',
    'feel_wonder',
    'hero_curious_cadet',
    'hero_kind_robot',
    'hero_little_inventor',
    'hero_lost_star_child',
    'hero_moon_bunny',
    'hero_planet_painter',
    'hero_rocket_pup',
    'hero_starlight_kitten',
    'hero_tiny_alien_gardener',
    'hero_turtle_pilot',
    'length_long_orbit',
    'length_short_comet',
    'length_very_long_galaxy',
    'magic_comet_flute',
    'magic_crystal_lantern',
    'magic_glow_seed',
    'magic_gravity_boots',
    'magic_moon_key',
    'magic_nebula_blanket',
    'magic_rainbow_fuel',
    'magic_star_compass',
    'magic_time_pebble',
    'magic_whisper_helmet',
    'problem_broken_moon_bridge',
    'problem_dim_lighthouse',
    'problem_lost_star_map',
    'problem_meteor_maze',
    'problem_missing_planet_song',
    'problem_runaway_moon',
    'problem_sleeping_star',
    'problem_sleepy_robot',
    'problem_sparkle_storm',
    'problem_tangled_orbit',
    'setting_asteroid_garden',
    'setting_comet_harbor',
    'setting_crystalon',
    'setting_magmora',
    'setting_moonbay',
    'setting_nebula_nook',
    'setting_pillow_planet',
    'setting_ringland',
    'setting_starfall',
    'setting_verdantia',
    'surprise_me_space',
  };

  static bool supportsWizard(String wizardId) {
    return _slug(wizardId) == 'space_adventure_captain';
  }

  static String? backgroundFor(String wizardId) {
    if (!supportsWizard(wizardId)) {
      return null;
    }
    return '$_spaceCaptainRoot/background_space_nova.webp';
  }

  static String? personaFor(String wizardId) {
    if (!supportsWizard(wizardId)) {
      return null;
    }
    return '$_spaceCaptainRoot/persona_full_nova.webp';
  }

  static String? helperFor(String wizardId) {
    if (!supportsWizard(wizardId)) {
      return null;
    }
    return '$_spaceCaptainRoot/helper_bot_nova.webp';
  }

  static String? choiceFor({
    required String wizardId,
    required String choiceId,
    String imageAssetPath = '',
  }) {
    final String explicitAsset = imageAssetPath.trim();
    if (explicitAsset.startsWith('assets/')) {
      return explicitAsset;
    }
    if (!supportsWizard(wizardId)) {
      return null;
    }
    final String stem = _slug(choiceId);
    if (_spaceChoiceStems.contains(stem)) {
      return '$_spaceCaptainRoot/choices/$stem.webp';
    }
    return null;
  }

  static String _slug(String value) {
    final StringBuffer buffer = StringBuffer();
    bool wroteSeparator = false;
    for (final int rune in value.toLowerCase().runes) {
      final bool isLetter = rune >= 97 && rune <= 122;
      final bool isDigit = rune >= 48 && rune <= 57;
      if (isLetter || isDigit) {
        buffer.writeCharCode(rune);
        wroteSeparator = false;
      } else if (!wroteSeparator && buffer.isNotEmpty) {
        buffer.write('_');
        wroteSeparator = true;
      }
    }
    final String result = buffer.toString();
    return result.endsWith('_')
        ? result.substring(0, result.length - 1)
        : result;
  }
}
