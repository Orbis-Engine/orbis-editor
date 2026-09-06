import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/snapping.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('off, it changes nothing', () {
    final snap = Snapping(on: false);
    expect(snap.place(1.234), 1.234);
    expect(snap.turn(0.1), 0.1);
    expect(snap.placeAll(Vector3(1.1, 2.2, 3.3)).x, 1.1);
  });

  test('a position lands on the nearest line', () {
    final snap = Snapping(step: 0.25);
    expect(snap.place(0.3), closeTo(0.25, 1e-9));
    expect(snap.place(0.4), closeTo(0.5, 1e-9));
    expect(snap.place(-0.3), closeTo(-0.25, 1e-9));
    expect(snap.place(0), 0);
  });

  test('two things dragged along an axis land on the same lines', () {
    final snap = Snapping(step: 0.5);
    // The point of snapping the position rather than the movement: these two
    // start at different fractions and have to meet, not stay 0.13 apart.
    final a = Vector3(0.13, 0, 0);
    final b = Vector3(0.61, 0, 0);
    final axis = Vector3(1, 0, 0);

    final movedA = a + snap.along(a, a + Vector3(1.9, 0, 0), axis);
    final movedB = b + snap.along(b, b + Vector3(1.42, 0, 0), axis);

    expect(movedA.x % 0.5, closeTo(0, 1e-9));
    expect(movedB.x % 0.5, closeTo(0, 1e-9));
    expect(movedA.x, closeTo(movedB.x, 1e-9));
  });

  test('a movement across the axis is ignored', () {
    final snap = Snapping(step: 1);
    final from = Vector3.zero();
    // The pointer wandered up and sideways; only what is along the axis
    // counts, because that is the handle somebody grabbed.
    final moved = snap.along(from, Vector3(2.4, 9, -7), Vector3(1, 0, 0));
    expect(moved.y, 0);
    expect(moved.z, 0);
    expect(moved.x, closeTo(2, 1e-9));
  });

  test('a turn lands on a whole number of degrees', () {
    final snap = Snapping(angle: 15);
    double degrees(double radians) => radians * 180 / math.pi;
    expect(degrees(snap.turn(20 * math.pi / 180)), closeTo(15, 1e-9));
    expect(degrees(snap.turn(23 * math.pi / 180)), closeTo(30, 1e-9));
    expect(degrees(snap.turn(-8 * math.pi / 180)), closeTo(-15, 1e-9));
  });

  test('the steps double, so a shape made at one lines up at the next', () {
    for (var i = 1; i < Snapping.steps.length; i++) {
      final bigger = Snapping.steps[i];
      final smaller = Snapping.steps[i - 1];
      expect(bigger, greaterThan(smaller));
      // Every coarser step is a whole number of finer ones, which is what
      // makes changing the grid mid-build safe.
      expect((bigger / smaller) % 1, closeTo(0, 1e-9),
          reason: '$bigger over $smaller');
    }
  });

  test('cycling stops at the ends rather than wrapping round', () {
    final snap = Snapping(step: Snapping.steps.last);
    expect(snap.coarser, Snapping.steps.last, reason: 'no coarser than this');
    snap.step = Snapping.steps.first;
    expect(snap.finer, Snapping.steps.first);
    snap.step = 0.1;
    expect(snap.coarser, 0.5);
    expect(snap.finer, 0.05);
  });

  test('a step nobody offered still cycles somewhere sensible', () {
    final snap = Snapping(step: 0.37);
    expect(Snapping.steps.contains(snap.coarser), isTrue);
    expect(Snapping.steps.contains(snap.finer), isTrue);
  });
}
