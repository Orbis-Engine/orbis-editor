import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/boundary.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  SceneObject shapeWith(Boundary boundary, {Mesh? mesh}) => SceneObject(
        id: 'a',
        name: 'A',
        kind: ObjectKind.shape,
        shape: mesh == null ? Shape.of(ShapeKind.cube) : null,
        geometry: mesh,
        boundary: boundary,
      );

  ({Vector3 origin, Vector3 direction}) fromAbove(double x, double z) =>
      (origin: Vector3(x, 50, z), direction: Vector3(0, -1, 0));

  group('what it is', () {
    test('a shape gets the mesh by default, because a box is right by luck',
        () {
      expect(SceneObject(id: 'a', name: 'A', kind: ObjectKind.shape).boundary
          .kind, BoundaryKind.mesh);
    });

    test('a mesh boundary is the shape, grown by the padding', () {
      final shell = Boundary(padding: 0.1).meshFrom(cube())!;
      expect(shell.faceCount, 6);
      expect(shell.bounds.max.x, closeTo(cube().bounds.max.x + 0.1, 1e-9));
    });

    test('a box boundary has no mesh to test against', () {
      expect(
        Boundary(kind: BoundaryKind.box).meshFrom(cube()),
        isNull,
      );
    });

    test('a mesh boundary with nothing to follow has none either', () {
      expect(Boundary().meshFrom(null), isNull);
      expect(Boundary().meshFrom(Mesh()), isNull);
    });

    test('padding grows the box in every direction', () {
      final natural = (min: Vector3.all(-1), max: Vector3.all(1));
      final box = Boundary(padding: 0.25).boxFrom(natural);
      expect(box.min.x, closeTo(-1.25, 1e-9));
      expect(box.max.z, closeTo(1.25, 1e-9));
    });

    test('an offset moves it without resizing it', () {
      final natural = (min: Vector3.all(-1), max: Vector3.all(1));
      final box = Boundary(offset: Vector3(0, 2, 0)).boxFrom(natural);
      expect(box.min.y, closeTo(1, 1e-9));
      expect(box.max.y, closeTo(3, 1e-9));
      expect(box.max.x - box.min.x, closeTo(2, 1e-9));
    });

    test('an offset moves the mesh too', () {
      final shell = Boundary(offset: Vector3(5, 0, 0)).meshFrom(cube())!;
      expect(shell.bounds.min.x, closeTo(cube().bounds.min.x + 5, 1e-9));
    });
  });

  group('what a click reaches', () {
    test('padding makes a shape easier to hit', () {
      final tight = EditorScene([shapeWith(Boundary())]);
      final loose = EditorScene([shapeWith(Boundary(padding: 0.3))]);
      // Just outside the cube, and inside the padded one.
      final ray = fromAbove(0.65, 0);

      expect(tight.objectAlong(ray.origin, ray.direction), isNull);
      expect(loose.objectAlong(ray.origin, ray.direction), 'a');
    });

    test('a box boundary fills the notch a mesh one leaves open', () {
      final ell = PolyShape(points: [
        Vector3(-1, 0, -1),
        Vector3(-1, 0, 1),
        Vector3(0, 0, 1),
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(1, 0, -1),
      ], height: 1).build();

      final ray = fromAbove(0.5, 0.5);
      expect(
        EditorScene([shapeWith(Boundary(), mesh: ell)])
            .objectAlong(ray.origin, ray.direction),
        isNull,
        reason: 'the notch is a hole, and a mesh boundary knows it',
      );
      expect(
        EditorScene([
          shapeWith(Boundary(kind: BoundaryKind.box), mesh: ell)
        ]).objectAlong(ray.origin, ray.direction),
        'a',
        reason: 'a box does not, and sometimes that is what somebody wants',
      );
    });

    test('none means none', () {
      final scene =
          EditorScene([shapeWith(Boundary(kind: BoundaryKind.none))]);
      final ray = fromAbove(0, 0);
      expect(scene.objectAlong(ray.origin, ray.direction), isNull,
          reason: 'decoration to walk through is decoration not to click');
    });

    test('an offset boundary is hit where it is, not where the shape is', () {
      final scene = EditorScene([
        shapeWith(
          Boundary(kind: BoundaryKind.box),
        )..boundary = Boundary(offset: Vector3(3, 0, 0), kind: BoundaryKind.box),
      ]);
      expect(
        scene.objectAlong(fromAbove(3, 0).origin, fromAbove(3, 0).direction),
        'a',
      );
      expect(
        scene.objectAlong(fromAbove(0, 0).origin, fromAbove(0, 0).direction),
        isNull,
      );
    });
  });

  group('through the file', () {
    test('it goes with the object', () {
      final object = shapeWith(Boundary(
        kind: BoundaryKind.box,
        padding: 0.15,
        offset: Vector3(0, 0.5, 0),
      ));
      final back = SceneDocument.decode(
        SceneDocument.encode(EditorScene([object]), name: 'A'),
      ).scene.objects.single;

      expect(back.boundary.kind, BoundaryKind.box);
      expect(back.boundary.padding, 0.15);
      expect(back.boundary.offset.y, 0.5);
    });

    test('a boundary nobody changed writes nothing', () {
      expect(Boundary().toJson(), isEmpty);
    });

    test('rubbish reads back as nothing', () {
      expect(Boundary.fromJson(null), isNull);
      expect(Boundary.fromJson('mesh'), isNull);
      // An empty map is a boundary nobody described, which is the default.
      expect(Boundary.fromJson(const {})!.kind, BoundaryKind.mesh);
    });

    test('a copy of an object gets its own offset', () {
      final object = shapeWith(Boundary(offset: Vector3(1, 0, 0)));
      final copy = object.copy();
      copy.boundary.offset.x = 9;
      expect(object.boundary.offset.x, 1);
    });
  });
}
