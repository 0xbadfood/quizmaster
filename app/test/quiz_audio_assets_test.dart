import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter owns quiz result sound effects', () {
    final manifestFile = File('assets/audio/quiz_audio_manifest.json');
    expect(manifestFile.existsSync(), isTrue);
    final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
    expect(manifest, isNot(contains('correct_feedback_clips')));
    expect(manifest, isNot(contains('incorrect_feedback_clips')));

    for (final relativePath in [
      manifest['correct_sfx'],
      manifest['incorrect_sfx'],
    ]) {
      expect(relativePath, endsWith('.mp3'));
      expect(File('assets/$relativePath').existsSync(), isTrue);
    }
  });
}
