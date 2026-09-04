import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/launcher/launcher_screen.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';

void main() {
  // The window the editor actually opens at. The default test surface is
  // smaller than the app's own minimum, which puts real controls below the
  // fold and tests a layout nobody will ever see.
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  Future<void> atEditorSize(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: orbisTheme(), home: child));
    await tester.pumpAndSettle();
  }

  testWidgets('the launcher opens on the project list', (tester) async {
    await atEditorSize(tester, LauncherScreen(onOpen: (_) {}));

    // The list, not the form. Somebody opening the editor is usually coming
    // back to something rather than starting from nothing.
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Create project'), findsNothing,
        reason: 'the create form should not be what greets you');
  });

  testWidgets('the rail moves between the two views', (tester) async {
    await atEditorSize(tester, LauncherScreen(onOpen: (_) {}));

    await tester.tap(find.text('New project').last);
    await tester.pumpAndSettle();
    expect(find.text('Create project'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Create project'), findsNothing);
  });
}
