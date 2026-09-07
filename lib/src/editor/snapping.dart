import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Which part of a thing is put on the line.
///
/// An object's own origin is rarely where somebody wants it measured from. A
/// plane made in the editor has its origin in the middle, so snapping it to
/// the floor leaves it half above and half below — which is exactly right for
/// a wall through a floor and exactly wrong for a floor.
enum SnapTo {
  /// The object's own origin, wherever the person who made it put it.
  pivot('Origin'),

  /// The bottom of it, along whichever way it is being dragged. What puts a
  /// floor *on* the ground rather than through it.
  base('Base'),

  /// The middle of it.
  centre('Middle'),

  /// The top of it, for hanging something from a ceiling.
  top('Top');

  const SnapTo(this.label);

  final String label;
}

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
    this.to = SnapTo.base,
  });

  /// Whether it applies at all. Held down rather than switched is the other
  /// way round — the key suspends it, because somebody who wants a shelf half
  /// a millimetre off wants it for one drag and not for the afternoon.
  bool on;

  /// How far apart the grid lines are, in metres.
  double step;

  /// How many degrees a turn lands on.
  double angle;

  /// Which part of the thing being dragged is put on the line.
  ///
  /// Its base by default. Almost everything anybody drags is something that
  /// stands on something else, and a shape whose origin is in the middle
  /// otherwise sinks half of itself into the floor the moment it snaps.
  SnapTo to;

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
  /// [anchor] is how far the part being put on the line is from the object's
  /// own origin, along the axis. Nought means the origin itself.
  Vector3 along(
    Vector3 from,
    Vector3 wanted,
    Vector3 axis, {
    double anchor = 0,
  }) {
    if (!on || step <= 0) return wanted - from;

    final direction = axis.normalized();
    final reach = (wanted - from).dot(direction);
    final start = from.dot(direction);
    // The *anchor* lands on a line, and the origin goes wherever that puts
    // it. Written from a fixed origin rather than as a distance moved, so two
    // things dragged along the same axis land on the same lines.
    final landed = place(start + reach + anchor) - anchor - start;
    return direction * landed;
  }

  /// How far the anchor is from an object's origin, along [axis], given the
  /// box the object occupies in the world.
  ///
  /// Positive means the anchor is further along the axis than the origin.
  double anchorFor(
    Vector3 axis,
    Vector3 origin,
    ({Vector3 min, Vector3 max}) box,
  ) {
    if (to == SnapTo.pivot) return 0;
    final direction = axis.normalized();
    final low = box.min.dot(direction);
    final high = box.max.dot(direction);
    // The box is axis-aligned in the world and the axis is one of the world's
    // own, so its ends along that axis are simply the two corners. Ordered,
    // because dotting a minimum with a negative axis gives the maximum.
    final from = low < high ? low : high;
    final upTo = low < high ? high : low;

    final at = switch (to) {
      SnapTo.pivot => origin.dot(direction),
      SnapTo.base => from,
      SnapTo.centre => (from + upTo) / 2,
      SnapTo.top => upTo,
    };
    return at - origin.dot(direction);
  }
}
