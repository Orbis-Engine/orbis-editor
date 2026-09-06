import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/asset_browser.dart';
import 'package:orbis_editor/src/editor/clipboard.dart';
import 'package:orbis_editor/src/editor/data_object.dart';
import 'package:orbis_editor/src/editor/data_panel.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/inspector.dart';
import 'package:orbis_editor/src/editor/outliner.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  /// Stands in for the system clipboard, which has no implementation under
  /// the test binding. Copy writes here and paste reads it, so the round trip
  /// through text is what the tests actually exercise.
  String? systemClipboard;

  setUp(() {
    systemClipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          systemClipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return systemClipboard == null ? null : {'text': systemClipboard};
      }
      return null;
    });

    root = Directory.systemTemp.createTempSync('orbis_shell');
    Directory(p.join(root.path, 'scenes')).createSync();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    root.deleteSync(recursive: true);
  });

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
        of: find.byType(Draggable<ObjectDrag>),
        matching: find.text(name),
      );

  /// The whole row a name sits in, rather than just its text — the text is
  /// centred, so its top-left is halfway down the row.
  Finder rowBox(String name) => find.ancestor(
        of: row(name),
        matching: find.byType(Draggable<ObjectDrag>),
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

    expect(find.textContaining('Meshes, prefabs and scenes'), findsOneWidget);
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

  testWidgets('a new scene is listed and loaded, and the old one is not',
      (tester) async {
    await open(tester);
    await save(tester);

    await menu(tester, 'Scene', 'New scene');

    // Both are listed, but only the new one holds anything.
    expect(sceneCount('2 scenes'), findsOneWidget);
    expect(sceneRow('main'), findsOneWidget);
    expect(sceneRow('Untitled'), findsOneWidget);
    expect(find.text('not loaded'), findsOneWidget);

    // The old scene's objects are gone from the tree, because it no longer
    // holds them.
    expect(row('Props'), findsOneWidget,
        reason: 'the new scene has its own Props');
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
    await tester.pump(const Duration(milliseconds: 400));
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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // Pick a sky from the swatches. The first slider is the ambient; the
    // scene panel has fog sliders under it now.
    await tester.tap(find.byType(Slider).first);
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

  testWidgets('only the loaded scene has objects in the tree', (tester) async {
    // A second scene file in the project, listed but not loaded.
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([
      SceneObject(id: 'barrel', name: 'Barrel', kind: ObjectKind.mesh),
    ])));

    await open(tester);

    expect(sceneRow('props'), findsOneWidget);
    expect(find.text('not loaded'), findsOneWidget);
    // Its object is not in the tree, because the scene is not loaded.
    expect(row('Barrel'), findsNothing);
  });

  testWidgets('double-clicking a scene loads it', (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([
      SceneObject(id: 'barrel', name: 'Barrel', kind: ObjectKind.mesh),
    ], name: 'Props')));

    await open(tester);
    await save(tester);

    final target = sceneRow('props');
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(target);
    await tester.pumpAndSettle();

    // The other scene is now the one with objects.
    expect(row('Barrel'), findsOneWidget);
    expect(row('Props'), findsNothing, reason: 'the old scene was unloaded');
    expect(find.textContaining('props$sceneExtension'), findsWidgets);
  });

  testWidgets('leaving a scene with changes asks before dropping them',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([])));

    await open(tester);
    await save(tester);
    await add(tester, 'Group');

    final target = sceneRow('props');
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(target);
    await tester.pumpAndSettle();

    expect(find.textContaining('Save main first?'), findsOneWidget);
  });

  testWidgets('cancelling the prompt keeps you where you were',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([])));

    await open(tester);
    await save(tester);
    await add(tester, 'Group');

    final target = sceneRow('props');
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(target);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Still in the first scene, with the change still there.
    expect(row('Props'), findsOneWidget);
    expect(row('Group'), findsOneWidget);
    expect(unsavedMarker(), findsOneWidget);
  });

  testWidgets('choosing Save writes the change and then moves on',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([
      SceneObject(id: 'barrel', name: 'Barrel', kind: ObjectKind.mesh),
    ])));

    await open(tester);
    await save(tester);
    await add(tester, 'Group');

    final target = sceneRow('props');
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(target);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Save'),
    ));
    await tester.pumpAndSettle();

    // The change reached the file it belonged to...
    final written = File(p.join(root.path, 'scenes', 'main$sceneExtension'))
        .readAsStringSync();
    expect(written, contains('"Group"'));
    // ...and the other scene is now loaded.
    expect(row('Barrel'), findsOneWidget);
  });

  testWidgets('an unloaded scene offers to load rather than pretending to edit',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([])));

    await open(tester);
    await tester.tap(sceneRow('props'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // No environment fields to fiddle with — there is no document behind them.
    expect(find.text('Load scene'), findsOneWidget);
    expect(find.text('ENVIRONMENT'), findsNothing);
  });

  /// Loads a scene from its row in the hierarchy.
  Future<void> loadScene(WidgetTester tester, String name) async {
    final target = sceneRow(name);
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
  }

  testWidgets('an object can be copied from one scene into another',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([], name: 'Props')));

    await open(tester);
    await save(tester);

    // Copy a whole subtree out of the first scene...
    await tester.tap(row('Props'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC);

    // ...leave it, and paste into the other.
    await loadScene(tester, 'props');
    expect(row('Props'), findsNothing, reason: 'the other scene is empty');

    await press(tester, LogicalKeyboardKey.keyV);

    expect(row('Props'), findsOneWidget);
    expect(row('Cube'), findsOneWidget, reason: 'the children came too');
    expect(row('Crate'), findsOneWidget);
  });

  testWidgets('the clipboard survives the scene it came from being unloaded',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([], name: 'Props')));

    await open(tester);
    await save(tester);

    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC);

    await loadScene(tester, 'props');
    await press(tester, LogicalKeyboardKey.keyV);
    await save(tester);

    final written = File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .readAsStringSync();
    expect(written, contains('"Crate"'));
  });

  testWidgets('cut removes it from the scene it was in', (tester) async {
    await open(tester);

    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyX);

    expect(row('Crate'), findsNothing);
    expect(find.textContaining('Delete Crate'), findsOneWidget);
  });

  testWidgets('duplicate leaves the original alone', (tester) async {
    await open(tester);

    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyD);

    // Two now, sharing a name and nothing else.
    expect(row('Crate'), findsNWidgets(2));
    expect(find.textContaining('Paste Crate'), findsOneWidget);
  });

  testWidgets('pasting is undoable in one step', (tester) async {
    await open(tester);

    await tester.tap(row('Props'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyD);
    expect(row('Cube'), findsNWidgets(2));

    await press(tester, LogicalKeyboardKey.keyZ);

    // The whole subtree went, not just its root.
    expect(row('Cube'), findsOneWidget);
    expect(row('Props'), findsOneWidget);
  });

  testWidgets('the edit menu says what paste would do', (tester) async {
    await open(tester);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    // Nothing copied yet, so it is just Paste.
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Paste Crate'), findsOneWidget);
  });

  /// Clicks a row with a modifier held.
  Future<void> clickWith(
    WidgetTester tester,
    String name,
    LogicalKeyboardKey modifier,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.tap(row(name));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(modifier);
  }

  testWidgets('command-click adds to the selection', (tester) async {
    await open(tester);

    await tester.tap(row('Sun'));
    await tester.pumpAndSettle();
    await clickWith(tester, 'Ground', LogicalKeyboardKey.metaLeft);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Copy 2 objects'), findsOneWidget);
  });

  testWidgets('shift-click takes everything between', (tester) async {
    await open(tester);

    await tester.tap(row('Sun'));
    await tester.pumpAndSettle();
    await clickWith(tester, 'Cube', LogicalKeyboardKey.shiftLeft);

    // Sun, Ground, Props, Cube — in the order the tree draws them.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Copy 4 objects'), findsOneWidget);
  });

  testWidgets('command-click again takes one back out', (tester) async {
    await open(tester);

    await tester.tap(row('Sun'));
    await tester.pumpAndSettle();
    await clickWith(tester, 'Ground', LogicalKeyboardKey.metaLeft);
    await clickWith(tester, 'Ground', LogicalKeyboardKey.metaLeft);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget, reason: 'back to one');
  });

  testWidgets('deleting several is one step', (tester) async {
    await open(tester);

    await tester.tap(row('Sun'));
    await tester.pumpAndSettle();
    await clickWith(tester, 'Ground', LogicalKeyboardKey.metaLeft);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(row('Sun'), findsNothing);
    expect(row('Ground'), findsNothing);
    expect(find.textContaining('Delete 2 objects'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.keyZ);
    expect(row('Sun'), findsOneWidget);
    expect(row('Ground'), findsOneWidget);
  });

  testWidgets('several can be copied into another scene at once',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([], name: 'Props')));

    await open(tester);
    await save(tester);

    await tester.tap(row('Sun'));
    await tester.pumpAndSettle();
    await clickWith(tester, 'Ground', LogicalKeyboardKey.metaLeft);
    await press(tester, LogicalKeyboardKey.keyC);

    await loadScene(tester, 'props');
    await press(tester, LogicalKeyboardKey.keyV);

    expect(row('Sun'), findsOneWidget);
    expect(row('Ground'), findsOneWidget);
  });

  testWidgets('a copy leaves readable text on the system clipboard',
      (tester) async {
    await open(tester);

    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC);

    // What lands in a text editor is the scene's own encoding, not a blob.
    expect(systemClipboard, isNotNull);
    expect(systemClipboard, contains('"Crate"'));
    expect(systemClipboard, contains('orbis.objects'));
  });

  testWidgets('a copy from elsewhere can be pasted in', (tester) async {
    await open(tester);

    // As though another window had put it there.
    final elsewhere = SceneClipboard()
      ..take(
        EditorScene([
          SceneObject(id: 'x', name: 'From Elsewhere', kind: ObjectKind.mesh),
        ]),
        ['x'],
      );
    systemClipboard = elsewhere.toText();

    await press(tester, LogicalKeyboardKey.keyV);

    expect(row('From Elsewhere'), findsOneWidget);
  });

  testWidgets('text that is not ours is not pasted', (tester) async {
    await open(tester);
    systemClipboard = 'just some notes I had copied';

    await press(tester, LogicalKeyboardKey.keyV);

    expect(find.textContaining('nothing on the clipboard'), findsOneWidget);
  });

  testWidgets('a pasted object lands where it was in the world',
      (tester) async {
    File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(EditorScene([], name: 'Props')));

    await open(tester);
    await save(tester);

    // The crate sits inside Props, at 2.2 along x.
    await tester.tap(row('Crate'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC);

    await loadScene(tester, 'props');
    await press(tester, LogicalKeyboardKey.keyV);
    await save(tester);

    // The other scene has no Props to inherit from, so the local transform has
    // to carry what the parent used to contribute.
    final written = File(p.join(root.path, 'scenes', 'props$sceneExtension'))
        .readAsStringSync();
    final load = SceneDocument.decode(written);
    final crate = load.scene.objects.firstWhere((o) => o.name == 'Crate');
    expect(crate.position.x, closeTo(2.2, 1e-6));
  });

  group('prefabs', () {
    /// Selects a row and drags it onto the project browser.
    ///
    /// Selected first, because making a prefab of something is a thing done
    /// to the thing in front of you — and the inspector has to be showing it
    /// for the band that appears afterwards to be worth looking at.
    Future<void> dragToBrowser(WidgetTester tester, String name) async {
      await tester.tap(row(name));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(row(name)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout);
      await gesture.moveTo(tester.getCenter(find.byType(GridView)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // What it says stays on screen until its own timer fires, and a snack
      // bar still showing holds the next one back in the queue.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    /// The prefab band in the inspector, rather than the tile in the browser
    /// that carries the same file name.
    Finder band(String text) => find.descendant(
          of: find.byType(Inspector),
          matching: find.text(text),
        );

    /// The prefab files in the project, whatever folder they landed in.
    List<File> prefabs() => root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.oprefab'))
        .toList();

    testWidgets('dropping an object on the project makes one', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      final made = prefabs();
      expect(made, hasLength(1));
      expect(p.basename(made.single.path), 'Cube.oprefab');
      expect(made.single.readAsStringSync(), contains('orbis.prefab'));
    });

    testWidgets('what it was made from becomes an instance', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      // The band only appears for an object that remembers a prefab.
      expect(band('Cube.oprefab'), findsOneWidget);
      expect(band('Apply'), findsOneWidget);
      expect(band('Unpack'), findsOneWidget);
    });

    testWidgets('making one is undoable, link and all', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pumpAndSettle();

      expect(band('Cube.oprefab'), findsNothing);
      // The file stays: undo covers the scene, not the project folder, and
      // pretending otherwise would delete somebody's asset behind their back.
      expect(prefabs(), hasLength(1));
    });

    testWidgets('unpacking takes the link off', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      await tester.tap(band('Unpack'));
      await tester.pumpAndSettle();

      expect(band('Cube.oprefab'), findsNothing);
    });

    testWidgets('a prefab dropped in the viewport comes back', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      final tile = find.descendant(
        of: find.byType(GridView),
        matching: find.text('Cube.oprefab'),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(tile),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout);
      await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Two cubes now: the one it was made from and the one just placed.
      expect(row('Cube'), findsOneWidget);
      expect(row('Cube 2'), findsOneWidget);
    });

    testWidgets('a change applied reaches the other instances', (tester) async {
      await open(tester);
      await dragToBrowser(tester, 'Cube');

      final source = prefabs().single;
      // Two more instances, placed straight through the dropped file.
      for (var i = 0; i < 2; i++) {
        final tile = find.descendant(
          of: find.byType(GridView),
          matching: find.text('Cube.oprefab'),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(tile),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(kLongPressTimeout);
        await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      // Back to the original, and apply from it.
      await tester.tap(row('Cube'));
      await tester.pumpAndSettle();
      await tester.tap(band('Apply'));
      // Pumped rather than settled: what it says goes in a snack bar, and
      // settling waits out the four seconds it is on screen for.
      await tester.pump();

      expect(source.readAsStringSync(), contains('orbis.prefab'));
      expect(find.textContaining('updated 2 other instances'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

  group('the shared set', () {
    /// The Shared scene's own row, which sits above every scene.
    Finder sharedRow() => find.descendant(
          of: find.byType(Outliner),
          matching: find.text('Shared'),
        );

    Future<void> dragOnto(WidgetTester tester, Finder from, Finder to) async {
      final gesture = await tester.startGesture(tester.getCenter(from));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getCenter(to));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('an object can be dragged into it', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Crate'), sharedRow());

      // Out of the scene it was in and into the set every scene has: still
      // one row, but the scene is one object lighter.
      expect(find.textContaining('Move Crate'), findsOneWidget);
      expect(row('Crate'), findsOneWidget);
      expect(find.textContaining('6 objects'), findsOneWidget);
    });

    testWidgets('and dragged back out again', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Crate'), sharedRow());
      expect(find.textContaining('6 objects'), findsOneWidget);

      await dragOnto(tester, row('Crate'), row('Props'));

      expect(row('Crate'), findsOneWidget);
      expect(find.textContaining('7 objects'), findsOneWidget);
    });

    testWidgets('moving into it is undoable', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Crate'), sharedRow());
      await press(tester, LogicalKeyboardKey.keyZ);

      // Back in the scene it came from, counted there again.
      expect(row('Crate'), findsOneWidget);
      expect(find.textContaining('7 objects'), findsOneWidget);
    });

    testWidgets('something in it can be copied and pasted', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Crate'), sharedRow());

      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyC);
      await press(tester, LogicalKeyboardKey.keyV);

      // Both in the shared set, since that is where the selection was.
      expect(row('Crate'), findsNWidgets(2));
    });

    testWidgets('something in it can be duplicated', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Crate'), sharedRow());

      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyD);

      expect(row('Crate'), findsNWidgets(2));
    });

    testWidgets('pasting with nothing selected still goes to the scene',
        (tester) async {
      await open(tester);
      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyC);
      await press(tester, LogicalKeyboardKey.keyV);

      expect(row('Crate'), findsNWidgets(2));
    });

    testWidgets('an object copied out of it lands in the open scene',
        (tester) async {
      await open(tester);
      await dragOnto(tester, row('Sun'), sharedRow());

      await tester.tap(row('Sun'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyC);
      await tester.tap(row('Props'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyV);

      expect(row('Sun'), findsNWidgets(2));
    });

    testWidgets('the scene it left reads as unsaved too', (tester) async {
      await open(tester);
      await save(tester);
      expect(unsavedMarker(), findsNothing);

      await dragOnto(tester, row('Crate'), sharedRow());

      // Both documents changed, so the one it came out of is a whole object
      // short of what is on disk and has to say so.
      expect(unsavedMarker(), findsWidgets);
    });

    testWidgets('a whole subtree moves into it at once', (tester) async {
      await open(tester);
      await dragOnto(tester, row('Props'), sharedRow());

      // The group and both its children went together.
      expect(row('Props'), findsOneWidget);
      expect(row('Cube'), findsOneWidget);
      expect(row('Crate'), findsOneWidget);
      // Three fewer in the scene: the group and both its children.
      expect(find.textContaining('4 objects'), findsOneWidget);
    });
  });

  group('making things from the browser', () {
    /// Right-clicks the empty space in the file grid.
    Future<void> rightClickGrid(WidgetTester tester) async {
      await tester.tapAt(
        tester.getCenter(find.byType(AssetBrowser)),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
    }

    /// Picks a menu entry, opening the group it is in when it has one.
    Future<void> pick(WidgetTester tester, String label, {String? from}) async {
      if (from != null) {
        await tester.tap(find.widgetWithText(SubmenuButton, from));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text(label),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the menu groups what it can make', (tester) async {
      await open(tester);
      await rightClickGrid(tester);

      // The common ones stay in front; the rest are behind a heading.
      expect(find.widgetWithText(MenuItemButton, 'Folder'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Scene'), findsOneWidget);
      expect(find.widgetWithText(SubmenuButton, 'Script'), findsOneWidget);
      expect(find.widgetWithText(SubmenuButton, 'Style'), findsOneWidget);

      // Nothing inside a group is on the menu until the group is opened.
      expect(find.text('TypeScript'), findsNothing);
      expect(find.text('Stylesheet'), findsNothing);
    });

    testWidgets('a group opens to what is in it', (tester) async {
      await open(tester);
      await rightClickGrid(tester);
      await tester.tap(find.widgetWithText(SubmenuButton, 'Script'));
      await tester.pumpAndSettle();

      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('Interface'), findsOneWidget);
      expect(find.text('C++'), findsOneWidget);
      expect(find.text('C++ header'), findsOneWidget);
      // And what each one would actually write.
      expect(find.text('.tsx'), findsOneWidget);
    });

    testWidgets('a folder is made from the menu', (tester) async {
      await open(tester);
      await rightClickGrid(tester);
      await pick(tester, 'Folder');
      await answerPrompt(tester, 'props', 'Create');

      expect(Directory(p.join(root.path, 'props')).existsSync(), isTrue);
    });

    testWidgets('a script is made inside its group', (tester) async {
      await open(tester);
      await rightClickGrid(tester);
      await pick(tester, 'TypeScript', from: 'Script');
      await answerPrompt(tester, 'walker', 'Create');

      final made = File(p.join(root.path, 'walker.ts'));
      expect(made.existsSync(), isTrue);
      expect(made.readAsStringSync(), contains('onFrame'));
    });

    testWidgets('a theme and a stylesheet are both offered', (tester) async {
      await open(tester);
      await rightClickGrid(tester);
      await pick(tester, 'Theme', from: 'Style');
      await answerPrompt(tester, 'dark', 'Create');

      final made = File(p.join(root.path, 'dark.css'));
      expect(made.existsSync(), isTrue);
      // The theme is the values, not the rules.
      expect(made.readAsStringSync(), contains('--accent'));
    });

    testWidgets('right-clicking a file offers what to do with it too',
        (tester) async {
      await open(tester);
      await rightClickGrid(tester);
      await pick(tester, 'Folder');
      await answerPrompt(tester, 'props', 'Create');

      await tester.tapAt(
        tester.getCenter(find.descendant(
          of: find.byType(GridView),
          matching: find.text('props'),
        )),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(MenuItemButton, 'Rename'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Delete'), findsOneWidget);
      // And still everything the empty space offers.
      expect(find.widgetWithText(SubmenuButton, 'Script'), findsOneWidget);
    });
  });

  group('data objects', () {
    Future<void> rightClickGrid(WidgetTester tester) async {
      await tester.tapAt(
        tester.getCenter(find.byType(AssetBrowser)),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
    }

    /// Makes one through the menu and leaves it selected.
    Future<void> makeOne(WidgetTester tester, String name) async {
      await rightClickGrid(tester);
      await tester.tap(find.widgetWithText(SubmenuButton, 'Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('Data object'),
      ));
      await tester.pumpAndSettle();
      await answerPrompt(tester, name, 'Create');
    }

    Finder tile(String name) => find.descendant(
          of: find.byType(GridView),
          matching: find.text(name),
        );

    /// Selects a file in the grid.
    ///
    /// The wait is the double-tap window: a tile answers both, so a single
    /// tap is not a single tap until the timer for the second one has run
    /// out, and pumpAndSettle does not run out a timer.
    Future<void> select(WidgetTester tester, String name) async {
      await tester.tap(tile(name));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
    }

    testWidgets('one is made with something already in it', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');

      final made = File(p.join(root.path, 'ball.odata'));
      expect(made.existsSync(), isTrue);
      expect(DataObject.read(made.readAsStringSync())!.fields, isNotEmpty);
    });

    testWidgets('selecting one edits it in the inspector', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');

      await select(tester, 'ball.odata');

      expect(find.byType(DataPanel), findsOneWidget);
      expect(find.text('Add a value'), findsOneWidget);
    });

    testWidgets('a value typed in reaches the file', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');
      await select(tester, 'ball.odata');

      // The number the blank object starts with.
      await tester.enterText(
        find.descendant(
          of: find.byType(FieldRow),
          matching: find.byType(TextField),
        ).first,
        '12.5',
      );
      // Written shortly after the last keystroke rather than on every one.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final data = DataObject.read(
        File(p.join(root.path, 'ball.odata')).readAsStringSync(),
      )!;
      expect(data.fields.first.asNumber, 12.5);
    });

    testWidgets('selecting an object puts the inspector back', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');
      await select(tester, 'ball.odata');
      expect(find.byType(DataPanel), findsOneWidget);

      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();

      expect(find.byType(DataPanel), findsNothing);
    });

    testWidgets('selecting a mesh does not take the inspector', (tester) async {
      Directory(p.join(root.path, 'assets')).createSync();
      File(p.join(root.path, 'assets', 'rock.glb')).writeAsBytesSync([1]);

      await open(tester);
      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();
      await openFolder(tester, 'assets');
      await select(tester, 'rock.glb');

      // Still the object: only a data object claims the panel.
      expect(find.byType(DataPanel), findsNothing);
    });

    testWidgets('dropping one on the selection attaches it', (tester) async {
      await open(tester);
      await makeOne(tester, 'weight');

      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(tile('weight.odata')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Listed on the object, and named as what it is rather than a path.
      expect(find.text('DATA'), findsOneWidget);
      expect(find.text('weight.odata'), findsWidgets);
    });

    testWidgets('attaching is undoable', (tester) async {
      await open(tester);
      await makeOne(tester, 'weight');
      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(tile('weight.odata')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('DATA'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.keyZ);
      expect(find.text('DATA'), findsNothing);
    });

    testWidgets('what it says is saved with the scene', (tester) async {
      await open(tester);
      await makeOne(tester, 'weight');
      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(tile('weight.odata')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('DATA'), findsOneWidget);

      await save(tester);
      final written =
          File(p.join(root.path, 'scenes', 'main.oscene')).readAsStringSync();
      expect(written, contains('weight.odata'));
    });

    testWidgets('the types it writes land beside it', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');
      await select(tester, 'ball.odata');

      await tester.tap(find.text('Write TypeScript types'));
      await tester.pumpAndSettle();

      final types = File(p.join(root.path, 'ball.d.ts'));
      expect(types.existsSync(), isTrue);
      expect(types.readAsStringSync(), contains('export interface'));
    });
  });
}
