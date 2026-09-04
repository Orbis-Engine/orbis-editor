import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  group('the edited scene', () {
    test('sends only meshes to the renderer', () {
      final scene = EditorScene.starter();
      final rendered = scene.toRenderScene(OrbitCamera().toRenderCamera());

      expect(
        rendered.objects.length,
        scene.objects.where((o) => o.kind == ObjectKind.mesh).length,
      );
      // The sun, the camera and the scene root have no geometry; sending them
      // would draw a cube where the light is.
      expect(rendered.objects.length, lessThan(scene.objects.length));
    });

    test('converts colour out of sRGB, because shading is linear', () {
      // Mid grey: 0.5 in sRGB is about 0.21 in linear, and a renderer handed
      // 0.5 shows a scene that reads as washed out rather than wrong.
      final linear = EditorScene.linearFromColour(const Color(0xFF808080));
      expect(linear.x, closeTo(0.2158, 0.001));
    });

    test('points the sun where its rotation points', () {
      final scene = EditorScene(
        [SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light)],
      );
      // Unrotated, forward is -Z: light falling straight down the view axis.
      final direction = scene
          .toRenderScene(OrbitCamera().toRenderCamera())
          .sun
          .direction;
      expect(direction.z, closeTo(-1, 1e-9));
    });

    test('an edit to an object reaches the next rendered scene', () {
      final scene = EditorScene.starter();
      final cube = scene['cube']!;
      cube.position.setValues(3, 0, 0);
      scene.invalidate();

      final rendered = scene.toRenderScene(OrbitCamera().toRenderCamera());
      final translations =
          rendered.objects.map((o) => o.transform.getTranslation().x);
      expect(translations, contains(3.0));
    });
  });

  group('the orbit camera', () {
    test('stops short of the poles, where the view matrix collapses', () {
      // Far more drag than anyone would apply in one gesture.
      final up = OrbitCamera().orbit(const Offset(0, -100000));
      final down = OrbitCamera().orbit(const Offset(0, 100000));

      for (final camera in [up, down]) {
        final position = camera.toRenderCamera().position;
        final target = camera.toRenderCamera().target;
        final view = position - target;
        // A view direction parallel to up is what flips the image.
        expect(view.cross(Vector3(0, 1, 0)).length, greaterThan(0.01));
      }
    });

    test('zooming stays in front of the near plane and inside the world', () {
      var camera = OrbitCamera();
      for (var i = 0; i < 200; i++) {
        camera = camera.zoom(-500);
      }
      expect(camera.distance, greaterThan(1.0));

      for (var i = 0; i < 400; i++) {
        camera = camera.zoom(500);
      }
      expect(camera.distance, lessThanOrEqualTo(200.0));
    });
  });

  group('framing', () {
    test('fits a thing that is off to one side', () {
      final scene = EditorScene.starter();
      scene['crate']!.position.setValues(20, 0, 0);
      scene.invalidate();

      final bounds = scene.boundsOf('crate');
      expect(bounds.centre.x, closeTo(20, 1e-6));

      final framed =
          OrbitCamera().framing(centre: bounds.centre, radius: bounds.radius);
      // The camera now looks at the crate rather than the origin.
      expect(framed.target.x, closeTo(20, 1e-6));
    });

    test('keeps the angle, so framing is not also a new shot', () {
      final camera = OrbitCamera(yaw: 1.2, pitch: -0.4);
      final framed =
          camera.framing(centre: Vector3(5, 0, 0), radius: 2);

      expect(framed.yaw, camera.yaw);
      expect(framed.pitch, camera.pitch);
    });

    test('a group is framed by everything in it', () {
      final scene = EditorScene.starter();
      final group = scene.boundsOf('props');
      final one = scene.boundsOf('cube');

      // Props holds the cube and the crate, so it is wider than either.
      expect(group.radius, greaterThan(one.radius));
    });

    test('something flat does not put the camera inside it', () {
      final scene = EditorScene.starter();
      // The ground is 8 x 0.05 x 8.
      final bounds = scene.boundsOf('ground');
      final framed =
          OrbitCamera().framing(centre: bounds.centre, radius: bounds.radius);

      expect(framed.distance, greaterThan(1.5));
    });

    test('a light has no geometry, and is still framed rather than refused', () {
      final scene = EditorScene.starter();
      final bounds = scene.boundsOf('sun');
      expect(bounds.radius, greaterThan(0));
      expect(bounds.centre.isNaN, isFalse);
    });
  });

  group('panning', () {
    test('moves what the camera looks at, not how it looks', () {
      final camera = OrbitCamera(yaw: 0.6, pitch: 0.35);
      final panned = camera.pan(const Offset(40, 0));

      expect(panned.yaw, camera.yaw);
      expect(panned.distance, camera.distance);
      expect((panned.target - camera.target).length, greaterThan(0));
    });
  });
}
