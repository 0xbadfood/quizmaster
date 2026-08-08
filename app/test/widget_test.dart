import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunshine_app/widgets/bottom_dock.dart';

void main() {
  testWidgets('Bottom dock exposes Quiz launcher', (WidgetTester tester) async {
    DockItem tapped = DockItem.home;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: BottomDock(
            selectedItem: DockItem.home,
            onTap: (DockItem item) {
              tapped = item;
            },
          ),
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Rhymes'), findsOneWidget);
    expect(find.text('Stories'), findsOneWidget);
    expect(find.text('Quiz'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Parents'), findsOneWidget);

    await tester.tap(find.text('Quiz'));
    expect(tapped, DockItem.quiz);
  });
}
