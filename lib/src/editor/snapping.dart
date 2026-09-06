import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// What a drag lands on.
///
/// Blocking out a level is mostly making things line up, and lining things up
/// by eye at a hundred places is where the time goes. Everything here is one
/// idea: a drag reports where the pointer is, and this decides which of the
/// nearby round numbers that means.
class Snapping {
  Snapping({
    this.on = true,
    this.step = 0.5,
    this.angle = 15,
  });

  /// Whether it applies at all. Held down rather than switched is the other
  /// way round — the key suspends it, because somebody who wants a shelf half
  /// a millimetre off wants it for one drag and not for the afternoon.
  bool on;

  /// How far apart the grid lines are, in metres.
  double step;

  /// How many degrees a turn lands on.
  double angle;

  /// The steps offered: a millimetre up to two metres.
  ///
  /// Every one of them divides the next exactly, which is what makes changing
  /// the grid part-way through safe — everything placed on a fine grid is
  /// still on the coarse one. That property is why a quarter of a metre is
  /// not on the list: it would sit between a tenth and a half and divide
  /// neither.
  static const List<double> steps = [
    0.001,
    0.005,
    0.01,
    0.05,
    0.1,
    0.5,
    1.0,
    2.0,
  ];

  /// The next step up, wrapping, for the key that cycles them.
  double get coarser {
    final at = steps.indexOf(step);
    return at < 0 || at == steps.length - 1 ? steps.last : steps[at + 1];
  }

  double get finer {
    final at = steps.indexOf(step);
    return at <= 0 ? steps.first : steps[at - 1];
  }

  /// A distance along an axis, rounded to the grid.
  ///
  /// The *position* rather than the movement, so things land on the grid
  /// rather than a round distance from wherever they happened to start.
  /// Somebody dragging two walls together wants them to meet, and two walls
  /// each moved exactly a quarter of a metre from two different places do
  /// not.
  double place(double at) {
    if (!on || step <= 0) return at;
    return (at / step).roundToDouble() * step;
  }

  /// A whole position, each axis on the grid.
  Vector3 placeAll(Vector3 at) =>
      on ? Vector3(place(at.x), place(at.y), place(at.z)) : at;

  /// A turn, in radians, rounded to [angle] degrees.
  double turn(double radians) {
    if (!on || angle <= 0) return radians;
    final degrees = radians * 180 / math.pi;
    final landed = (degrees / angle).roundToDouble() * angle;
    return landed * math.pi / 180;
  }

  /// How much to move something so that [from] plus the move lands on the
  /// grid, given a pointer that has asked for [wanted].
  ///
  /// Written this way because a drag has two positions that matter: where the
  /// thing started, which decides what "on the grid" means for it, and where
  /// the pointer is, which decides which grid line. Snapping the difference
  /// instead would keep whatever fraction the thing started with forever.
  Vector3 along(Vector3 from, Vector3 wanted, Vector3 axis) {
    if (!on || step <= 0) return wanted - from;

    final direction = axis.normalized();
    final reach = (wanted - from).dot(direction);
    // Where it would end up along the axis, from a fixed origin — so two
    // things dragged along the same axis land on the same lines.
    final landed = place(from.dot(direction) + reach) - from.dot(direction);
    return direction * landed;
  }
}
