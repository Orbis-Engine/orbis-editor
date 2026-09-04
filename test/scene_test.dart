import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_light/orbis_light.dart';
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

    test('points a light where its rotation points', () {
      final scene = EditorScene(
        [SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light)],
      );
      // Unrotated, forward is -Z: light falling straight down the view axis.
      final direction = scene
          .toRenderScene(OrbitCamera().toRenderCamera())
          .lights
          .single
          .direction;
      expect(direction.z, closeTo(-1, 1e-9));
    });

    test('states a sun in lux and a bulb in lumens', () {
      final scene = EditorScene([
        SceneObject(
          id: 'sun',
          name: 'Sun',
          kind: ObjectKind.light,
          power: 100,
        ),
        SceneObject(
          id: 'bulb',
          name: 'Bulb',
          kind: ObjectKind.light,
          lightType: LightType.point,
          power: 100,
        ),
      ]);

      final lights = scene.toRenderScene(OrbitCamera().toRenderCamera()).lights;
      final sun = lights.firstWhere((l) => l.kind == OrbisLightKind.directional);
      final bulb = lights.firstWhere((l) => l.kind == OrbisLightKind.point);

      // The same number of watts means two different things, and the units
      // are the whole reason the conversion lives in one place.
      expect(sun.intensity, closeTo(100 * 683, 1));
      expect(bulb.intensity, closeTo(100 * 683, 1));
      // A sun does not fall off, so it is sent no radius to fall off within.
      expect(sun.falloffRadius, 0);
      expect(bulb.falloffRadius, greaterThan(0));
    });

    test('an area light arrives as a point of the same power', () {
      final scene = EditorScene([
        SceneObject(
          id: 'panel',
          name: 'Panel',
          kind: ObjectKind.light,
          lightType: LightType.area,
          power: 100,
          sourceRadius: 0.5,
        ),
      ]);

      final light =
          scene.toRenderScene(OrbitCamera().toRenderCamera()).lights.single;
      expect(light.kind, OrbisLightKind.point);
      // Not a point source, though: it keeps a width, so it still casts a
      // penumbra of about the right size.
      expect(light.sourceRadius, greaterThan(0.2));
    });

    test('hiding a group hides what is inside it', () {
      final scene = EditorScene.starter();
      scene['props']!.visible = false;

      final rendered = scene.toRenderScene(OrbitCamera().toRenderCamera());
      final cube = rendered.objects
          .firstWhere((o) => o.key == scene['cube']!.renderKey);

      // The cube's own flag was never touched. It is hidden because the thing
      // it sits in is.
      expect(scene['cube']!.visible, isTrue);
      expect(cube.visible, isFalse);
    });

    test('a hidden light is left out rather than sent dark', () {
      final scene = EditorScene([
        SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light)
          ..visible = false,
      ]);

      expect(
        scene.toRenderScene(OrbitCamera().toRenderCamera()).lights,
        isEmpty,
      );
    });

    test('an object keeps the key the renderer knows it by', () {
      final scene = EditorScene.starter();
      final before = scene
          .toRenderScene(OrbitCamera().toRenderCamera())
          .objects
          .map((o) => o.key)
          .toList();

      scene['cube']!.position.setValues(3, 0, 0);
      scene.invalidate();

      final after = scene
          .toRenderScene(OrbitCamera().toRenderCamera())
          .objects
          .map((o) => o.key)
          .toList();

      // The whole point: an edit is the same objects in new places, so the
      // renderer moves them rather than building the scene again.
      expect(after, before);
    });

    test('a copy is a new object, not the same one somewhere else', () {
      final original = SceneObject(id: 'a', name: 'A', kind: ObjectKind.mesh);
      expect(original.copyAs(id: 'b').renderKey, isNot(original.renderKey));
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

  group('a scene with a day running', () {
    EditorScene withSun({double hour = 12, bool cycle = true}) => EditorScene(
          [
            SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light),
            SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
          ],
          timeOfDay: hour,
          dayCycle: cycle,
        );

    test('the hour points the light, not the light\'s own rotation', () {
      final scene = withSun(hour: 12);
      // Rotated to point sideways, which the cycle is expected to overrule.
      scene['sun']!.rotation.setValues(0, 90, 0);
      scene.invalidate();

      final light =
          scene.toRenderScene(OrbitCamera().toRenderCamera()).lights.single;
      expect(light.direction.y, lessThan(-0.85));
    });

    test('with the cycle off the light keeps what it was authored with', () {
      final scene = withSun(hour: 12, cycle: false);
      final light =
          scene.toRenderScene(OrbitCamera().toRenderCamera()).lights.single;

      // Unrotated, which is straight down the view axis rather than down from
      // the sky. Turning the cycle off puts the scene back the way it was.
      expect(light.direction.z, closeTo(-1, 1e-9));
    });

    test('the camera opens up when the scene runs into the night', () {
      final day = withSun(hour: 12)
          .toRenderScene(OrbitCamera().toRenderCamera());
      final night = withSun(hour: 0)
          .toRenderScene(OrbitCamera().toRenderCamera());

      expect(night.camera.sensitivity, greaterThan(day.camera.sensitivity));
      expect(night.camera.aperture, lessThan(day.camera.aperture));
    });

    test('the sky is the scene\'s own until the cycle takes it over', () {
      final held = withSun(cycle: false)
        ..skyColour = const Color(0xFF123456);
      final driven = withSun(hour: 12)
        ..skyColour = const Color(0xFF123456);

      final camera = OrbitCamera().toRenderCamera();
      expect(held.toRenderScene(camera).sky.colour.x,
          EditorScene.linearFromColour(const Color(0xFF123456)).x);
      expect(driven.toRenderScene(camera).sky.colour.x,
          isNot(EditorScene.linearFromColour(const Color(0xFF123456)).x));
    });

    test('the light is named for whatever is above the horizon', () {
      final scene = withSun(hour: 12);
      expect(scene.displayNameOf(scene['sun']!), 'Sun');

      scene.timeOfDay = 0;
      expect(scene.displayNameOf(scene['sun']!), 'Moon');
    });

    test('a light somebody has named keeps its name', () {
      final scene = withSun(hour: 0);
      scene['sun']!.name = 'Key light';
      expect(scene.displayNameOf(scene['sun']!), 'Key light');
    });

    test('only the light above the scene follows the sky', () {
      final scene = withSun(hour: 0);
      scene.add(SceneObject(
        id: 'lamp',
        name: 'Sun',
        kind: ObjectKind.light,
        lightType: LightType.point,
      ));

      // Named the same and of the same mind about it, but it is not the one
      // lighting the scene from above, so it is left alone.
      expect(scene.displayNameOf(scene['lamp']!), 'Sun');
    });

    test('the clock is where the day has got to, not where it was saved', () {
      final scene = withSun(hour: 6)..hoursPerSecond = 1;
      scene.clock = 4;

      expect(scene.currentTimeOfDay, closeTo(10, 1e-9));
      // The authored hour is untouched, so saving does not record wherever a
      // clock left running happened to reach.
      expect(scene.timeOfDay, 6);
    });

    test('a scene with nothing moving does not ask to be animated', () {
      expect(withSun(cycle: false).isAnimated, isFalse);
      expect(withSun().isAnimated, isTrue);
      expect((withSun(cycle: false)..mist = 0.5).isAnimated, isTrue);
    });
  });

  group('mist', () {
    EditorScene foggy({double mist = 0.6}) => EditorScene(
          [],
          fogDensity: 0.1,
          fogHeight: 0,
          mist: mist,
        )..mistSpeed = 0.5;

    test('the layer moves as the clock does', () {
      final scene = foggy();
      final camera = OrbitCamera().toRenderCamera();

      final first = scene.toRenderScene(camera).fog;
      scene.clock = 0.9;
      final later = scene.toRenderScene(camera).fog;

      expect(later.density, isNot(closeTo(first.density, 1e-6)));
      expect(later.height, isNot(closeTo(first.height, 1e-6)));
    });

    test('still air stays exactly where it was put', () {
      final scene = foggy(mist: 0);
      final camera = OrbitCamera().toRenderCamera();

      final first = scene.toRenderScene(camera).fog;
      scene.clock = 12.5;
      final later = scene.toRenderScene(camera).fog;

      expect(later.density, first.density);
      expect(later.height, first.height);
    });

    test('it thins and thickens without ever blinking out', () {
      final scene = foggy(mist: 1);
      final camera = OrbitCamera().toRenderCamera();

      for (var step = 0; step < 400; step++) {
        scene.clock = step * 0.05;
        expect(scene.toRenderScene(camera).fog.density, greaterThan(0));
      }
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
