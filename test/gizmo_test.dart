import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/gizmo.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  const size = Size(800, 600);
  final camera = OrbitCamera();

  ViewportProjection projectionOf([OrbitCamera? other]) =>
      ViewportProjection(camera: other ?? camera, size: size);

  group('the viewport as pixels', () {
    test('what the camera is pointed at lands in the middle', () {
      final centre = projectionOf().project(camera.target)!;
      expect(centre.dx, closeTo(size.width / 2, 1));
      expect(centre.dy, closeTo(size.height / 2, 1));
    });

    test('a ray through the middle goes where the camera looks', () {
      final projection = projectionOf();
      final ray = projection.rayThrough(
        Offset(size.width / 2, size.height / 2),
      );

      final wanted = (camera.target - projection.eye)..normalize();
      expect((ray.direction - wanted).length, lessThan(1e-6));
    });

    test('something behind the camera does not land anywhere', () {
      final projection = projectionOf();
      final behind = projection.eye + (projection.eye - camera.target) * 2;
      expect(projection.project(behind), isNull);
    });

    test('a handle keeps its size on screen as the camera pulls back', () {
      final near = ViewportProjection(
        camera: OrbitCamera(distance: 5),
        size: size,
      );
      final far = ViewportProjection(
        camera: OrbitCamera(distance: 40),
        size: size,
      );

      // Longer in the world when further away, which is what keeps it the same
      // number of pixels.
      expect(
        far.handleLength(Vector3.zero()),
        greaterThan(near.handleLength(Vector3.zero()) * 4),
      );
    });
  });

  group('clicking into the scene', () {
    EditorScene sceneWith(List<SceneObject> objects) => EditorScene(objects);

    test('a ray through a cube finds it', () {
      final scene = sceneWith([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);

      expect(
        scene.objectAlong(Vector3(0, 0, 10), Vector3(0, 0, -1)),
        'cube',
      );
    });

    test('a ray past everything finds nothing', () {
      final scene = sceneWith([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);

      expect(
        scene.objectAlong(Vector3(0, 40, 10), Vector3(0, 0, -1)),
        isNull,
      );
    });

    test('the nearer of two wins', () {
      final scene = sceneWith([
        SceneObject(id: 'far', name: 'Far', kind: ObjectKind.mesh),
        SceneObject(
          id: 'near',
          name: 'Near',
          kind: ObjectKind.mesh,
          position: Vector3(0, 0, 5),
        ),
      ]);

      expect(scene.objectAlong(Vector3(0, 0, 10), Vector3(0, 0, -1)), 'near');
    });

    test('what is behind the eye is not in front of it', () {
      final scene = sceneWith([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);

      // Looking away from the cube.
      expect(
        scene.objectAlong(Vector3(0, 0, 10), Vector3(0, 0, 1)),
        isNull,
      );
    });

    test('a hidden object is not in the way', () {
      final scene = sceneWith([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh)
          ..visible = false,
      ]);

      expect(scene.objectAlong(Vector3(0, 0, 10), Vector3(0, 0, -1)), isNull);
    });

    test('an object is hit where it stands, not where it started', () {
      final scene = sceneWith([
        SceneObject(
          id: 'cube',
          name: 'Cube',
          kind: ObjectKind.mesh,
          position: Vector3(6, 0, 0),
        ),
      ]);

      expect(scene.objectAlong(Vector3(0, 0, 10), Vector3(0, 0, -1)), isNull);
      expect(scene.objectAlong(Vector3(6, 0, 10), Vector3(0, 0, -1)), 'cube');
    });

    test('a rotated, squashed object is hit at its own angle', () {
      final scene = sceneWith([
        SceneObject(
          id: 'plank',
          name: 'Plank',
          kind: ObjectKind.mesh,
          scale: Vector3(4, 0.1, 0.5),
        ),
      ]);

      // Along the plank: inside. Above where it would be if it were still a
      // cube: past it.
      expect(scene.objectAlong(Vector3(3, 0, 10), Vector3(0, 0, -1)), 'plank');
      expect(scene.objectAlong(Vector3(0, 0.6, 10), Vector3(0, 0, -1)), isNull);
    });
  });

  group('the handles', () {
    Gizmo gizmoAt(Vector3 pivot, {GizmoMode mode = GizmoMode.move}) =>
        Gizmo(mode: mode, pivot: pivot, projection: projectionOf());

    test('the pointer on an arm picks that axis', () {
      final gizmo = gizmoAt(Vector3.zero());
      final onX = gizmo.projection.project(gizmo.endOf(GizmoAxis.x))!;

      expect(gizmo.axisAt(onX), GizmoAxis.x);
    });

    test('the pointer nowhere near picks nothing', () {
      final gizmo = gizmoAt(Vector3.zero());
      expect(gizmo.axisAt(const Offset(5, 5)), isNull);
    });

    test('a ring is grabbed at its edge, not through its middle', () {
      final gizmo = gizmoAt(Vector3.zero(), mode: GizmoMode.rotate);
      final centre = gizmo.projection.project(gizmo.pivot)!;

      // An eighth of the way round, which is between the axes. All three
      // rings pass through the six points where the axes are, so those belong
      // to no one ring and the nearest is whichever happens to be nearest.
      final ring = gizmo.ringOnScreen(GizmoAxis.y);
      final edge = ring[ring.length ~/ 8];

      expect(gizmo.axisAt(edge), GizmoAxis.y);
      // The middle of a ring is a hole, and a gizmo that grabbed there would
      // take the ring nobody was pointing at.
      expect(gizmo.axisAt(centre), isNull);
    });

    test('a drag along an arm only moves along that arm', () {
      final gizmo = gizmoAt(Vector3.zero());
      final from = gizmo.projection.project(gizmo.pivot)!;
      final to = from + const Offset(60, 20);

      final start = gizmo.pointOnAxis(from, GizmoAxis.x)!;
      final end = gizmo.pointOnAxis(to, GizmoAxis.x)!;
      final shift = end - start;

      expect(shift.y.abs(), lessThan(1e-9));
      expect(shift.z.abs(), lessThan(1e-9));
      expect(shift.x.abs(), greaterThan(0));
    });

    test('a quarter turn measures a quarter turn', () {
      final gizmo = gizmoAt(Vector3.zero(), mode: GizmoMode.rotate);

      final angle = gizmo.angleBetween(
        Vector3(1, 0, 0),
        Vector3(0, 0, -1),
        GizmoAxis.y,
      );
      expect(angle, closeTo(math.pi / 2, 1e-9));
    });

    test('turning the other way measures the other sign', () {
      final gizmo = gizmoAt(Vector3.zero(), mode: GizmoMode.rotate);

      final angle = gizmo.angleBetween(
        Vector3(1, 0, 0),
        Vector3(0, 0, 1),
        GizmoAxis.y,
      );
      expect(angle, closeTo(-math.pi / 2, 1e-9));
    });

    test('past a quarter turn keeps going rather than springing back', () {
      final gizmo = gizmoAt(Vector3.zero(), mode: GizmoMode.rotate);

      // Two hundred degrees: the short way round would report the wrong
      // direction, and an object being turned would snap backwards.
      final angle = gizmo.angleBetween(
        Vector3(1, 0, 0),
        Vector3(math.cos(radians(-200)), 0, math.sin(radians(200))),
        GizmoAxis.y,
      );
      expect(angle.abs(), greaterThan(math.pi / 2));
    });

    test('the handles sit where the object is', () {
      final gizmo = gizmoAt(Vector3(3, 1, -2));
      final centre = gizmo.projection.project(Vector3(3, 1, -2))!;
      final drawn = gizmo.projection.project(gizmo.pivot)!;

      expect((centre - drawn).distance, lessThan(1e-9));
    });
  });
}
