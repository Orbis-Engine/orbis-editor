import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  group('the edited scene', () {
    test('sends only meshes to the renderer', () {
      final scene = EditorScene.starter();
      final rendered = scene.toRenderScene(const OrbitCamera().toRenderCamera());

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
        [SceneObject(name: 'Sun', kind: ObjectKind.light)],
      );
      // Unrotated, forward is -Z: light falling straight down the view axis.
      final direction = scene
          .toRenderScene(const OrbitCamera().toRenderCamera())
          .sun
          .direction;
      expect(direction.z, closeTo(-1, 1e-9));
    });

    test('an edit to an object reaches the next rendered scene', () {
      final scene = EditorScene.starter();
      final cube = scene.byName('Cube');
      cube.position.setValues(3, 0, 0);

      final rendered = scene.toRenderScene(const OrbitCamera().toRenderCamera());
      final translations =
          rendered.objects.map((o) => o.transform.getTranslation().x);
      expect(translations, contains(3.0));
    });
  });

  group('the orbit camera', () {
    test('stops short of the poles, where the view matrix collapses', () {
      // Far more drag than anyone would apply in one gesture.
      final up = const OrbitCamera().orbit(const Offset(0, -100000));
      final down = const OrbitCamera().orbit(const Offset(0, 100000));

      for (final camera in [up, down]) {
        final position = camera.toRenderCamera().position;
        final target = camera.toRenderCamera().target;
        final view = position - target;
        // A view direction parallel to up is what flips the image.
        expect(view.cross(Vector3(0, 1, 0)).length, greaterThan(0.01));
      }
    });

    test('zooming stays in front of the near plane and inside the world', () {
      var camera = const OrbitCamera();
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
}
