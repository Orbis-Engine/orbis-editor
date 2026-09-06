import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:orbis_weather/orbis_weather.dart';
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

    test('the camera is set for the light the scene has, not for the hour', () {
      // How this went wrong the first time: the exposure came from what the
      // clock said and the light came from the scene, and the two disagreed.
      // A bright light at midnight left the viewport a white rectangle with
      // the shapes barely showing through it.
      final scene = EditorScene(
        [
          SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light),
          // A second directional light, which the cycle does not drive: it
          // keeps the strength it was given, and it is what is actually
          // lighting the scene.
          SceneObject(
            id: 'floods',
            name: 'Floods',
            kind: ObjectKind.light,
            power: 200,
            rotation: Vector3(-90, 0, 0),
          ),
        ],
        timeOfDay: 0,
        dayCycle: true,
      );

      final camera = scene
          .toRenderScene(OrbitCamera().toRenderCamera())
          .camera;

      // Stopped down for daylight rather than opened up for a moon that is
      // not what anybody is looking at.
      expect(camera.sensitivity, 100);
      expect(camera.aperture, greaterThan(8));
    });

    test('a scene lit only by a moon opens the camera up', () {
      final scene = withSun(hour: 0);
      final camera =
          scene.toRenderScene(OrbitCamera().toRenderCamera()).camera;

      expect(camera.aperture, lessThan(2));
      expect(camera.sensitivity, greaterThan(1000));
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
    });
  });

  group('weather', () {
    EditorScene withWeather(
      WeatherState air, {
      double bearing = 90,
      double transition = 8,
    }) =>
        EditorScene([
          SceneObject(
            id: 'weather',
            name: 'Weather',
            kind: ObjectKind.weather,
            weather: air,
            windDirection: bearing,
            transitionSeconds: transition,
          ),
          SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light),
        ]);

    final camera = OrbitCamera().toRenderCamera();

    test('mist asks for shape as well as haze', () {
      final scene = withWeather(
        WeatherState.of(WeatherCondition.misty).copyWith(mistSize: 40),
      );
      final fog = scene.toRenderScene(camera).fog;

      expect(fog.structure, greaterThan(0));
      // Stated in metres and sent as turns per metre.
      expect(fog.featureSize, closeTo(1 / 40, 1e-9));
      // The even haze is still under it: banks with no haze behind them read
      // as cut-outs hanging in clear air.
      expect(fog.density, greaterThan(0));
      expect(fog.thickness, greaterThan(0));
    });

    test('clear weather asks for no shape at all', () {
      final fog = withWeather(WeatherState.of(WeatherCondition.clear))
          .toRenderScene(camera)
          .fog;
      expect(fog.structure, 0);
    });

    test('a scene with no weather in it has clear air', () {
      final scene = EditorScene([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);
      expect(scene.toRenderScene(camera).fog.isVisible, isFalse);
    });

    test('hiding the weather clears the air', () {
      final scene = withWeather(WeatherState.of(WeatherCondition.storm));
      scene['weather']!.visible = false;

      expect(scene.toRenderScene(camera).fog.isVisible, isFalse);
    });

    test('the wind blows the way the bearing says', () {
      final east = withWeather(
        WeatherState.of(WeatherCondition.storm),
        bearing: 90,
      ).toRenderScene(camera).fog.wind;
      final north = withWeather(
        WeatherState.of(WeatherCondition.storm),
        bearing: 0,
      ).toRenderScene(camera).fog.wind;

      expect(east.x, greaterThan(east.y.abs()));
      expect(north.y, greaterThan(north.x.abs()));
      // And it carries the speed of the weather it belongs to.
      expect(
        east.length,
        closeTo(WeatherState.of(WeatherCondition.storm).windSpeed, 1e-9),
      );
    });

    test('cloud takes the strength out of what is above the scene', () {
      final clear = withWeather(WeatherState.of(WeatherCondition.clear));
      final covered = withWeather(WeatherState.of(WeatherCondition.overcast));

      final bright = clear.toRenderScene(camera).lights.single;
      final dull = covered.toRenderScene(camera).lights.single;

      expect(dull.intensity, lessThan(bright.intensity * 0.3));
      // And widens it, which is what softens the shadows.
      expect(dull.sunAngularRadius, greaterThan(bright.sunAngularRadius * 10));
    });

    test('cloud is drawn in the sky, not in the fog', () {
      // The two are different weather and were being confused: what was
      // called cloud only dimmed the light, and what was drawn was the mist
      // at ground level. Cover now puts something overhead.
      final clear = withWeather(WeatherState.of(WeatherCondition.clear));
      final covered = withWeather(WeatherState.of(WeatherCondition.overcast));

      expect(clear.toRenderScene(camera).sky.clouds.isVisible, isFalse);

      final sky = covered.toRenderScene(camera).sky.clouds;
      expect(sky.isVisible, isTrue);
      expect(sky.cover, greaterThan(0.5));
      // Overhead, in metres, rather than anywhere near the ground.
      expect(sky.altitude, greaterThan(40));
      // And carried faster than anything at ground level is.
      expect(
        sky.wind.length,
        greaterThan(covered.toRenderScene(camera).fog.wind.length),
      );
    });

    test('the cloud is lit from where the light actually comes from', () {
      // The whole point of the sky being one object: a sun drawn in one
      // place and a cloud lit from another is the single thing that gives a
      // sky away, and it can only be got wrong if they are two objects.
      final scene = withWeather(WeatherState.of(WeatherCondition.fair));
      final rendered = scene.toRenderScene(camera);

      final beam = rendered.lights
          .firstWhere((light) => light.kind == OrbisLightKind.directional);

      // Towards the body is away from where its light travels.
      final towards = -beam.direction..normalize();
      expect((rendered.sky.bodyDirection - towards).length, lessThan(0.001));
    });

    test('each shape of cloud is a different shape', () {
      // Not presets of one shape with the numbers moved: they differ in how
      // high the base sits and how deep the layer is, and no slider reaches
      // either.
      final cumulus = OrbisClouds.cumulus(cover: 0.5);
      final cirrus = OrbisClouds.cirrus(cover: 0.5);
      final storm = OrbisClouds.cumulonimbus(cover: 0.5);

      // Ice needs the cold seven kilometres up; cumulus condense far lower.
      expect(cirrus.altitude, greaterThan(cumulus.altitude * 4));
      // A thunderhead is deep. That depth is why its base is dark.
      expect(storm.thickness, greaterThan(cumulus.thickness * 3));
      // And it is nearly a smooth sheet at one end and a cauliflower at the
      // other.
      expect(OrbisClouds.stratus(cover: 0.5).billow, lessThan(0.2));
      expect(cumulus.billow, greaterThan(0.7));
    });

    test('a condition brings its own shape, and a choice overrules it', () {
      final scene = withWeather(WeatherState.of(WeatherCondition.storm));
      final weather = scene.objects
          .firstWhere((object) => object.kind == ObjectKind.weather);
      weather.condition = WeatherCondition.storm;

      // A storm is a thunderhead, and a thunderhead is deep.
      final automatic = scene.toRenderScene(camera).sky.clouds;
      expect(automatic.thickness, greaterThan(2000));

      // Until somebody says otherwise, at which point it is a different
      // shape: streaks of ice rather than a folded cauliflower.
      weather.cloudKind = CloudKind.cirrus;
      final chosen = scene.toRenderScene(camera).sky.clouds;
      expect(chosen.thickness, lessThan(automatic.thickness / 2));
      expect(chosen.density, lessThan(automatic.density / 3));

      // Including saying there should be none.
      weather.cloudKind = CloudKind.none;
      expect(scene.toRenderScene(camera).sky.clouds.isVisible, isFalse);
    });

    test('the ground mist and the sky are set apart', () {
      final scene = withWeather(
        WeatherState.of(WeatherCondition.misty).copyWith(cloudCover: 0),
      );
      final rendered = scene.toRenderScene(camera);

      // Mist near the ground with a clear sky over it is a real morning, and
      // it has to be possible to ask for it.
      expect(rendered.fog.structure, greaterThan(0));
      expect(rendered.sky.clouds.isVisible, isFalse);
    });

    test('cloud puts that light back as sky', () {
      final clear = withWeather(WeatherState.of(WeatherCondition.clear));
      final covered = withWeather(WeatherState.of(WeatherCondition.overcast));

      expect(
        covered.toRenderScene(camera).sky.ambient,
        greaterThan(clear.toRenderScene(camera).sky.ambient * 2),
      );
    });

    test('a change of condition arrives over time rather than at once', () {
      final scene = withWeather(
        WeatherState.of(WeatherCondition.clear),
        transition: 10,
      );
      final object = scene['weather']!;

      object.blendFrom = WeatherState.of(WeatherCondition.clear);
      object.blendSince = 0;
      object.weather = WeatherState.of(WeatherCondition.storm);

      scene.clock = 0;
      expect(scene.weatherNow!.cloudCover,
          closeTo(WeatherState.of(WeatherCondition.clear).cloudCover, 1e-9));

      scene.clock = 5;
      final half = scene.weatherNow!.cloudCover;
      expect(half, greaterThan(0.4));
      expect(half, lessThan(0.6));

      scene.clock = 11;
      expect(scene.weatherNow!.cloudCover, 1);
    });

    test('a scene in the middle of changing its weather is animated', () {
      final scene = withWeather(
        WeatherState.of(WeatherCondition.clear),
        transition: 10,
      );
      scene['weather']!
        ..blendFrom = WeatherState.of(WeatherCondition.storm)
        ..blendSince = 0;

      scene.clock = 2;
      expect(scene.isAnimated, isTrue);

      // Settled: the renderer moves the cloud on its own clock from here, so
      // the editor has nothing left to tick for.
      scene.clock = 20;
      expect(scene.isAnimated, isFalse);
    });

    test('rain falls as streaks and snow as flakes', () {
      final wet = withWeather(WeatherState.of(WeatherCondition.rain))
          .toRenderScene(camera)
          .precipitation;
      final white = withWeather(WeatherState.of(WeatherCondition.snow))
          .toRenderScene(camera)
          .precipitation;

      expect(wet.isVisible, isTrue);
      expect(white.isVisible, isTrue);

      // How far a drop travels while the shutter is open, which is the whole
      // difference between the two. A flake is not a point — it has to be
      // large enough to see — so this is a ratio rather than an order of
      // magnitude.
      expect(wet.stretch, greaterThan(white.stretch * 4));
      expect(wet.fall, greaterThan(white.fall * 5));
      // And there are more drops in rain than flakes in snow.
      expect(wet.dropsPerMetre, greaterThan(white.dropsPerMetre));
    });

    test('dry weather draws no curtain at all', () {
      final dry = withWeather(WeatherState.of(WeatherCondition.overcast))
          .toRenderScene(camera)
          .precipitation;
      expect(dry.isVisible, isFalse);
    });

    test('half of each is one curtain halfway between', () {
      final both = withWeather(
        WeatherState.of(WeatherCondition.rain).copyWith(rain: 0.4, snow: 0.4),
      ).toRenderScene(camera).precipitation;

      final rain = withWeather(
        WeatherState.of(WeatherCondition.rain).copyWith(rain: 0.8, snow: 0),
      ).toRenderScene(camera).precipitation;

      expect(both.amount, closeTo(rain.amount, 1e-9));
      // Falling at something between the two speeds rather than at either.
      expect(both.fall, lessThan(rain.fall));
      expect(both.fall, greaterThan(1));
    });

    test('the wind carries snow further than it carries rain', () {
      final air = WeatherState.of(WeatherCondition.rain).copyWith(windSpeed: 6);
      final wet =
          withWeather(air).toRenderScene(camera).precipitation.wind.length;
      final white = withWeather(air.copyWith(rain: 0, snow: 0.65))
          .toRenderScene(camera)
          .precipitation
          .wind
          .length;

      expect(white, greaterThan(wet));
    });

    test('lightning strikes, and most of the time it does not', () {
      var struck = 0;
      var brightest = 0.0;

      // Ten minutes of a storm, ten times a second.
      for (var step = 0; step < 6000; step++) {
        final flash = WeatherState.flashAt(step / 10, 0.6);
        if (flash > 0.01) struck++;
        if (flash > brightest) brightest = flash;
      }

      expect(brightest, greaterThan(0.5));
      // Lit for a fraction of the time. A storm that was bright half the
      // night would be a lamp.
      expect(struck / 6000, lessThan(0.15));
      expect(struck, greaterThan(0));
    });

    test('the same second of the same storm looks the same twice', () {
      expect(WeatherState.flashAt(42.5, 0.6), WeatherState.flashAt(42.5, 0.6));
      expect(WeatherState.flashAt(42.5, 0), 0);
    });

    test('a strike brightens what is above the scene', () {
      final scene = withWeather(WeatherState.of(WeatherCondition.storm));

      // Walk until one lands, then compare that instant with a dark one.
      var lit = 0.0;
      for (var step = 0; step < 4000; step++) {
        final at = step / 20;
        if (WeatherState.flashAt(at, WeatherState.of(WeatherCondition.storm)
                .lightning) >
            0.5) {
          lit = at;
          break;
        }
      }
      expect(lit, greaterThan(0), reason: 'no strike inside three minutes');

      scene.clock = 0.05;
      final dark = scene.toRenderScene(camera);
      scene.clock = lit;
      final flash = scene.toRenderScene(camera);

      expect(flash.lights.single.intensity,
          greaterThan(dark.lights.single.intensity * 5));
      expect(flash.sky.ambient, greaterThan(dark.sky.ambient * 5));
    });

    test('a storm keeps the editor ticking, so the strikes are seen', () {
      final quiet = withWeather(WeatherState.of(WeatherCondition.overcast));
      final storm = withWeather(WeatherState.of(WeatherCondition.storm));

      expect(quiet.isAnimated, isFalse);
      expect(storm.isAnimated, isTrue);
    });

    test('one scene, one answer about the weather', () {
      final scene = withWeather(WeatherState.of(WeatherCondition.storm));
      scene.add(SceneObject(
        id: 'second',
        name: 'Weather',
        kind: ObjectKind.weather,
        weather: WeatherState.of(WeatherCondition.clear),
      ));

      expect(scene.hasSpareWeather, isTrue);
      // The first one is it, and the second is ignored rather than blended
      // with or fought over.
      expect(scene.weatherNow!.mist,
          WeatherState.of(WeatherCondition.storm).mist);
    });
  });

  group('what every scene has', () {
    final camera = OrbitCamera().toRenderCamera();

    EditorScene sharedWith(List<SceneObject> objects) => EditorScene(objects);

    test('shared objects are drawn alongside the open scene', () {
      final open = EditorScene([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);
      final shared = sharedWith([
        SceneObject(id: 'prop', name: 'Prop', kind: ObjectKind.mesh),
      ]);

      final drawn = open.toRenderScene(camera, shared: shared).objects;
      expect(drawn.length, 2);
      // By key, because that is the only thing the renderer knows either of
      // them by — and two scenes' objects must never collide in it.
      expect(
        drawn.map((o) => o.key).toSet(),
        {open['cube']!.renderKey, shared['prop']!.renderKey},
      );
    });

    test('a shared light lights the open scene', () {
      final open = EditorScene([
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh),
      ]);
      final shared = sharedWith([
        SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light),
      ]);

      expect(open.toRenderScene(camera, shared: shared).lights, hasLength(1));
      // And is what the sky draws its disk for.
      expect(open.toRenderScene(camera, shared: shared).sky.showBody, isTrue);
    });

    test('shared weather is what the scene is in, until it has its own', () {
      final open = EditorScene([]);
      final shared = sharedWith([
        SceneObject(
          id: 'weather',
          name: 'Weather',
          kind: ObjectKind.weather,
          weather: WeatherState.of(WeatherCondition.storm),
        ),
      ]);

      expect(
        open.toRenderScene(camera, shared: shared).precipitation.isVisible,
        isTrue,
      );

      // A scene that has its own overrules it, so a level can be dry inside a
      // project that rains.
      final dry = EditorScene([
        SceneObject(
          id: 'weather',
          name: 'Weather',
          kind: ObjectKind.weather,
          weather: WeatherState.of(WeatherCondition.clear),
        ),
      ]);
      expect(
        dry.toRenderScene(camera, shared: shared).precipitation.isVisible,
        isFalse,
      );
    });

    test('a scene with its own sun keeps it', () {
      final open = EditorScene([
        SceneObject(
          id: 'stage',
          name: 'Stage',
          kind: ObjectKind.light,
          power: 400,
        ),
      ]);
      final shared = sharedWith([
        SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light, power: 50),
      ]);

      final lights = open.toRenderScene(camera, shared: shared).lights;
      // Both are sent — two lights are two lights — but the scene's own is
      // the one the sky and the day cycle are about.
      expect(lights, hasLength(2));
      expect(lights.first.intensity, greaterThan(lights.last.intensity));
    });

    test('hiding something shared hides it everywhere', () {
      final open = EditorScene([]);
      final shared = sharedWith([
        SceneObject(id: 'prop', name: 'Prop', kind: ObjectKind.mesh)
          ..visible = false,
      ]);

      final drawn = open.toRenderScene(camera, shared: shared).objects;
      expect(drawn.single.visible, isFalse);
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
