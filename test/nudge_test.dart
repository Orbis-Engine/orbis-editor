import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
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
    root = Directory.systemTemp.createTempSync('orbis_nudge');
    Directory('${root.path}/scenes').createSync(recursive: true);
    final scene = EditorScene([
      SceneObject(
        id: 'a',
        name: 'Crate',
        kind: ObjectKind.shape,
        position: Vector3(0, 0, 0),
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

  Vector3 where(WidgetTester tester) =>
      viewportIn(tester).workspace.loaded!.scene!['a']!.position;

  Future<void> select(WidgetTester tester) async {
    viewportIn(tester).onPick!('a', add: false);
    await tester.pumpAndSettle();
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('an arrow moves one square along the floor', (tester) async {
    await open(tester);
    await select(tester);

    final step = viewportIn(tester).snapping.step;
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(where(tester).x, closeTo(step, 1e-9));
    expect(where(tester).z, 0);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(where(tester).z, closeTo(step, 1e-9));
  });

  testWidgets('shift takes it up and down instead', (tester) async {
    await open(tester);
    await select(tester);

    final step = viewportIn(tester).snapping.step;
    await press(tester, LogicalKeyboardKey.arrowUp, shift: true);
    expect(where(tester).y, closeTo(step, 1e-9));
    expect(where(tester).z, 0, reason: 'not along the floor as well');

    await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
    expect(where(tester).y, closeTo(0, 1e-9));
  });

  testWidgets('option does ten at a time', (tester) async {
    await open(tester);
    await select(tester);

    final step = viewportIn(tester).snapping.step;
    await press(tester, LogicalKeyboardKey.arrowRight, alt: true);
    expect(where(tester).x, closeTo(step * 10, 1e-9));
  });

  testWidgets('each press is its own step to undo', (tester) async {
    await open(tester);
    await select(tester);

    final step = viewportIn(tester).snapping.step;
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(where(tester).x, closeTo(step * 2, 1e-9));

    // Unlike a drag, whose frames merge into one step. Pressing an arrow
    // twice is two things somebody did.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(where(tester).x, closeTo(step, 1e-9));
  });

  testWidgets('nothing selected, nothing moves', (tester) async {
    await open(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(where(tester).x, 0);
  });

  testWidgets('it moves by squares even with the grid switched off',
      (tester) async {
    await open(tester);
    await select(tester);

    final snapping = viewportIn(tester).snapping;
    final step = snapping.step;
    snapping.on = false;

    // An arrow key is a request for a definite amount, and the definite
    // amount on offer is a square — whether or not drags are being snapped.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(where(tester).x, closeTo(step, 1e-9));
  });
}
