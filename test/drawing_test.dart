import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/drawing.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/modelling_panel.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_draw');
    Directory('${root.path}/scenes').createSync(recursive: true);
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
          name: 'Test',
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

  EditorScene sceneIn(WidgetTester tester) =>
      viewportIn(tester).workspace.loaded!.scene!;

  List<SceneObject> shapesIn(WidgetTester tester) =>
      sceneIn(tester).objects.where((o) => o.kind == ObjectKind.shape).toList();

  /// Puts a point down the way the viewport would, on the ground.
  Future<void> point(WidgetTester tester, double x, double z) async {
    viewportIn(tester).onDrawPoint!(
      Vector3(x, 0, z),
      Vector3.zero(),
      Vector3(0, 1, 0),
      null,
    );
    await tester.pump();
  }

  /// Starts a tool from the modelling panel, which is where they live now —
  /// the viewport draws what a tool is doing and does not offer the tool.
  Future<void> startTool(WidgetTester tester, ViewportTool tool) async {
    await tester.tap(find.text('MODELLING').first);
    await tester.pumpAndSettle();
    tester
        .widget<ModellingPanel>(find.byType(ModellingPanel))
        .onTool(tool);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    viewportIn(tester).onDrawFinish!();
    await tester.pumpAndSettle();
  }

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

  group('drawing a shape', () {
    testWidgets('three points and a finish make an object', (tester) async {
      await open(tester);
      final before = shapesIn(tester).length;

      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      await point(tester, 2, 2);
      await finish(tester);

      final made = shapesIn(tester);
      expect(made, hasLength(before + 1));
      expect(made.last.outline, isNotNull);
      expect(made.last.outline!.points, hasLength(3));
      // A solid: a top, a bottom and three walls.
      expect(made.last.currentMesh!.faceCount, 5);
    });

    testWidgets('the tool stops itself when the shape is made',
        (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      await point(tester, 2, 2);
      await finish(tester);

      expect(viewportIn(tester).drawing!.tool, ViewportTool.none);
      expect(viewportIn(tester).drawing!.points, isEmpty);
    });

    testWidgets('the points are kept relative to where the object stands',
        (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 10, 10);
      await point(tester, 10, 12);
      await point(tester, 12, 12);
      await finish(tester);

      final object = shapesIn(tester).last;
      // Standing at the middle of what was drawn, with the points around the
      // object's own origin — so moving it later moves the outline with it.
      expect(object.position.x, closeTo(32 / 3, 1e-9));
      final middle = Vector3.zero();
      for (final at in object.outline!.points) {
        middle.add(at);
      }
      expect(middle.length, closeTo(0, 1e-9));
    });

    testWidgets('two points are not enough, and it says so', (tester) async {
      await open(tester);
      final before = shapesIn(tester).length;

      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      await finish(tester);

      expect(shapesIn(tester), hasLength(before));
      expect(viewportIn(tester).drawing!.tool, ViewportTool.polyShape,
          reason: 'still drawing, so the next click carries on');
    });

    testWidgets('an outline that crosses itself is refused', (tester) async {
      await open(tester);
      final before = shapesIn(tester).length;

      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 2, 2);
      await point(tester, 2, 0);
      await point(tester, 0, 2);
      await finish(tester);

      expect(shapesIn(tester), hasLength(before));
    });

    testWidgets('backspace takes a point back and escape gives up',
        (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      expect(viewportIn(tester).drawing!.points, hasLength(2));

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(viewportIn(tester).drawing!.points, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(viewportIn(tester).drawing!.tool, ViewportTool.none);
    });

    testWidgets('backspace does not delete the selection while drawing',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      final was = shapesIn(tester).length;

      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      expect(shapesIn(tester), hasLength(was),
          reason: 'a very unwelcome surprise halfway through an outline');
    });

    testWidgets('enter finishes it', (tester) async {
      await open(tester);
      final before = shapesIn(tester).length;

      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      await point(tester, 2, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(shapesIn(tester), hasLength(before + 1));
    });

    testWidgets('pressing the tool again puts it away', (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await startTool(tester, ViewportTool.polyShape);

      expect(viewportIn(tester).drawing!.tool, ViewportTool.none);
      expect(viewportIn(tester).drawing!.points, isEmpty);
    });

    testWidgets('the height can be changed afterwards, and undone',
        (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.polyShape);
      await point(tester, 0, 0);
      await point(tester, 0, 2);
      await point(tester, 2, 2);
      await finish(tester);

      final object = shapesIn(tester).last;
      expect(object.outline!.height, 2);
      expect(object.currentMesh!.bounds.max.y, closeTo(2, 1e-9));
    });
  });

  group('cutting', () {
    /// Selects the shape and puts the editor into its geometry.
    Future<void> editShape(WidgetTester tester) async {
      final object = shapesIn(tester).single;
      viewportIn(tester).onPick!(object.id, add: false);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
    }

    /// Puts a cut point down on a face, in world space.
    Future<void> cutPoint(
      WidgetTester tester,
      Vector3 at,
      Vector3 normal,
      int face,
    ) async {
      viewportIn(tester).onDrawPoint!(at, at, normal, face);
      await tester.pump();
    }

    testWidgets('a cut across a face makes two of it', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await editShape(tester);

      final mesh = shapesIn(tester).single.currentMesh!;
      // The top, and two points on opposite edges of it.
      final top = mesh.faces.indexWhere(
        (face) => mesh.normalOf(face).y > 0.99,
      );
      final corners = mesh.pointsOf(mesh.faces[top]);
      final a = (corners[0] + corners[1]) / 2;
      final b = (corners[2] + corners[3]) / 2;

      await startTool(tester, ViewportTool.cut);
      await cutPoint(tester, a, Vector3(0, 1, 0), top);
      await cutPoint(tester, b, Vector3(0, 1, 0), top);
      await finish(tester);

      expect(shapesIn(tester).single.currentMesh!.faceCount, 7);
      expect(viewportIn(tester).drawing!.tool, ViewportTool.none);
    });

    testWidgets('what came out of the cut is what is selected', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await editShape(tester);

      final mesh = shapesIn(tester).single.currentMesh!;
      final top = mesh.faces.indexWhere(
        (face) => mesh.normalOf(face).y > 0.99,
      );
      final corners = mesh.pointsOf(mesh.faces[top]);

      await startTool(tester, ViewportTool.cut);
      await cutPoint(tester, (corners[0] + corners[1]) / 2,
          Vector3(0, 1, 0), top);
      await cutPoint(tester, (corners[2] + corners[3]) / 2,
          Vector3(0, 1, 0), top);
      await finish(tester);

      // Because the next thing somebody does is extrude it, which is why
      // they cut it.
      expect(viewportIn(tester).elementSelection.faces, hasLength(2));
    });

    testWidgets('a cut that starts in the middle is refused', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await editShape(tester);

      final mesh = shapesIn(tester).single.currentMesh!;
      final top = mesh.faces.indexWhere(
        (face) => mesh.normalOf(face).y > 0.99,
      );
      final middle = mesh.centreOf(mesh.faces[top]);
      final corners = mesh.pointsOf(mesh.faces[top]);

      await startTool(tester, ViewportTool.cut);
      await cutPoint(tester, middle, Vector3(0, 1, 0), top);
      await cutPoint(tester, (corners[0] + corners[1]) / 2,
          Vector3(0, 1, 0), top);
      await finish(tester);

      expect(shapesIn(tester).single.currentMesh!.faceCount, 6,
          reason: 'nothing was divided, so nothing changed');
    });

    testWidgets('the cut is one step to undo', (tester) async {
      await open(tester);
      await addShape(tester, 'Cube');
      await editShape(tester);

      final mesh = shapesIn(tester).single.currentMesh!;
      final top = mesh.faces.indexWhere(
        (face) => mesh.normalOf(face).y > 0.99,
      );
      final corners = mesh.pointsOf(mesh.faces[top]);

      await startTool(tester, ViewportTool.cut);
      await cutPoint(tester, (corners[0] + corners[1]) / 2,
          Vector3(0, 1, 0), top);
      await cutPoint(tester, (corners[2] + corners[3]) / 2,
          Vector3(0, 1, 0), top);
      await finish(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(shapesIn(tester).single.currentMesh!.faceCount, 6);
    });

    testWidgets('the tool refuses to start without a shape', (tester) async {
      await open(tester);
      await startTool(tester, ViewportTool.cut);
      expect(viewportIn(tester).drawing!.tool, ViewportTool.none);
    });
  });

  group('the drawing itself', () {
    test('the plane is fixed by the first point', () {
      final drawing = Drawing()..start(ViewportTool.polyShape);
      drawing.planeAt(Vector3.zero(), Vector3(0, 1, 0));
      drawing.planeAt(Vector3(9, 9, 9), Vector3(1, 0, 0));

      expect(drawing.normal!.y, 1, reason: 'the second one is ignored');
      expect(drawing.origin!.x, 0);
    });

    test('a second click in the same place is one point', () {
      final drawing = Drawing()..start(ViewportTool.polyShape);
      expect(drawing.add(Vector3(1, 0, 1)), isTrue);
      expect(drawing.add(Vector3(1, 0, 1)), isFalse);
      expect(drawing.points, hasLength(1));
    });

    test('taking back the first point gives back the plane too', () {
      final drawing = Drawing()..start(ViewportTool.polyShape);
      drawing
        ..planeAt(Vector3.zero(), Vector3(0, 1, 0))
        ..add(Vector3.zero())
        ..undo();

      expect(drawing.normal, isNull,
          reason: 'the next click is free to choose a different surface');
    });

    test('a click near the first point closes a shape and not a cut', () {
      final shape = Drawing()..start(ViewportTool.polyShape);
      for (final at in [
        Vector3.zero(),
        Vector3(0, 0, 2),
        Vector3(2, 0, 2),
      ]) {
        shape.add(at);
      }
      expect(shape.wouldClose(Vector3(0.05, 0, 0)), isTrue);
      expect(shape.wouldClose(Vector3(5, 0, 5)), isFalse);

      final cut = Drawing()..start(ViewportTool.cut);
      for (final at in [
        Vector3.zero(),
        Vector3(0, 0, 2),
        Vector3(2, 0, 2),
      ]) {
        cut.add(at);
      }
      expect(cut.wouldClose(Vector3(0.05, 0, 0)), isFalse,
          reason: 'a cut that comes back to its start is a loop, not a finish');
    });

    test('how much is enough differs between the two', () {
      final shape = Drawing()..start(ViewportTool.polyShape);
      final cut = Drawing()..start(ViewportTool.cut);
      for (final at in [Vector3.zero(), Vector3(0, 0, 1)]) {
        shape.add(at);
        cut.add(at);
      }
      expect(shape.canFinish, isFalse, reason: 'two points enclose nothing');
      expect(cut.canFinish, isTrue, reason: 'two points are a line to cut on');
    });
  });
}
