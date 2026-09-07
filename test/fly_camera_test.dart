import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  /// How far apart two points are, for assertions about movement.
  double gap(Vector3 a, Vector3 b) => (a - b).length;

  group('looking around', () {
    test('keeps the eye where it is', () {
      final was = OrbitCamera(yaw: 0.6, pitch: 0.2, distance: 9);
      final looked = was.looking(const Offset(120, 40));

      // Orbiting swings the eye around the target; looking keeps the eye still
      // and moves the target. From inside a room that is the whole difference.
      expect(
        gap(looked.toRenderCamera().position, was.toRenderCamera().position),
        lessThan(1e-9),
      );
    });

    test('changes where it points', () {
      final was = OrbitCamera(yaw: 0.6, pitch: 0.2, distance: 9);
      final looked = was.looking(const Offset(120, 0));

      expect(looked.yaw, isNot(closeTo(was.yaw, 1e-6)));
      expect(gap(looked.target, was.target), greaterThan(0.5));
    });

    test('cannot be turned past straight up or straight down', () {
      var camera = OrbitCamera();
      for (var i = 0; i < 200; i++) {
        camera = camera.looking(const Offset(0, 40));
      }
      // At exactly vertical the up vector and the view direction are parallel
      // and the image flips.
      expect(camera.pitch.abs(), lessThan(1.5708));
      expect(camera.toRenderCamera().position.x.isFinite, isTrue);
    });

    test('orbiting still swings around the target', () {
      final was = OrbitCamera(distance: 9);
      final orbited = was.orbit(const Offset(120, 0));

      expect(gap(orbited.target, was.target), lessThan(1e-9));
      expect(
        gap(orbited.toRenderCamera().position, was.toRenderCamera().position),
        greaterThan(0.5),
      );
    });
  });

  group('flying', () {
    test('forward goes towards what the camera is looking at', () {
      final was = OrbitCamera(yaw: 0.6, pitch: 0.25, distance: 20);
      final flown = was.flying(Vector3(0, 0, 5));

      // Closer to the thing it was looking at, by the distance asked for.
      final before = gap(was.toRenderCamera().position, was.target);
      final after = gap(flown.toRenderCamera().position, was.target);
      expect(before - after, closeTo(5, 1e-6));
    });

    test('the eye and what it looks at move together', () {
      final was = OrbitCamera(yaw: 0.6, pitch: 0.25, distance: 20);
      final flown = was.flying(Vector3(3, 2, 5));

      final eyeMoved =
          flown.toRenderCamera().position - was.toRenderCamera().position;
      final targetMoved = flown.target - was.target;
      expect(gap(eyeMoved, targetMoved), lessThan(1e-9));
      expect(flown.distance, was.distance);
    });

    test('right is right of where it is looking, not right of the world', () {
      final facing = OrbitCamera(yaw: 0, pitch: 0);
      final turned = OrbitCamera(yaw: 1.5707963, pitch: 0);

      final one = facing.flying(Vector3(4, 0, 0)).target;
      final other = turned.flying(Vector3(4, 0, 0)).target;

      // Both moved four metres, in different world directions.
      expect(gap(one, facing.target), closeTo(4, 1e-6));
      expect(gap(other, turned.target), closeTo(4, 1e-6));
      expect(gap(one, other), greaterThan(1));
    });

    test('the axes are unit length, so a metre is a metre', () {
      for (final camera in [
        OrbitCamera(),
        OrbitCamera(yaw: 2.1, pitch: -0.9),
        OrbitCamera(yaw: -0.4, pitch: 1.2),
      ]) {
        final axes = camera.basis;
        expect(axes.right.length, closeTo(1, 1e-9));
        expect(axes.up.length, closeTo(1, 1e-9));
        expect(axes.forward.length, closeTo(1, 1e-9));
      }
    });

    test('the axes are at right angles to each other', () {
      final axes = OrbitCamera(yaw: 0.7, pitch: 0.3).basis;
      expect(axes.right.dot(axes.up), closeTo(0, 1e-9));
      expect(axes.right.dot(axes.forward), closeTo(0, 1e-9));
      expect(axes.up.dot(axes.forward), closeTo(0, 1e-9));
    });

    test('going nowhere changes nothing', () {
      final was = OrbitCamera(yaw: 0.6, pitch: 0.25);
      final flown = was.flying(Vector3.zero());
      expect(gap(flown.target, was.target), lessThan(1e-12));
    });
  });
}
