import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/gizmo.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/mesh_edit.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/editor/workspace.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

/// What one drag reported.
typedef Reported = ({Mesh mesh, ElementSelection selection, String what, bool merge});

void main() {
  /// The cube's top face, whichever position it happens to be at.
  int topFaceOf(Mesh mesh) {
    for (var i = 0; i < mesh.faces.length; i++) {
      if (mesh.normalOf(mesh.faces[i]).y > 0.99) return i;
    }
    throw StateError('no top face');
  }

  late List<Reported> reported;
  late Mesh mesh;
  late Workspace workspace;
  late History history;
  late SceneObject object;

  /// Where the drawing surface actually is.
  ///
  /// Not the widget's own box: the viewport has a margin, so the pixels the
  /// handles are projected into start a few in from the corner. A test that
  /// assumed otherwise would grab a few pixels off every handle and orbit the
  /// camera instead.
  late Rect surface;

  /// What ties one gesture's worth of commands together, as the shell keeps
  /// it.
  Object? gestureKey;
  final camera = OrbitCamera(yaw: 0.6, pitch: 0.4, distance: 8);

  /// Builds a viewport already editing a cube, with [selection] selected.
  Future<void> pump(
    WidgetTester tester, {
    required ElementSelection selection,
    ElementMode mode = ElementMode.face,
  }) async {
    reported = [];
    final scene = workspace.loaded!.scene!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: SceneViewport(
            workspace: workspace,
            camera: camera,
            onCameraChanged: (_) {},
            history: history,
            primary: object.id,
            selected: {object.id},
            editing: (
              object: object,
              mesh: mesh,
              transform: scene.worldOf(object.id),
            ),
            elementMode: mode,
            elementSelection: selection,
            onDragElements: (mesh, selection, what, {required merge}) {
              reported.add((
                mesh: mesh,
                selection: selection,
                what: what,
                merge: merge,
              ));
              // What the shell does with it, so the undo behaviour under test
              // is the real one and not a description of it.
              if (!merge) gestureKey = Object();
              history.run(SetGeometry(
                sceneId: 'a',
                id: object.id,
                name: object.name,
                to: mesh,
                what: what,
                gesture: gestureKey,
              ));
            },
          ),
        ),
      ),
    ));
    await tester.pump();
    surface = tester.getRect(
      find
          .descendant(of: find.byType(SceneViewport), matching: find.byType(Stack))
          .first,
    );
  }

  /// Where a handle is on screen, worked out the same way the viewport does.
  Offset handleAt(GizmoAxis axis, ElementSelection? selection) {
    final scene = workspace.loaded!.scene!;
    final projection = ViewportProjection(camera: camera, size: surface.size);
    final gizmo = Gizmo(
      mode: GizmoMode.move,
      pivot: selection == null
          ? scene.worldOf(object.id).getTranslation()
          : scene.worldOf(object.id).transformed3(selection.pivotIn(mesh)!),
      projection: projection,
    );
    // Not the very end of the arm: a little short of it is well inside the
    // handle's reach whichever way it happens to be pointing.
    final local = projection.project(
      gizmo.pivot + axis.direction * (gizmo.length * 0.8),
    )!;
    return surface.topLeft + local;
  }

  /// Drags a pointer in small steps.
  ///
  /// Not one big move: Flutter reports the start of a drag at wherever the
  /// pointer had reached when the slop was crossed, so a single forty-pixel
  /// move starts the drag forty pixels from the handle — past the end of it,
  /// where there is nothing to grab and the camera orbits instead.
  Future<void> dragBy(
    WidgetTester tester,
    TestGesture gesture,
    Offset total, {
    int steps = 8,
  }) async {
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(total / steps.toDouble());
      await tester.pump();
    }
  }

  setUp(() {
    mesh = Shape.of(ShapeKind.cube).build();
    object = SceneObject(
      id: 'shape',
      name: 'Cube',
      kind: ObjectKind.shape,
      geometry: mesh,
    );
    final scene = EditorScene([object]);
    workspace = Workspace('/project')
      ..add(SceneEntry(id: 'a', name: 'A', scene: scene));
    history = History(workspace);
  });

  testWidgets('dragging a handle moves the selected face and nothing else',
      (tester) async {
    final selection = ElementSelection(faces: {topFaceOf(mesh)});
    await pump(tester, selection: selection);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, selection),
    );
    await dragBy(tester, gesture, const Offset(0, -80));
    await gesture.up();
    await tester.pump();

    expect(reported, isNotEmpty);
    final last = reported.last.mesh;
    expect(last.faceCount, mesh.faceCount, reason: 'a move creates no faces');
    expect(last.vertexCount, mesh.vertexCount);

    final moved = ElementSelection(faces: {topFaceOf(mesh)}).pointsIn(mesh);
    for (var i = 0; i < last.vertexCount; i++) {
      final shift = last.positions[i] - mesh.positions[i];
      if (moved.contains(i)) {
        expect(shift.y, greaterThan(0.1), reason: 'corner $i went up');
      } else {
        expect(shift.length, lessThan(1e-9), reason: 'corner $i stayed');
      }
    }
  });

  testWidgets('every frame after the first folds into one step',
      (tester) async {
    final selection = ElementSelection(faces: {topFaceOf(mesh)});
    await pump(tester, selection: selection);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, selection),
    );
    await dragBy(tester, gesture, const Offset(0, -80));
    await gesture.up();
    await tester.pump();

    expect(reported.length, greaterThan(1), reason: 'a frame each');
    expect(reported.first.merge, isFalse, reason: 'the first starts a step');
    expect(reported.skip(1).every((one) => one.merge), isTrue);
    expect(history.canUndo, isTrue);

    // And the whole gesture undoes at once, back to where it began.
    history.undo();
    final now = workspace.loaded!.scene![object.id]!.currentMesh!;
    for (var i = 0; i < now.vertexCount; i++) {
      expect((now.positions[i] - mesh.positions[i]).length, lessThan(1e-9));
    }
  });

  testWidgets('holding shift extrudes before it moves', (tester) async {
    final selection = ElementSelection(faces: {topFaceOf(mesh)});
    await pump(tester, selection: selection);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, selection),
    );
    await dragBy(tester, gesture, const Offset(0, -60));
    await gesture.up();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(reported.first.what, 'Extrude');
    final made = reported.last.mesh;
    // Four walls where the face was, and the face carried to the end of them.
    expect(made.faceCount, mesh.faceCount + 4);
    expect(made.vertexCount, mesh.vertexCount + 4);
    // The new face is what is selected afterwards, because somebody who has
    // just extruded is almost always about to extrude again.
    expect(reported.last.selection.faces.length, 1);

    final top = made.centreOf(made.faces[reported.last.selection.faces.first]);
    expect(top.y, greaterThan(mesh.centreOf(mesh.faces[topFaceOf(mesh)]).y));
  });

  testWidgets('the extrude is written before anything has moved',
      (tester) async {
    final selection = ElementSelection(faces: {topFaceOf(mesh)});
    await pump(tester, selection: selection);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, selection),
    );
    // Barely a movement — enough to start a drag and no more. Somebody who
    // pulls a face and changes their mind has still made one, and it should
    // be there and be undoable.
    await dragBy(tester, gesture, const Offset(0, -6), steps: 3);
    await gesture.up();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(reported.first.what, 'Extrude');
    expect(reported.first.merge, isFalse);
    expect(reported.first.mesh.faceCount, mesh.faceCount + 4);
  });

  testWidgets('shift on a vertex selection moves, it does not extrude',
      (tester) async {
    final selection = ElementSelection(vertices: {0, 1});
    await pump(tester, selection: selection, mode: ElementMode.vertex);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, selection),
    );
    await dragBy(tester, gesture, const Offset(0, -50));
    await gesture.up();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(reported, isNotEmpty);
    expect(reported.every((one) => one.what == 'Move'), isTrue);
    expect(reported.last.mesh.faceCount, mesh.faceCount);
  });

  testWidgets('with nothing selected the handles move the object again',
      (tester) async {
    await pump(tester, selection: ElementSelection());

    // The handles are back on the object, so a drag on them is an object
    // move — and nothing is reported as a geometry change.
    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(GizmoAxis.y, null),
    );
    await dragBy(tester, gesture, const Offset(0, -40));
    await gesture.up();
    await tester.pump();

    expect(reported, isEmpty);
    expect(workspace.loaded!.scene![object.id]!.position.y, greaterThan(0.1));
  });
}
