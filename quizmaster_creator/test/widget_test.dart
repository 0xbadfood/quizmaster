import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizmaster_creator/src/app.dart';
import 'package:quizmaster_creator/src/state/app_controller.dart';
import 'package:quizmaster_creator/src/storage/settings_store.dart';

void main() {
  testWidgets('mobile shell exposes the three orchestration screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(settingsStore: MemorySettingsStore());
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(QuizmasterCreatorApp(controller: controller));
    await tester.pump();

    expect(find.text('Configure this run'), findsOneWidget);
    expect(find.text('Setup'), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
    expect(find.text('Runs'), findsOneWidget);
    expect(find.text('Connect to continue'), findsOneWidget);

    await tester.tap(find.text('Runs'));
    await tester.pump();

    expect(find.text('Production runs'), findsOneWidget);
    expect(find.text('No generation selected'), findsOneWidget);
  });
}
