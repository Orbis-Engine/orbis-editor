import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/inspector.dart';
import 'package:orbis_editor/src/editor/outliner.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_scope');
    Directory('${root.path}/scenes').createSync(recursive: true);
    final scene = EditorScene([
      SceneObject(
        id: 'a',
        name: 'Crate',
        kind: ObjectKind.shape,
        shape: Shape.of(ShapeKind.cube),
      ),
    ]);
    File('${root.path}/scenes/main.oscene')
        .writeAsStringSync(SceneDocument.encode(scene, name: 'main'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: EditorShell(
        project: Project(
          name: 'T',
          directory: root.path,
          lastOpened: DateTime(2026),
        ),
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  SceneViewport viewportIn(WidgetTester tester) =>
      tester.widget<SceneViewport>(find.byType(SceneViewport));

  /// Moves the object the way a drag does: one command, merged.
  void moveTo(WidgetTester tester, double y) {
    final viewport = viewportIn(tester);
    viewport.history!.run(TransformMany(
      sceneId: viewport.workspace.loaded!.id,
      field: TransformField.position,
      what: 'Crate',
      changes: {'a': (from: Vector3.zero(), to: Vector3(0, y, 0))},
    ));
  }

  testWidgets('a move shows in the inspector without the rest rebuilding',
      (tester) async {
    await open(tester);
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();

    final outlinerWas = tester.widget<Outliner>(find.byType(Outliner));

    moveTo(tester, 3.25);
    await tester.pump();

    // The number is live, which is the whole reason not to simply stop
    // rebuilding the inspector.
    expect(find.text('3.25'), findsWidgets);

    // And the outliner is the very same widget, so Flutter never went near
    // its subtree — no rebuild, no layout, no paint.
    expect(
      identical(tester.widget<Outliner>(find.byType(Outliner)), outlinerWas),
      isTrue,
      reason: 'a name is the same name at a different height',
    );
  });

  testWidgets('anything that is not a move rebuilds everything',
      (tester) async {
    await open(tester);
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();

    final was = tester.widget<Outliner>(find.byType(Outliner));

    final viewport = viewportIn(tester);
    viewport.history!.run(Rename(
      sceneId: viewport.workspace.loaded!.id,
      id: 'a',
      from: 'Crate',
      to: 'Barrel',
    ));
    await tester.pumpAndSettle();

    expect(identical(tester.widget<Outliner>(find.byType(Outliner)), was),
        isFalse);
    expect(find.text('Barrel'), findsWidgets);
  });

  testWidgets('undoing a move is not itself a move', (tester) async {
    await open(tester);
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();

    moveTo(tester, 5);
    await tester.pump();
    final was = tester.widget<Outliner>(find.byType(Outliner));

    viewportIn(tester).history!.undo();
    await tester.pumpAndSettle();

    // Stepping back through history changes what is dirty and what the undo
    // label says, and something has to notice.
    expect(identical(tester.widget<Outliner>(find.byType(Outliner)), was),
        isFalse);
  });

  testWidgets('a panel opened during a drag is built rather than missing',
      (tester) async {
    await open(tester);
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();

    moveTo(tester, 1);
    await tester.pump();

    // Opening a panel is a setState of its own, so the frame it lands on is
    // a deep one and it gets built like anything else.
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text('UVs'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('UVS'), findsWidgets);
  });

  testWidgets('the inspector still follows a change of selection',
      (tester) async {
    await open(tester);
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();
    expect(find.byType(VectorRow), findsWidgets);

    moveTo(tester, 2);
    await tester.pump();

    viewportIn(tester).onPick!(null, add: false);
    await tester.pumpAndSettle();
    expect(find.byType(VectorRow), findsNothing,
        reason: 'nothing selected, nothing to show');
  });
}
