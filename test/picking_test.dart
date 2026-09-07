import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  SceneObject shapeAt(String id, Vector3 at, {Shape? shape, Mesh? mesh}) =>
      SceneObject(
        id: id,
        name: id,
        kind: ObjectKind.shape,
        position: at,
        shape: shape ?? (mesh == null ? Shape.of(ShapeKind.cube) : null),
        geometry: mesh,
      );

  /// A ray straight down from high above a point.
  ({Vector3 origin, Vector3 direction}) fromAbove(double x, double z) =>
      (origin: Vector3(x, 50, z), direction: Vector3(0, -1, 0));

  group('what a click can reach', () {
    test('a shape is its own size, not two metres', () {
      final scene = EditorScene([shapeAt('a', Vector3.zero())]);
      final cube = Shape.of(ShapeKind.cube).build().bounds;
      // The built-in cube is a metre across, so its own bounds stop well
      // short of the two-metre box everything used to be picked as.
      expect(cube.max.x, lessThan(1));

      final inside = fromAbove(cube.max.x - 0.05, 0);
      expect(scene.objectAlong(inside.origin, inside.direction), 'a');

      final past = fromAbove(cube.max.x + 0.3, 0);
      expect(scene.objectAlong(past.origin, past.direction), isNull,
          reason: 'a click beside a small shape used to select it');
    });

    test('the object behind is found through the gap in an L', () {
      // An L-shaped room, and something standing in the notch of it. A box
      // round the room covers the notch; the room itself does not.
      final ell = PolyShape(points: [
        Vector3(-1, 0, -1),
        Vector3(-1, 0, 1),
        Vector3(0, 0, 1),
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(1, 0, -1),
      ], height: 1).build();

      final scene = EditorScene([
        shapeAt('room', Vector3.zero(), mesh: ell),
        shapeAt('behind', Vector3(0.5, -3, 0.5)),
      ]);

      // Down through the notch, which is the quarter the room does not fill.
      final ray = fromAbove(0.5, 0.5);
      expect(scene.objectAlong(ray.origin, ray.direction), 'behind',
          reason: 'the whole difference between a box round a thing and the '
              'thing');

      // And through a part the room does fill.
      final onto = fromAbove(-0.5, 0.5);
      expect(scene.objectAlong(onto.origin, onto.direction), 'room');
    });

    test('the nearest is still the one picked', () {
      final scene = EditorScene([
        shapeAt('low', Vector3(0, 0, 0)),
        shapeAt('high', Vector3(0, 4, 0)),
      ]);
      final ray = fromAbove(0, 0);
      expect(scene.objectAlong(ray.origin, ray.direction), 'high');
    });

    test('an object with no geometry keeps the placeholder box', () {
      final marker = SceneObject(
        id: 'm',
        name: 'Marker',
        kind: ObjectKind.mesh,
        meshAsset: 'models/thing.glb',
      );
      final box = marker.localBounds();
      expect(box.min.x, -1);
      expect(box.max.y, 1);
    });

    test('a file that says how big it is is believed', () {
      final marker = SceneObject(
        id: 'm',
        name: 'Marker',
        kind: ObjectKind.mesh,
        meshAsset: 'models/thing.glb',
      );
      final told = marker.localBounds(
        reported: (min: Vector3.all(-0.05), max: Vector3.all(0.05)),
      );
      expect(told.max.x, 0.05);

      final scene = EditorScene([marker]);
      // Ten centimetres away: inside the placeholder box, outside the thing.
      final ray = fromAbove(0.1, 0);
      expect(
        scene.objectAlong(
          ray.origin,
          ray.direction,
          boundsOf: (_) => (min: Vector3.all(-0.05), max: Vector3.all(0.05)),
        ),
        isNull,
        reason: 'told how big it is, and it is not that big',
      );
      expect(scene.objectAlong(ray.origin, ray.direction, boundsOf: (_) => null),
          'm',
          reason: 'told nothing, so back to the placeholder');
    });

    test('an object with geometry ignores what a file says', () {
      // The geometry is the truth when there is any: a reported box is only
      // for the objects whose geometry the editor does not hold.
      final object = shapeAt('a', Vector3.zero());
      final told = object.localBounds(
        reported: (min: Vector3.all(-9), max: Vector3.all(9)),
      );
      expect(told.max.x, lessThan(1));
    });

    test('a hidden object cannot be clicked', () {
      final scene = EditorScene([shapeAt('a', Vector3.zero())])
        ..[('a')]!.visible = false;
      final ray = fromAbove(0, 0);
      expect(scene.objectAlong(ray.origin, ray.direction), isNull);
    });

    test('a scaled object is picked at the size it is drawn', () {
      final scene = EditorScene([
        shapeAt('a', Vector3.zero())..scale.setValues(4, 1, 4),
      ]);
      // Well outside a metre-wide cube, well inside one scaled by four.
      final ray = fromAbove(1.5, 0);
      expect(scene.objectAlong(ray.origin, ray.direction), 'a');
    });

    test('an empty mesh falls back to the box rather than never hitting', () {
      final scene = EditorScene([shapeAt('a', Vector3.zero(), mesh: Mesh())]);
      final ray = fromAbove(0, 0);
      expect(scene.objectAlong(ray.origin, ray.direction), 'a');
    });
  });
}
