import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_shell');
    Directory(p.join(root.path, 'scenes')).createSync();
    File(p.join(root.path, 'scenes', 'main.orbisscene')).writeAsStringSync('{}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    // The editor's real minimum. At the default 800x600 the panels sit below
    // the fold and a test passes while nothing is on screen.
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: EditorShell(
        project: Project(
          name: 'Test',
          directory: root.path,
          lastOpened: DateTime(2026),
        ),
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Adds through the Add menu.
  ///
  /// Scoped to the menu item, because find.text also matches the outliner row
  /// and the inspector's name field — an unscoped tap on "Cube" selects the
  /// cube that is already there instead of making one.
  Future<void> add(WidgetTester tester, String label) async {
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  /// A row in the outliner, rather than the same name in the inspector's
  /// title field or in a menu.
  Finder row(String name) => find.descendant(
        of: find.byType(Draggable<String>),
        matching: find.text(name),
      );

  testWidgets('the tree shows what is nested inside what', (tester) async {
    await open(tester);

    // Props holds two meshes in the starter scene, so all four are on screen.
    expect(row('Props'), findsOneWidget);
    expect(row('Cube'), findsOneWidget);
    expect(row('Crate'), findsOneWidget);
  });

  testWidgets('collapsing a parent hides its children', (tester) async {
    await open(tester);

    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();

    expect(row('Props'), findsOneWidget);
    expect(row('Crate'), findsNothing);
  });

  testWidgets('selecting shows that object in the inspector', (tester) async {
    await open(tester);

    await tester.tap(row('Ground'));
    await tester.pumpAndSettle();

    // The name field carries the selection.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, 'Ground');
  });

  testWidgets('dragging a transform number changes it, and undo puts it back',
      (tester) async {
    await open(tester);
    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();

    String positionX() => tester
        .widgetList<Text>(find.descendant(
          of: find.byType(Row),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .firstWhere((d) => d == '2.20', orElse: () => '')!;

    expect(positionX(), '2.20', reason: 'the crate starts at x 2.2');

    // One gesture made of many moves, which is one undo step.
    final field = find.text('2.20');
    final gesture = await tester.startGesture(tester.getCenter(field));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('2.20'), findsNothing, reason: 'the drag did nothing');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(find.text('2.20'), findsOneWidget,
        reason: 'one undo should cover the whole drag');
  });

  testWidgets('adding puts a new object in and undo takes it out',
      (tester) async {
    await open(tester);

    await add(tester, 'Group');

    expect(find.textContaining('Add Group'), findsOneWidget,
        reason: 'the status bar should name the last change');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(find.textContaining('Add Group'), findsNothing);
  });

  testWidgets('a second object of the same kind gets its own name',
      (tester) async {
    await open(tester);

    await add(tester, 'Group');
    await add(tester, 'Group');

    expect(find.textContaining('Add Group 2'), findsOneWidget);
  });

  testWidgets('the project browser lists what is on disk', (tester) async {
    await open(tester);

    expect(find.text('PROJECT'), findsOneWidget);
    expect(find.text('scenes'), findsWidgets);
  });

  testWidgets('opening a folder shows its files', (tester) async {
    await open(tester);

    // The tile in the grid, not the row in the folder tree beside it. A tile
    // opens on a double tap; a single one only selects.
    await tester.tap(find.descendant(
      of: find.byType(GridView),
      matching: find.text('scenes'),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.descendant(
      of: find.byType(GridView),
      matching: find.text('scenes'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('main.orbisscene'), findsOneWidget);
  });

  testWidgets('undo is offered only once there is something to undo',
      (tester) async {
    await open(tester);
    expect(find.byTooltip('Nothing to undo'), findsOneWidget);

    await add(tester, 'Cube');

    expect(find.byTooltip('Nothing to undo'), findsNothing);
    expect(find.byTooltip('Undo Add Cube 2'), findsOneWidget);
  });
}
