import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// What is lighting a scene from above.
///
/// One at a time, because a renderer draws one directional light and a sky has
/// one thing in it that everything else is lit by. A scene with a day cycle
/// switches at the horizon; a scene without one is told which.
enum CelestialBody {
  sun('Sun'),
  moon('Moon');

  const CelestialBody(this.label);

  /// What it is called, which is also what a light of this body is named while
  /// nobody has renamed it.
  final String label;
}

/// The sky at one moment: where the light comes from, what colour it is, and
/// what a camera has to do to see by it.
///
/// A record of one instant rather than a thing that ticks. The clock belongs
/// to the editor, the hour belongs to the scene, and this is the function
/// between them — which is what makes it something a test can pin down.
class SkyState {
  const SkyState({
    required this.body,
    required this.direction,
    required this.altitude,
    required this.lightColour,
    required this.power,
    required this.skyColour,
    required this.ambient,
    required this.exposure,
  });

  final CelestialBody body;

  /// The direction light travels: from the body towards the scene.
  final Vector3 direction;

  /// How high the body sits, in radians. Negative is below the horizon, which
  /// only the sun ever is — when it goes down the moon comes up.
  final double altitude;

  final Color lightColour;

  /// Watts per square metre, the unit a sun's strength is stated in.
  final double power;

  final Color skyColour;

  /// How much light the sky itself casts, in lux.
  final double ambient;

  /// What the camera has to be set to for any of this to be visible.
  final CameraExposure exposure;
}

/// A camera's three settings, which together decide how much light reaches it.
///
/// Needed because a day cycle spans about seventeen stops. Moonlight is a
/// quarter of a lux and midday is a hundred thousand: on one fixed exposure,
/// either the night is pure black or the day is pure white. Every camera and
/// every eye solves this by changing sensitivity, and so does this one.
class CameraExposure {
  const CameraExposure({
    required this.aperture,
    required this.shutterSpeed,
    required this.sensitivity,
  });

  /// Sunny sixteen: what a camera is set to outdoors at midday, and what
  /// Filament assumes when nobody says otherwise.
  static const CameraExposure daylight = CameraExposure(
    aperture: 16,
    shutterSpeed: 1 / 125,
    sensitivity: 100,
  );

  /// F-number.
  final double aperture;

  /// Seconds.
  final double shutterSpeed;

  /// ISO.
  final double sensitivity;
}

/// Where the sun and moon are through a day, and what that does to everything.
///
/// Not an ephemeris. A real one needs a date, a latitude and a longitude, and
/// it would buy a scene nothing that this does not: an arc that rises, crosses
/// and sets, with the light going warm at both ends. What matters here is that
/// it is smooth, that it repeats, and that midnight and midday are opposite.
abstract final class DayCycle {
  /// How high the sun climbs at noon. Sixty-five degrees is a summer's day at
  /// a temperate latitude — high enough for short shadows, low enough that
  /// they still point somewhere.
  static const double peakAltitude = 65 * math.pi / 180;

  /// Direct sun at noon, in watts per square metre, as the light package takes
  /// it. About seventy-five thousand lux.
  static const double noonPower = 110;

  /// Moonlight, in the same unit — about a lux.
  ///
  /// Brighter than the real thing, which is a quarter of a lux and looks like
  /// almost nothing. Every night scene ever filmed is lit well above what the
  /// moon actually gives, for the same reason: a night has to be dark and
  /// legible at once, and the real number is only the first of those.
  static const double moonPower = 0.0015;

  /// The sky at [hour], which runs from zero to twenty-four and wraps.
  static SkyState at(double hour) {
    final time = hour % 24;

    // Zero at six in the morning, pi at six in the evening, so the sun is up
    // for exactly half of it and highest at noon.
    final swing = math.sin((time - 6) / 12 * math.pi);
    final sunAltitude = swing * peakAltitude;

    // Turns once a day, so it rises on one side and sets on the other rather
    // than going back the way it came.
    final azimuth = (time / 24) * 2 * math.pi;

    final isDay = sunAltitude > 0;
    final body = isDay ? CelestialBody.sun : CelestialBody.moon;

    // The moon is opposite the sun. Not true of the real one, which is why it
    // has phases — but a moon that is up all night is the one a scene wants.
    final altitude = isDay ? sunAltitude : -sunAltitude;
    final facing = isDay ? azimuth : azimuth + math.pi;

    final toBody = Vector3(
      math.cos(altitude) * math.sin(facing),
      math.sin(altitude),
      math.cos(altitude) * math.cos(facing),
    );

    // How much of a day it is: one at noon, zero from dusk to dawn. Squared
    // off at the ends so sunrise takes a while rather than happening between
    // two frames.
    final daylight = _smooth(swing.clamp(0.0, 1.0) / 0.35);

    // Low sun is red because its light has come a long way through the air.
    // The same reason the sky is blue, seen from the other end.
    final horizon = _smooth(swing.clamp(0.0, 1.0) / 0.18);

    return SkyState(
      body: body,
      // Light travels from the body to the scene, which is the way the body
      // is not.
      direction: -toBody..normalize(),
      altitude: altitude,
      lightColour: isDay
          ? Color.lerp(_lowSun, _highSun, horizon)!
          : _moonlight,
      power: isDay
          ? noonPower * math.max(0, swing) * math.max(0, swing)
          : moonPower,
      skyColour: _skyAt(swing),
      ambient: isDay
          ? 60 + 27940 * daylight
          // Not nothing: a night sky with no ambient at all makes every
          // surface facing away from the moon pure black, and a night is not
          // a scene with holes in it.
          : 12,
      exposure: _exposureFor(daylight),
    );
  }

  /// The sky's own colour through the day.
  ///
  /// Four stops rather than a formula: night, the minute before dawn, an hour
  /// after it, and midday. A gradient between three of them looks like a
  /// filter being turned; the dawn stop is what makes it read as a sunrise.
  static Color _skyAt(double swing) {
    if (swing <= 0) {
      // Below the horizon, deepening for the first part of the night.
      return Color.lerp(_duskSky, _nightSky, _smooth(-swing / 0.25))!;
    }
    if (swing < 0.18) return Color.lerp(_duskSky, _dawnSky, swing / 0.18)!;
    return Color.lerp(_dawnSky, _daySky, _smooth((swing - 0.18) / 0.5))!;
  }

  /// What a camera has to be set to, from a night to a bright day.
  ///
  /// Interpolated the way stops are — by doubling, not by adding — so the
  /// middle of the range is the middle of what an eye would call it rather
  /// than a value that races through dusk and crawls through noon.
  static CameraExposure _exposureFor(double daylight) {
    double stops(double dark, double light) =>
        dark * math.pow(light / dark, daylight).toDouble();

    return CameraExposure(
      aperture: stops(1.4, 16),
      shutterSpeed: stops(1 / 30, 1 / 125),
      sensitivity: stops(6400, 100),
    );
  }

  /// Smoothstep, clamped. Turns a straight ramp into one that eases out of
  /// both ends, which is the difference between a sunrise and a switch.
  static double _smooth(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  static const Color _lowSun = Color(0xFFFF8A3D);
  static const Color _highSun = Color(0xFFFFF4E5);
  static const Color _moonlight = Color(0xFFC3D4FF);

  static const Color _nightSky = Color(0xFF05070F);
  static const Color _duskSky = Color(0xFF2A2438);
  static const Color _dawnSky = Color(0xFF7A5A63);
  static const Color _daySky = Color(0xFF6E96C8);
}
