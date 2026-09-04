import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/sky.dart';

void main() {
  group('the day', () {
    test('the sun is up at noon and the moon at midnight', () {
      expect(DayCycle.at(12).body, CelestialBody.sun);
      expect(DayCycle.at(0).body, CelestialBody.moon);
      expect(DayCycle.at(23).body, CelestialBody.moon);
    });

    test('it comes from overhead at noon', () {
      // Light travelling downwards, which is what a sun overhead does.
      expect(DayCycle.at(12).direction.y, lessThan(-0.85));
    });

    test('it rises on one side and sets on the other', () {
      final morning = DayCycle.at(8).direction;
      final evening = DayCycle.at(16).direction;

      // Light in the morning comes from the opposite side to light in the
      // evening. A sun that went back the way it came would light both ends
      // of a day identically.
      expect(morning.x.sign, isNot(evening.x.sign));
    });

    test('the moon is opposite where the sun would have been', () {
      // Two in the morning, and the sun eight hours later.
      final moon = DayCycle.at(2).direction;
      final sun = DayCycle.at(10).direction;

      // Sideways, they are opposed; the moon is not simply the sun upside
      // down, it is on the other side of the sky.
      expect(moon.x.sign, isNot(sun.x.sign));
      expect(moon.y, lessThan(0));
    });

    test('the light goes warm at the horizon and white overhead', () {
      final dawn = DayCycle.at(6.5).lightColour;
      final noon = DayCycle.at(12).lightColour;

      double warmth(colour) => colour.r - colour.b;
      expect(warmth(dawn), greaterThan(warmth(noon)));
    });

    test('the sky is darker at night than at noon', () {
      double lightness(colour) => colour.r + colour.g + colour.b;
      expect(
        lightness(DayCycle.at(1).skyColour),
        lessThan(lightness(DayCycle.at(12).skyColour)),
      );
    });

    test('a night is many stops darker than a day', () {
      // Not a little darker: about seventeen stops. Which is the whole reason
      // the exposure has to move — on one setting, one of the two is a solid
      // colour.
      expect(DayCycle.at(12).power, greaterThan(DayCycle.at(0).power * 10000));
    });

    test('the camera opens up for the night and stops down for the day', () {
      final night = DayCycle.at(0).exposure;
      final noon = DayCycle.at(12).exposure;

      expect(night.aperture, lessThan(noon.aperture));
      expect(night.shutterSpeed, greaterThan(noon.shutterSpeed));
      expect(night.sensitivity, greaterThan(noon.sensitivity));
    });

    test('noon is the daylight a camera is built for', () {
      final noon = DayCycle.at(12).exposure;
      expect(noon.aperture, closeTo(CameraExposure.daylight.aperture, 0.5));
      expect(noon.sensitivity, closeTo(CameraExposure.daylight.sensitivity, 5));
    });

    test('an hour past the end of the day is an hour into the next', () {
      expect(DayCycle.at(25).body, DayCycle.at(1).body);
      expect(DayCycle.at(25).power, DayCycle.at(1).power);
    });

    test('each body crosses the sky smoothly', () {
      // Walked a minute at a time through the sun's half of the day and then
      // the moon's. Within one arc there is nothing to jump over, and a body
      // that teleported would read as a light being switched on somewhere
      // else.
      for (final span in const [(6.2, 17.8), (18.2, 29.8)]) {
        var previous = DayCycle.at(span.$1);
        for (var minute = 1; minute < (span.$2 - span.$1) * 60; minute++) {
          final now = DayCycle.at(span.$1 + minute / 60);
          expect(
            (now.direction - previous.direction).length,
            lessThan(0.01),
            reason: 'jumped at ${span.$1 + minute / 60} hours',
          );
          previous = now;
        }
      }
    });

    test('the swap at the horizon happens in the dark', () {
      // The one place the direction does jump: the sun sets on one side and
      // the moon is already up on the other, which is what those two bodies
      // actually do. It is only allowed to be a jump because there is no
      // light left in it to see by — the sun has faded to nothing by the time
      // it reaches the horizon.
      for (final hour in const [6.0, 18.0]) {
        expect(DayCycle.at(hour - 0.01).power, lessThan(0.05));
        expect(DayCycle.at(hour + 0.01).power, lessThan(0.05));
      }
    });

    test('everything that can be seen changes smoothly across dawn', () {
      final before = DayCycle.at(5.99);
      final after = DayCycle.at(6.01);

      double gap(a, b) =>
          (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();

      expect(gap(before.skyColour, after.skyColour), lessThan(0.02));
      expect(
        (before.exposure.sensitivity - after.exposure.sensitivity).abs(),
        lessThan(50),
      );
      expect((before.ambient - after.ambient).abs(), lessThan(200));
    });
  });
}
