import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/outliner.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_shell');
    Directory(p.join(root.path, 'scenes')).createSync();
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

  /// Picks an item out of a toolbar menu.
  Future<void> menu(WidgetTester tester, String button, String item) async {
    await tester.tap(find.textContaining(button).first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(item),
    ));
    await tester.pumpAndSettle();
  }

  /// Types into the dialog on screen and confirms it.
  Future<void> answerPrompt(WidgetTester tester, String text, String action) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(action),
    ));
    await tester.pumpAndSettle();
  }

  /// The unsaved marker in the status bar, rather than the one on the Scene
  /// menu — both are shown, in the two places somebody looks.
  Finder unsavedMarker() => find.descendant(
        of: find.byType(Row),
        matching: find.textContaining(RegExp(r'\.oscene •|Unsaved')),
      );

  /// Saves with the keyboard.
  Future<void> save(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
  }

  /// Opens a folder from the file grid.
  ///
  /// The grid tile rather than the folder-tree row beside it, because both
  /// carry the same text. A tile opens on a double tap; a single one selects.
  Future<void> openFolder(WidgetTester tester, String name) async {
    final tile = find.descendant(
      of: find.byType(GridView),
      matching: find.text(name),
    );
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  /// The hierarchy panel's own count, rather than the viewport's chip.
  Finder sceneCount(String text) => find.descendant(
        of: find.byType(Outliner),
        matching: find.textContaining(text),
      );

  /// An object's row in the outliner, rather than the same name in the
  /// inspector's title field or in a menu. Objects are draggable; scenes are
  /// headings and are not.
  Finder row(String name) => find.descendant(
        of: find.byType(Draggable<String>),
        matching: find.text(name),
      );

  /// The whole row a name sits in, rather than just its text — the text is
  /// centred, so its top-left is halfway down the row.
  Finder rowBox(String name) => find.ancestor(
        of: row(name),
        matching: find.byType(Draggable<String>),
      );

  /// A scene's own row.
  Finder sceneRow(String name) => find.descendant(
        of: find.byType(Outliner),
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

    // The first chevron belongs to the scene's own row; the second to Props.
    await tester.tap(find.byIcon(Icons.expand_more).at(1));
    await tester.pumpAndSettle();

    expect(row('Props'), findsOneWidget);
    expect(row('Crate'), findsNothing);
  });

  testWidgets('collapsing the scene hides everything in it', (tester) async {
    await open(tester);

    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();

    expect(row('Props'), findsNothing);
    expect(row('Ground'), findsNothing);
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

    File(p.join(root.path, 'scenes', 'notes.txt')).writeAsStringSync('x');
    await openFolder(tester, 'scenes');

    expect(find.text('notes.txt'), findsOneWidget);
  });

  testWidgets('undo is offered only once there is something to undo',
      (tester) async {
    await open(tester);
    expect(find.byTooltip('Nothing to undo'), findsOneWidget);

    await add(tester, 'Cube');

    expect(find.byTooltip('Nothing to undo'), findsNothing);
    expect(find.byTooltip('Undo Add Cube 2'), findsOneWidget);
  });

  testWidgets('saving writes a scene file that opens again', (tester) async {
    await open(tester);

    // Nothing has been written yet, so the status bar says so.
    expect(unsavedMarker(), findsOneWidget,
        reason: 'a fresh scene is unsaved and should be marked');

    await save(tester);

    final written = File(p.join(root.path, 'scenes', 'main$sceneExtension'));
    expect(written.existsSync(), isTrue);

    final load = SceneDocument.decode(written.readAsStringSync());
    expect(load.hasProblems, isFalse);
    expect(load.scene.childrenOf('props').length, 2,
        reason: 'the hierarchy should survive the save');
  });

  testWidgets('the unsaved marker clears on save and comes back on an edit',
      (tester) async {
    await open(tester);

    await save(tester);
    expect(unsavedMarker(), findsNothing);

    await add(tester, 'Group');
    expect(unsavedMarker(), findsOneWidget);
  });

  testWidgets('undoing back to the saved state reads as saved again',
      (tester) async {
    await open(tester);
    await save(tester);

    await add(tester, 'Group');
    expect(unsavedMarker(), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // Somebody who changed their mind has not changed the file.
    expect(unsavedMarker(), findsNothing);
  });

  testWidgets('a scene written by a newer editor is refused, not half-read',
      (tester) async {
    File(p.join(root.path, 'scenes', 'main$sceneExtension'))
        .writeAsStringSync('{"formatVersion": 99, "objects": []}');

    await open(tester);

    // The starter scene is still there rather than an empty one.
    expect(row('Props'), findsOneWidget);
    expect(find.textContaining('newer Orbis'), findsOneWidget);
  });

  testWidgets('an existing scene file is what opens', (tester) async {
    File(p.join(root.path, 'scenes', 'main$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([
      SceneObject(id: 'x', name: 'Only Thing', kind: ObjectKind.mesh),
    ])));

    await open(tester);

    expect(row('Only Thing'), findsOneWidget);
    expect(row('Props'), findsNothing, reason: 'the starter scene should not '
        'be used when there is a file');
  });

  testWidgets('dragging a mesh out of the browser puts it in the scene',
      (tester) async {
    Directory(p.join(root.path, 'assets')).createSync();
    File(p.join(root.path, 'assets', 'crate.glb')).writeAsBytesSync([1, 2]);

    await open(tester);
    await openFolder(tester, 'assets');

    final tile = find.descendant(
      of: find.byType(GridView),
      matching: find.text('crate.glb'),
    );
    expect(tile, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Named after the file, and recorded as referencing it.
    expect(row('crate'), findsOneWidget);
    expect(find.textContaining('Add crate'), findsOneWidget);
  });

  testWidgets('a texture dragged in is refused with a reason', (tester) async {
    Directory(p.join(root.path, 'assets')).createSync();
    File(p.join(root.path, 'assets', 'rock.png')).writeAsBytesSync([1]);

    await open(tester);
    await openFolder(tester, 'assets');

    final tile = find.descendant(
      of: find.byType(GridView),
      matching: find.text('rock.png'),
    );
    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Only meshes and scenes'), findsOneWidget);
    expect(row('rock'), findsNothing);
  });

  testWidgets('F frames the selection', (tester) async {
    await open(tester);
    await tester.tap(row('Ground'));
    await tester.pumpAndSettle();

    final before = tester
        .widget<SceneViewport>(find.byType(SceneViewport))
        .camera;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();

    final after =
        tester.widget<SceneViewport>(find.byType(SceneViewport)).camera;

    // The ground is wide, so framing it pulls the camera back.
    expect(after.distance, isNot(before.distance));
    expect(after.yaw, before.yaw, reason: 'framing should not change the angle');
  });

  testWidgets('save as writes a second scene and edits it from then on',
      (tester) async {
    await open(tester);
    await save(tester);

    await menu(tester, 'Scene', 'Save as…');
    await answerPrompt(tester, 'second', 'Save');

    expect(
      File(p.join(root.path, 'scenes', 'second$sceneExtension')).existsSync(),
      isTrue,
    );
    // And the first one is still there, rather than moved.
    expect(
      File(p.join(root.path, 'scenes', 'main$sceneExtension')).existsSync(),
      isTrue,
    );
    // Edits now go to the new file, which the status bar names.
    expect(
      find.descendant(
        of: find.byType(Row),
        matching: find.textContaining('scenes/second$sceneExtension'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('save as refuses to overwrite a scene that exists',
      (tester) async {
    File(p.join(root.path, 'scenes', 'taken$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([])));

    await open(tester);
    await menu(tester, 'Scene', 'Save as…');
    await answerPrompt(tester, 'taken', 'Save');

    expect(find.textContaining('already a scene'), findsOneWidget);
    // Untouched.
    expect(
      File(p.join(root.path, 'scenes', 'taken$sceneExtension'))
          .readAsStringSync(),
      SceneDocument.encode(EditorScene([])),
    );
  });

  testWidgets('a new scene opens alongside the one already there',
      (tester) async {
    await open(tester);
    await save(tester);

    await menu(tester, 'Scene', 'New scene');

    // Two scene rows now, not one replaced by another.
    expect(sceneCount('2 scenes'), findsOneWidget);
    expect(sceneRow('main'), findsOneWidget);
    expect(sceneRow('Untitled'), findsOneWidget);
  });

  testWidgets('closing a scene with changes asks first', (tester) async {
    await open(tester);
    await save(tester);
    await add(tester, 'Group');

    // The close action appears on the scene's row when it is hovered.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(sceneRow('main')));
    addTearDown(mouse.removePointer);
    await tester.pump();

    await tester.tap(find.byTooltip('Close main'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Save main first?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(sceneCount('0 scenes'), findsOneWidget);
  });

  testWidgets('a dropped mesh is recorded relative to the project',
      (tester) async {
    Directory(p.join(root.path, 'assets')).createSync();
    File(p.join(root.path, 'assets', 'crate.glb')).writeAsBytesSync([1, 2]);

    await open(tester);
    await openFolder(tester, 'assets');

    final tile = find.descendant(
      of: find.byType(GridView),
      matching: find.text('crate.glb'),
    );
    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await save(tester);

    // Relative, so the scene file survives the project being moved or shared.
    final written = File(p.join(root.path, 'scenes', 'main$sceneExtension'))
        .readAsStringSync();
    expect(written, contains('"assets/crate.glb"'));
    expect(written, isNot(contains(root.path)));
  });

  testWidgets('the scene is the root, with its objects under it',
      (tester) async {
    await open(tester);

    final sceneY = tester.getCenter(sceneRow('main')).dy;
    // Everything in it is drawn below it and indented.
    for (final name in ['Sun', 'Ground', 'Props']) {
      expect(tester.getCenter(row(name)).dy, greaterThan(sceneY));
      expect(tester.getTopLeft(row(name)).dx,
          greaterThan(tester.getTopLeft(sceneRow('main')).dx));
    }
  });

  testWidgets('selecting the scene shows its own settings', (tester) async {
    await open(tester);
    await tester.tap(sceneRow('main'));
    await tester.pumpAndSettle();

    // The sky belongs to the scene, not to anything in it.
    expect(find.text('ENVIRONMENT'), findsOneWidget);
    expect(find.text('Sky'), findsOneWidget);
    expect(find.text('Ambient'), findsOneWidget);
    // And not an object's fields.
    expect(find.text('TRANSFORM'), findsNothing);
  });

  testWidgets('the scene settings are saved with the scene', (tester) async {
    await open(tester);
    await tester.tap(sceneRow('main'));
    await tester.pumpAndSettle();

    // Pick a sky from the swatches.
    await tester.tap(find.byType(Slider));
    await tester.pumpAndSettle();
    await save(tester);

    final written = File(p.join(root.path, 'scenes', 'main$sceneExtension'))
        .readAsStringSync();
    expect(written, contains('"sky"'));
    expect(written, contains('"ambient"'));
  });

  testWidgets('dragging a row onto another makes it a child', (tester) async {
    await open(tester);

    // Onto the middle of the row, which is the reparent band.
    final gesture = await tester.startGesture(tester.getCenter(row('Ground')));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(row('Props')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Move Ground'), findsOneWidget);
  });

  testWidgets('dragging to the edge of a row reorders instead', (tester) async {
    await open(tester);

    final box = tester.getRect(rowBox('Sun'));
    final gesture = await tester.startGesture(tester.getCenter(row('Ground')));
    await tester.pump(const Duration(milliseconds: 200));
    // The top sliver of the Sun row: before it, as a sibling.
    await gesture.moveTo(Offset(box.center.dx, box.top + 2));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Reorder Ground'), findsOneWidget);
  });

  testWidgets('a thing cannot be dropped into its own child', (tester) async {
    await open(tester);

    final gesture = await tester.startGesture(tester.getCenter(row('Props')));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(row('Cube')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Refused before the drop, so nothing happened and nothing was said.
    expect(find.textContaining('Move Props'), findsNothing);
    expect(row('Props'), findsOneWidget);
  });

  testWidgets('both scenes are drawn together', (tester) async {
    await open(tester);
    await save(tester);
    await menu(tester, 'Scene', 'New scene');

    // The viewport counts what is on screen across every open scene.
    expect(find.textContaining('2 scenes'), findsWidgets);
  });
}
