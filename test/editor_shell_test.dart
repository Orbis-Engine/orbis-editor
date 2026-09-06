import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/asset_browser.dart';
import 'package:orbis_editor/src/editor/clipboard.dart';
import 'package:orbis_editor/src/editor/data_object.dart';
import 'package:orbis_editor/src/editor/console_panel.dart';
import 'package:orbis_editor/src/editor/data_panel.dart';
import 'package:orbis_editor/src/editor/dock.dart';
import 'package:orbis_editor/src/editor/dock_view.dart';
import 'package:orbis_editor/src/editor/game_view.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/inspector.dart';
import 'package:orbis_editor/src/editor/mesh_panel.dart';
import 'package:orbis_editor/src/editor/surface.dart';
import 'package:orbis_editor/src/editor/outliner.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_editor/src/widgets/controls.dart';
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math_64.dart' hide Colors;

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

    await add(tester, 'Mesh object');

    expect(find.byTooltip('Nothing to undo'), findsNothing);
    expect(find.byTooltip('Undo Add Mesh'), findsOneWidget);
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

    /// Scrolls the inspector to the bottom.
    ///
    /// Its sections are a lazy list, so one below the fold is not built and a
    /// finder cannot see it. Which sections fit depends on the window and on
    /// how the panels are arranged, so a test that assumes one is on screen is
    /// a test that breaks when somebody moves a panel.
    Future<void> scrollInspector(WidgetTester tester) async {
      await tester.drag(
        find.descendant(
          of: find.byType(Inspector),
          matching: find.byType(ListView),
        ),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
    }

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
      await scrollInspector(tester);
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
      await scrollInspector(tester);
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
      await scrollInspector(tester);
      expect(find.text('DATA'), findsOneWidget);

      await save(tester);
      final written =
          File(p.join(root.path, 'scenes', 'main.oscene')).readAsStringSync();
      expect(written, contains('weight.odata'));
    });

    testWidgets('the bindings it writes land beside it', (tester) async {
      await open(tester);
      await makeOne(tester, 'ball');
      await select(tester, 'ball.odata');

      await tester.tap(find.text('Write script bindings'));
      await tester.pumpAndSettle();

      // Both languages from the one declaration, which is what makes a field
      // renamed here a build error in whatever reads it.
      final types = File(p.join(root.path, 'ball.d.ts'));
      expect(types.existsSync(), isTrue);
      expect(types.readAsStringSync(), contains('export interface'));

      final header = File(p.join(root.path, 'ball.h'));
      expect(header.existsSync(), isTrue);
      expect(header.readAsStringSync(), contains('namespace Ball'));
    });
  });

  group('an interface on a scene', () {
    /// Makes a .oui in the project and returns its tile in the grid.
    Finder makeInterface(String name) {
      File(p.join(root.path, '$name.oui')).writeAsStringSync(
        const UiDocument(
          name: 'Heads-up',
          root: UiNode(
            type: 'stack',
            classes: 'w-full h-full',
            children: [
              UiNode(
                type: 'text',
                css: 'left: 40px; top: 40px',
                text: 'Health 100',
              ),
            ],
          ),
        ).toText(),
      );
      return find.descendant(
        of: find.byType(GridView),
        matching: find.text('$name.oui'),
      );
    }

    Future<void> dropOnViewport(WidgetTester tester, Finder tile) async {
      final gesture = await tester.startGesture(tester.getCenter(tile));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getCenter(find.byType(SceneViewport)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('dropping one makes a canvas object that shows it',
        (tester) async {
      final tile = makeInterface('hud');
      await open(tester);
      await dropOnViewport(tester, tile);

      // An object in the tree, and the interface itself over the viewport.
      expect(row('hud'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SceneViewport),
          matching: find.text('Health 100'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the object says which interface it shows', (tester) async {
      final tile = makeInterface('hud');
      await open(tester);
      await dropOnViewport(tester, tile);

      expect(find.text('INTERFACE'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Inspector),
          matching: find.text('hud.oui'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('it is saved with the scene and comes back', (tester) async {
      final tile = makeInterface('hud');
      await open(tester);
      await dropOnViewport(tester, tile);
      await save(tester);

      final written =
          File(p.join(root.path, 'scenes', 'main.oscene')).readAsStringSync();
      expect(written, contains('hud.oui'));

      final back = SceneDocument.decode(written).scene;
      final canvas = back.objects
          .firstWhere((o) => o.kind == ObjectKind.canvas);
      expect(canvas.interfaceAsset, 'hud.oui');
    });

    testWidgets('hiding the object takes the interface off the scene',
        (tester) async {
      final tile = makeInterface('hud');
      await open(tester);
      await dropOnViewport(tester, tile);

      Finder drawn() => find.descendant(
            of: find.byType(SceneViewport),
            matching: find.text('Health 100'),
          );
      expect(drawn(), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(Inspector),
        matching: find.text('Hidden'),
      ));
      await tester.pumpAndSettle();

      // What hides it here is what hides it in the game: the object's own
      // visibility, not a view setting.
      expect(drawn(), findsNothing);
    });

    testWidgets('the viewport can put it aside without changing the scene',
        (tester) async {
      final tile = makeInterface('hud');
      await open(tester);
      await dropOnViewport(tester, tile);
      await save(tester);

      await tester.tap(find.descendant(
        of: find.byType(SceneViewport),
        matching: find.text('Interface'),
      ));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(SceneViewport),
          matching: find.text('Health 100'),
        ),
        findsNothing,
      );
      // A view setting, so the scene is still saved.
      expect(unsavedMarker(), findsNothing);
    });

    testWidgets('dropping a second one onto the selected canvas replaces it',
        (tester) async {
      makeInterface('hud');
      final other = makeInterface('menu');
      await open(tester);

      await dropOnViewport(tester, find.descendant(
        of: find.byType(GridView),
        matching: find.text('hud.oui'),
      ));
      await dropOnViewport(tester, other);

      // One canvas, showing the second interface.
      expect(row('hud'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Inspector),
          matching: find.text('menu.oui'),
        ),
        findsOneWidget,
      );
    });
  });

  group('the console', () {
    testWidgets('there are two panels at the bottom', (tester) async {
      await open(tester);

      expect(find.text('PROJECT'), findsOneWidget);
      expect(find.text('CONSOLE'), findsOneWidget);
      // The project one is showing to begin with.
      expect(find.byType(AssetBrowser), findsOneWidget);
      expect(find.byType(ConsolePanel), findsNothing);
    });

    testWidgets('opening it shows what the editor has said', (tester) async {
      await open(tester);
      await save(tester);

      await tester.tap(find.text('CONSOLE'));
      await tester.pumpAndSettle();

      expect(find.byType(ConsolePanel), findsOneWidget);
      expect(find.byType(AssetBrowser), findsNothing);
      expect(find.textContaining('Saved'), findsWidgets);
    });

    testWidgets('a message that has gone from the status bar is still there',
        (tester) async {
      await open(tester);
      await save(tester);

      // Long enough for the snack bar to have come and gone.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      await tester.tap(find.text('CONSOLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved'), findsWidgets);
    });

    testWidgets('a refusal is an error, and says so on the tab',
        (tester) async {
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

      // Kept, and counted where somebody who is not looking at the console
      // will still see it.
      await tester.tap(find.text('CONSOLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Meshes, prefabs and scenes'), findsWidgets);
    });

    testWidgets('it can be cleared', (tester) async {
      await open(tester);
      await save(tester);
      await tester.tap(find.text('CONSOLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved'), findsWidgets);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Nothing to report.'), findsOneWidget);
    });

    testWidgets('the filters hide a level', (tester) async {
      await open(tester);
      await save(tester);
      await tester.tap(find.text('CONSOLE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved'), findsWidgets);

      await tester.tap(find.textContaining('Info '));
      await tester.pumpAndSettle();

      // Scoped to the panel: the snack bar that said the same thing is still
      // on screen, because a snack bar goes away on its own timer and
      // pumpAndSettle does not run one out.
      expect(
        find.descendant(
          of: find.byType(ConsolePanel),
          matching: find.textContaining('Saved'),
        ),
        findsNothing,
      );
      expect(find.text('Nothing at these levels.'), findsOneWidget);
    });
  });

  group('flying the view', () {
    /// Holds the right button down over the viewport.
    Future<TestGesture> look(WidgetTester tester) async {
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.addPointer(
        location: tester.getCenter(find.byType(SceneViewport)),
      );
      addTearDown(gesture.removePointer);
      await gesture.down(tester.getCenter(find.byType(SceneViewport)));
      // Pumped rather than settled: flying runs the clock, so there is always
      // another frame scheduled and pumpAndSettle waits for one that never
      // comes.
      await tester.pump();
      return gesture;
    }

    testWidgets('holding the right button says it is flying', (tester) async {
      await open(tester);
      expect(find.textContaining('Flying'), findsNothing);

      await look(tester);

      expect(find.textContaining('Flying'), findsOneWidget);
      expect(find.textContaining('m/s'), findsOneWidget);
    });

    testWidgets('letting go stops', (tester) async {
      await open(tester);
      final gesture = await look(tester);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.textContaining('Flying'), findsNothing);
    });

    testWidgets('W moves the view forward while the button is held',
        (tester) async {
      await open(tester);
      final gesture = await look(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await gesture.up();
      await tester.pumpAndSettle();

      // Still flying is what would be wrong; the camera having moved is what
      // the unit tests on OrbitCamera cover exactly.
      expect(find.textContaining('Flying'), findsNothing);
      expect(find.byType(SceneViewport), findsOneWidget);
    });

    testWidgets('W does nothing when the button is not held', (tester) async {
      await open(tester);

      // Otherwise typing a name into the inspector would fly the view across
      // the level a letter at a time.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pumpAndSettle();

      expect(find.textContaining('Flying'), findsNothing);
    });

    testWidgets('it can be switched on rather than held', (tester) async {
      await open(tester);

      // A click makes this view the one the keyboard is talking to.
      await tester.tapAt(tester.getCenter(find.byType(SceneViewport)));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pump();

      // No button held: a two-finger click held down while the other hand
      // types WASD is a hand position nobody keeps for long.
      expect(find.textContaining('Flying'), findsOneWidget);
    });

    testWidgets('escape stops it', (tester) async {
      await open(tester);
      await tester.tapAt(tester.getCenter(find.byType(SceneViewport)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.textContaining('Flying'), findsNothing);
    });

    testWidgets('and so does pressing the key again', (tester) async {
      await open(tester);
      await tester.tapAt(tester.getCenter(find.byType(SceneViewport)));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pumpAndSettle();

      expect(find.textContaining('Flying'), findsNothing);
    });

    testWidgets('W moves while it is switched on, with nothing held',
        (tester) async {
      await open(tester);
      await tester.tapAt(tester.getCenter(find.byType(SceneViewport)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pump();

      expect(find.textContaining('Flying'), findsOneWidget);
    });

    testWidgets('the backquote does nothing until a view is clicked in',
        (tester) async {
      await open(tester);

      // Otherwise typing a backquote into a name would launch the view.
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pumpAndSettle();

      expect(find.textContaining('Flying'), findsNothing);
    });

    testWidgets('the wheel sets the speed rather than the distance',
        (tester) async {
      await open(tester);
      await look(tester);

      final before = tester
          .widgetList<Text>(find.textContaining('m/s'))
          .first
          .data;

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(SceneViewport)),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump();

      final after =
          tester.widgetList<Text>(find.textContaining('m/s')).first.data;
      expect(after, isNot(before));
    });
  });

  group('arranging the panels', () {
    Future<void> viewMenu(WidgetTester tester, String item) async {
      // The toolbar button, not the word "Viewport" wherever else it appears
      // — and it gains a dot when the layout is locked.
      await tester.tap(find.byWidgetPredicate(
        (widget) => widget is OrbisButton && widget.label.startsWith('View'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text(item),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the editor opens with the panels it always had',
        (tester) async {
      await open(tester);

      expect(find.byType(Outliner), findsOneWidget);
      expect(find.byType(SceneViewport), findsOneWidget);
      expect(find.byType(Inspector), findsOneWidget);
      expect(find.byType(AssetBrowser), findsOneWidget);
    });

    testWidgets('four views is four scene panels at once', (tester) async {
      await open(tester);
      await viewMenu(tester, 'Four views');

      expect(find.byType(SceneViewport), findsNWidgets(4));
      // Each one is a camera of its own, so moving one does not move the rest.
      expect(find.text('SCENE 2'), findsOneWidget);
      expect(find.text('SCENE 4'), findsOneWidget);
    });

    testWidgets('and back to one', (tester) async {
      await open(tester);
      await viewMenu(tester, 'Four views');
      await viewMenu(tester, 'One view');

      expect(find.byType(SceneViewport), findsOneWidget);
    });

    testWidgets('the game view is a tab beside the scene', (tester) async {
      await open(tester);
      expect(find.text('GAME'), findsOneWidget);
      expect(find.byType(GameView), findsNothing);

      await tester.tap(find.text('GAME'));
      await tester.pumpAndSettle();

      expect(find.byType(GameView), findsOneWidget);
      // One at a time: the scene view is behind it, not beside it.
      expect(find.byType(SceneViewport), findsNothing);
    });

    testWidgets('a panel can be closed and opened again', (tester) async {
      await open(tester);
      await viewMenu(tester, 'Console');
      expect(find.byType(ConsolePanel), findsOneWidget);

      // Closing the console leaves the project browser where it was.
      await viewMenu(tester, 'Project');
      expect(find.byType(AssetBrowser), findsOneWidget);
    });

    testWidgets('the arrangement is remembered', (tester) async {
      await open(tester);
      await viewMenu(tester, 'Four views');
      expect(
        File(p.join(root.path, '.orbis', 'layout.json')).existsSync(),
        isTrue,
      );

      // Opened again, the panels are where they were left.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await open(tester);

      expect(find.byType(SceneViewport), findsNWidgets(4));
    });

    testWidgets('locking says so and stops the tabs being dragged',
        (tester) async {
      await open(tester);
      await viewMenu(tester, 'Lock the layout');

      expect(find.textContaining('View •'), findsOneWidget);
      // Nothing to drag: a locked layout draws its tabs without handles.
      expect(find.byType(Draggable<PanelDrag>), findsNothing);

      await viewMenu(tester, 'Unlock the layout');
      expect(find.byType(Draggable<PanelDrag>), findsWidgets);
    });

    testWidgets('a saved layout that cannot be read is not fatal',
        (tester) async {
      Directory(p.join(root.path, '.orbis')).createSync(recursive: true);
      File(p.join(root.path, '.orbis', 'layout.json'))
          .writeAsStringSync('not a layout at all');

      await open(tester);

      // The standard arrangement, rather than an editor that will not open.
      expect(find.byType(SceneViewport), findsOneWidget);
      expect(find.byType(Inspector), findsOneWidget);
    });
  });

  group('the camera preview', () {
    testWidgets('selecting a camera shows what it sees', (tester) async {
      await open(tester);
      expect(find.text('CAMERA'), findsNothing);

      await tester.tap(row('Camera'));
      await tester.pumpAndSettle();

      expect(find.text('CAMERA'), findsOneWidget);
    });

    testWidgets('selecting anything else takes it away', (tester) async {
      await open(tester);
      await tester.tap(row('Camera'));
      await tester.pumpAndSettle();
      expect(find.text('CAMERA'), findsOneWidget);

      await tester.tap(row('Crate'));
      await tester.pumpAndSettle();

      expect(find.text('CAMERA'), findsNothing);
    });

    testWidgets('hiding the camera takes it away too', (tester) async {
      await open(tester);
      await tester.tap(row('Camera'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(Inspector),
        matching: find.text('Hidden'),
      ));
      await tester.pumpAndSettle();

      // A camera that is not in the scene has no shot to preview.
      expect(find.text('CAMERA'), findsNothing);
    });
  });

  group('the trackpad', () {
    /// Two fingers on the trackpad, which Flutter reports as a pan-zoom
    /// gesture rather than as a scroll once something listens for one.
    Future<void> twoFingers(
      WidgetTester tester,
      Offset by, {
      double scale = 1,
      // Flying runs the clock, so there is always another frame scheduled and
      // pumpAndSettle waits for one that never comes.
      bool settle = true,
    }) async {
      final at = tester.getCenter(find.byType(SceneViewport));
      final pointer = TestPointer(1, PointerDeviceKind.trackpad);

      await tester.sendEventToBinding(pointer.panZoomStart(at));
      await tester.pump();
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(at, pan: by, scale: scale),
      );
      await tester.pump();
      await tester.sendEventToBinding(pointer.panZoomEnd());
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    /// Where the camera of the one scene view is standing.
    Vector3 eye(WidgetTester tester) => tester
        .widget<SceneViewport>(find.byType(SceneViewport))
        .camera
        .toRenderCamera()
        .position;

    testWidgets('two fingers orbit', (tester) async {
      await open(tester);
      final was = eye(tester);

      await twoFingers(tester, const Offset(80, 0));

      // Moved around what it was looking at, rather than towards it.
      final now = eye(tester);
      expect((now - was).length, greaterThan(0.5));
      expect(now.length, closeTo(was.length, 0.5));
    });

    testWidgets('shift and two fingers pan', (tester) async {
      await open(tester);
      final wasAt = tester
          .widget<SceneViewport>(find.byType(SceneViewport))
          .camera
          .target
          .clone();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await twoFingers(tester, const Offset(80, 0));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      final nowAt =
          tester.widget<SceneViewport>(find.byType(SceneViewport)).camera.target;
      expect((nowAt - wasAt).length, greaterThan(0.05));
    });

    testWidgets('pinching zooms', (tester) async {
      await open(tester);
      final was = tester
          .widget<SceneViewport>(find.byType(SceneViewport))
          .camera
          .distance;

      await twoFingers(tester, Offset.zero, scale: 1.4);

      final now = tester
          .widget<SceneViewport>(find.byType(SceneViewport))
          .camera
          .distance;
      expect(now, lessThan(was));
    });

    testWidgets('two fingers steer while flying, with nothing held',
        (tester) async {
      await open(tester);
      await tester.tapAt(tester.getCenter(find.byType(SceneViewport)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pump();

      final was = eye(tester);
      await twoFingers(tester, const Offset(60, 0), settle: false);

      // Looking keeps the eye where it is; orbiting would have moved it.
      expect((eye(tester) - was).length, lessThan(1e-6));
    });
  });

  group('building geometry', () {
    /// Adds a shape through the Add menu.
    Future<void> addShape(WidgetTester tester, String kind) async {
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SubmenuButton, 'Shape'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text(kind),
      ));
      await tester.pumpAndSettle();
    }

    /// The shape object in the open scene.
    SceneObject shapeIn(WidgetTester tester) {
      final shell = tester.widget<SceneViewport>(find.byType(SceneViewport));
      return shell.workspace.loaded!.scene!.objects
          .firstWhere((o) => o.kind == ObjectKind.shape);
    }

    Future<void> scrollInspector(WidgetTester tester) async {
      await tester.drag(
        find.descendant(
          of: find.byType(Inspector),
          matching: find.byType(ListView),
        ),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a shape can be added and is parametric', (tester) async {
      await open(tester);
      await addShape(tester, 'Stairs');

      final object = shapeIn(tester);
      expect(object.shape!.kind, ShapeKind.stairs);
      expect(object.isParametric, isTrue,
          reason: 'it is a set of numbers until somebody edits it');
      expect(object.geometry, isNull);
    });

    testWidgets('its parameters are in the inspector', (tester) async {
      await open(tester);
      await addShape(tester, 'Cylinder');
      await scrollInspector(tester);

      // The controls that belong to a cylinder and to nothing else.
      expect(find.text('Sides'), findsOneWidget);
      expect(find.text('Height cuts'), findsOneWidget);
      // And not a torus's.
      expect(find.text('Tube'), findsNothing);
    });

    testWidgets('every kind offers its own parameters', (tester) async {
      await open(tester);

      for (final (kind, control) in const [
        ('Torus', 'Tube'),
        ('Door', 'Side width'),
        ('Sphere', 'Divisions'),
      ]) {
        await addShape(tester, kind);
        await scrollInspector(tester);
        expect(find.text(control), findsOneWidget, reason: kind);
      }
    });

    testWidgets('it is written out so the renderer can draw it',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');

      // An object is the built-in cube or a glTF file, and there is no third
      // way in — so geometry built here becomes a file.
      final built = Directory(p.join(root.path, '.orbis', 'geometry'));
      expect(built.existsSync(), isTrue);
      expect(built.listSync().where((f) => f.path.endsWith('.glb')),
          isNotEmpty);
    });

    testWidgets('the geometry mode is offered for a shape', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);

      expect(find.text('GEOMETRY'), findsOneWidget);
      expect(find.text('Editing'), findsOneWidget);
    });

    testWidgets('G goes into the geometry and round the modes',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
      expect(find.text('Faces'), findsWidgets);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Back out to the object, which is what escape is for.
      expect(find.textContaining('Click'), findsNothing);
    });

    /// The materials panel as it stands, so its callbacks can be driven
    /// without fighting a lazy list for a button below the fold.
    MeshPanel panelIn(WidgetTester tester) =>
        tester.widget<MeshPanel>(find.byType(MeshPanel));

    testWidgets('a material slot is added and painted onto a face',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();

      panelIn(tester).onSurfaces(const [Surface(name: 'Stone')], live: false);
      await tester.pumpAndSettle();
      expect(shapeIn(tester).surfaces, hasLength(1));

      // A second, so painting with one is a choice rather than the only
      // thing that could have happened.
      panelIn(tester).onSurfaces(
        const [Surface(name: 'Stone'), Surface(name: 'Brass', metallic: 1)],
        live: false,
      );
      await tester.pumpAndSettle();

      // Picked through the model rather than the viewport: what is under
      // test is painting, and where a click lands is somebody else's test.
      final viewport = tester.widget<SceneViewport>(find.byType(SceneViewport));
      viewport.onPickElement!(0, add: false);
      await tester.pumpAndSettle();

      panelIn(tester).onPaint(1);
      await tester.pumpAndSettle();

      final mesh = shapeIn(tester).currentMesh!;
      expect(mesh.faces[0].material, 1);
      expect(mesh.faces[1].material, 0, reason: 'nothing else was painted');
    });

    testWidgets('painting is one undoable step', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();

      panelIn(tester).onSurfaces(
        const [Surface(name: 'Stone'), Surface(name: 'Brass')],
        live: false,
      );
      await tester.pumpAndSettle();

      final viewport = tester.widget<SceneViewport>(find.byType(SceneViewport));
      viewport.onPickElement!(2, add: false);
      await tester.pumpAndSettle();
      panelIn(tester).onPaint(1);
      await tester.pumpAndSettle();
      expect(shapeIn(tester).currentMesh!.faces[2].material, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(shapeIn(tester).currentMesh!.faces[2].material, 0);
      expect(shapeIn(tester).surfaces, hasLength(2),
          reason: 'the slots are a separate step and are still there');
    });

    testWidgets('the object actions are offered without a selection',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);

      expect(find.text('Conform normals'), findsOneWidget);
      expect(find.text('Flip all normals'), findsOneWidget);
      // And nothing that needs a face selected.
      expect(find.text('Extrude'), findsNothing);
    });

    testWidgets('flipping the normals is one undoable step', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await scrollInspector(tester);

      await tester.tap(find.text('Flip all normals'));
      await tester.pumpAndSettle();

      // It stopped being a shape the moment it was edited.
      final object = shapeIn(tester);
      expect(object.geometry, isNotNull);
      expect(object.isParametric, isFalse);

      await press(tester, LogicalKeyboardKey.keyZ);
      expect(shapeIn(tester).geometry, isNull);
    });

    testWidgets('changing a parameter changes the geometry', (tester) async {
      await open(tester);
      await addShape(tester, 'Stairs');
      await scrollInspector(tester);

      final was = shapeIn(tester).shape!.steps;
      final slider = find.descendant(
        of: find.widgetWithText(FieldRow, 'Steps'),
        matching: find.byType(Slider),
      );
      // Scrolled to rather than assumed: the inspector's lazy list builds
      // what is near the viewport, and a widget it has built can still be
      // above the top of it.
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(shapeIn(tester).shape!.steps, isNot(was));
      // Still a shape: changing a number is not editing the geometry.
      expect(shapeIn(tester).isParametric, isTrue);
    });

    testWidgets('a shape is saved with the scene and comes back',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Arch');
      await save(tester);

      final written =
          File(p.join(root.path, 'scenes', 'main.oscene')).readAsStringSync();
      expect(written, contains('"shape"'));

      final back = SceneDocument.decode(written).scene;
      final object =
          back.objects.firstWhere((o) => o.kind == ObjectKind.shape);
      expect(object.shape!.kind, ShapeKind.arch);
      expect(object.currentMesh, isNotNull);
    });
  });
}
