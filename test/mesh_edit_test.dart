import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/gizmo.dart';
import 'package:orbis_editor/src/editor/mesh_edit.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  const size = Size(800, 600);

  /// A camera looking at the origin from in front and above, which is where
  /// the editor starts.
  MeshPicker pickerFor(Mesh mesh, {Matrix4? at, OrbitCamera? camera}) {
    final view = camera ?? OrbitCamera(yaw: 0, pitch: 0.3, distance: 6);
    return MeshPicker(
      mesh: mesh,
      transform: at ?? Matrix4.identity(),
      projection: ViewportProjection(camera: view, size: size),
    );
  }

  group('picking a face', () {
    test('a click in the middle hits the near one', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final picker = pickerFor(mesh);

      final hit = picker.faceAt(const Offset(400, 300));

      expect(hit, isNotNull);
      // Nearest wins: a ray through a box crosses two faces and the one it
      // reaches first is the one somebody clicked.
      final normal = mesh.normalOf(mesh.faces[hit!]);
      expect(normal.z, greaterThan(0.5));
    });

    test('a click on nothing hits nothing', () {
      final picker = pickerFor(Shape.of(ShapeKind.cube).build());
      expect(picker.faceAt(const Offset(5, 5)), isNull);
    });

    test('where the object is moved, so is what is clickable', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final moved = pickerFor(
        mesh,
        at: Matrix4.translationValues(40, 0, 0),
      );

      expect(moved.faceAt(const Offset(400, 300)), isNull);
    });

    test('a face is pickable from inside as well as outside', () {
      final mesh = Shape.of(ShapeKind.cube).copyWith(width: 20, depth: 20,
          height: 20).build();
      // The camera is inside the box.
      final picker = pickerFor(
        mesh,
        camera: OrbitCamera(yaw: 0, pitch: 0, distance: 1),
        at: Matrix4.translationValues(0, -10, 0),
      );

      // Culling back faces here would mean nothing is selectable from inside
      // a room, which is most of what somebody builds.
      expect(picker.faceAt(const Offset(400, 300)), isNotNull);
    });
  });

  group('picking a vertex', () {
    test('the nearest one within reach', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final picker = pickerFor(mesh);
      final projection = ViewportProjection(
        camera: OrbitCamera(yaw: 0, pitch: 0.3, distance: 6),
        size: size,
      );

      final corner = projection.project(mesh.positions[2])!;
      expect(picker.vertexAt(corner), 2);
    });

    test('nothing when the click is nowhere near', () {
      final picker = pickerFor(Shape.of(ShapeKind.cube).build());
      expect(picker.vertexAt(const Offset(10, 10)), isNull);
    });

    test('a corner with no area is still clickable', () {
      // A ray through a corner misses every triangle; what somebody means by
      // clicking near one is "that one, the nearest".
      final mesh = Shape.of(ShapeKind.cube).build();
      final picker = pickerFor(mesh);
      final projection = ViewportProjection(
        camera: OrbitCamera(yaw: 0, pitch: 0.3, distance: 6),
        size: size,
      );
      final corner = projection.project(mesh.positions[6])!;

      expect(picker.vertexAt(corner + const Offset(4, 4)), 6);
    });
  });

  group('picking an edge', () {
    test('the nearest line within reach', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final picker = pickerFor(mesh);
      final projection = ViewportProjection(
        camera: OrbitCamera(yaw: 0, pitch: 0.3, distance: 6),
        size: size,
      );

      final a = projection.project(mesh.positions[2])!;
      final b = projection.project(mesh.positions[3])!;
      final found = picker.edgeAt(Offset.lerp(a, b, 0.5)!);

      expect(found, isNotNull);
      expect({found!.$1, found.$2}, {2, 3});
    });

    test('nothing far from any of them', () {
      final picker = pickerFor(Shape.of(ShapeKind.cube).build());
      expect(picker.edgeAt(const Offset(20, 20)), isNull);
    });
  });

  group('what is selected', () {
    test('knows how much is in it, per mode', () {
      final selection = ElementSelection(
        vertices: {1, 2},
        edges: {(0, 1)},
        faces: {3, 4, 5},
      );

      expect(selection.countIn(ElementMode.vertex), 2);
      expect(selection.countIn(ElementMode.edge), 1);
      expect(selection.countIn(ElementMode.face), 3);
      expect(selection.isEmpty, isFalse);
    });

    test('a face that has gone is skipped rather than crashed on', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final selection = ElementSelection(faces: {2, 99});

      // Every operation makes new faces and drops old ones; a selection that
      // held the objects would go stale, and one that holds positions has to
      // cope with the list being shorter.
      expect(selection.facesIn(mesh), hasLength(1));
    });

    test('the points it touches come from whichever mode made it', () {
      final mesh = Shape.of(ShapeKind.cube).build();

      expect(ElementSelection(vertices: {0, 1}).pointsIn(mesh), {0, 1});
      expect(ElementSelection(edges: {(0, 3)}).pointsIn(mesh), {0, 3});
      expect(ElementSelection(faces: {0}).pointsIn(mesh),
          mesh.faces.first.vertices.toSet());
    });

    test('the pivot is the middle of what is selected', () {
      final mesh = Shape.of(ShapeKind.cube).build();
      final top = mesh.faces.indexWhere((f) => mesh.normalOf(f).y > 0.9);

      final pivot = ElementSelection(faces: {top}).pivotIn(mesh)!;
      expect(pivot.y, closeTo(1, 1e-9));
      expect(pivot.x, closeTo(0, 1e-9));
    });

    test('an empty selection has no pivot rather than one at the origin', () {
      expect(ElementSelection().pivotIn(Shape.of(ShapeKind.cube).build()),
          isNull);
    });

    test('a copy does not share its sets', () {
      final was = ElementSelection(faces: {1});
      final copy = was.copy()..faces.add(2);

      expect(was.faces, {1});
      expect(copy.faces, {1, 2});
    });
  });

  group('the modes', () {
    test('cycle round', () {
      expect(ElementMode.vertex.next, ElementMode.edge);
      expect(ElementMode.edge.next, ElementMode.face);
      expect(ElementMode.face.next, ElementMode.vertex);
    });
  });
}
