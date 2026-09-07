import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/gizmo.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/snapping.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/editor/workspace.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  late Workspace workspace;
  late History history;
  late SceneObject object;
  late Rect surface;
  final camera = OrbitCamera(yaw: 0.6, pitch: 0.4, distance: 8);
  final snapping = Snapping(step: 0.5);

  /// A shape standing somewhere that is *not* on the grid, which is where
  /// anything somebody made by hand stands.
  setUp(() {
    object = SceneObject(
      id: 'a',
      name: 'A',
      kind: ObjectKind.shape,
      position: Vector3(0, 0.3, 0),
      shape: Shape.of(ShapeKind.cube),
    );
    workspace = Workspace('/project')
      ..add(SceneEntry(id: 's', name: 'S', scene: EditorScene([object])));
    history = History(workspace);
  });

  Future<void> pump(WidgetTester tester) async {
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
            snapping: snapping,
            primary: object.id,
            selected: {object.id},
          ),
        ),
      ),
    ));
    await tester.pump();
    surface = tester.getRect(
      find
          .descendant(
              of: find.byType(SceneViewport), matching: find.byType(Stack))
          .first,
    );
  }

  /// Where the Y handle is on screen.
  Offset handleAt() {
    final projection = ViewportProjection(camera: camera, size: surface.size);
    final gizmo = Gizmo(
      mode: GizmoMode.move,
      pivot: workspace.loaded!.scene!.worldOf(object.id).getTranslation(),
      projection: projection,
    );
    return surface.topLeft +
        projection.project(
          gizmo.pivot + GizmoAxis.y.direction * (gizmo.length * 0.8),
        )!;
  }

  testWidgets('a drag that is not moving does not move what it is holding',
      (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(),
    );
    // Enough to be a drag, and then nothing. The pointer is still; the object
    // should be too.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump();
    }

    final settled = <double>[];
    for (var i = 0; i < 8; i++) {
      // The same position reported again, which is what a held-still pointer
      // sends.
      await gesture.moveBy(Offset.zero);
      await tester.pump();
      settled.add(workspace.loaded!.scene![object.id]!.position.y);
    }
    await gesture.up();

    expect(settled.toSet(), hasLength(1),
        reason: 'it went ${settled.map((y) => y.toStringAsFixed(3)).join(", ")}'
            ' — a snapped position fed back into its own snapping');
  });

  testWidgets('a slow drag only ever goes one way', (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(),
    );

    final heights = <double>[];
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump();
      heights.add(workspace.loaded!.scene![object.id]!.position.y);
    }
    await gesture.up();

    // Dragging upwards, so every step is up or level. A step back down is the
    // flicker.
    for (var i = 1; i < heights.length; i++) {
      expect(heights[i], greaterThanOrEqualTo(heights[i - 1] - 1e-9),
          reason: 'went backwards at step $i: '
              '${heights[i - 1].toStringAsFixed(3)} to '
              '${heights[i].toStringAsFixed(3)}');
    }
    expect(heights.last, greaterThan(heights.first));
  });

  testWidgets('and it still lands on the grid', (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(),
    );
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -3));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    final y = workspace.loaded!.scene![object.id]!.position.y;
    expect(y % snapping.step, closeTo(0, 1e-6),
        reason: 'it started at 0.3 and should have been taken to a line');
  });

  testWidgets('unsnapped, it follows the pointer exactly', (tester) async {
    snapping.on = false;
    addTearDown(() => snapping.on = true);
    await pump(tester);

    final gesture = await tester.startGesture(
      kind: PointerDeviceKind.mouse,
      handleAt(),
    );
    final heights = <double>[];
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump();
      heights.add(workspace.loaded!.scene![object.id]!.position.y);
    }
    await gesture.up();

    // Never backwards, and further up at the end than at the start. The
    // first frame or two are the gesture being recognised, before anything
    // has been asked to move.
    for (var i = 1; i < heights.length; i++) {
      expect(heights[i], greaterThanOrEqualTo(heights[i - 1] - 1e-12));
    }
    expect(heights.last, greaterThan(heights.first + 0.1));
  });
}
