import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'viewport.dart';

/// What a drag on the gizmo does.
enum GizmoMode {
  move('Move', Icons.open_with),
  rotate('Rotate', Icons.threesixty);

  const GizmoMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Which of the three the pointer has hold of.
enum GizmoAxis {
  x(Color(0xFFE2564B)),
  y(Color(0xFF6FBF73)),
  z(Color(0xFF4C8FD6));

  const GizmoAxis(this.colour);

  /// Red, green, blue for x, y, z. Not a house style — it is the convention
  /// every tool with three axes in it has used for decades, and an editor that
  /// picks its own colours makes somebody re-learn the one thing they already
  /// knew.
  final Color colour;

  Vector3 get direction => switch (this) {
        GizmoAxis.x => Vector3(1, 0, 0),
        GizmoAxis.y => Vector3(0, 1, 0),
        GizmoAxis.z => Vector3(0, 0, 1),
      };
}

/// A ray into the scene, from the eye through a pixel.
class ViewRay {
  const ViewRay(this.origin, this.direction);

  final Vector3 origin;
  final Vector3 direction;

  /// Where this ray meets a plane, or null if it runs alongside it.
  Vector3? meets({required Vector3 point, required Vector3 normal}) {
    final slope = normal.dot(direction);
    // Nearly parallel: the intersection is either nowhere or so far away that
    // using it would throw the object to the horizon.
    if (slope.abs() < 1e-6) return null;
    final t = normal.dot(point - origin) / slope;
    if (t <= 0) return null;
    return origin + direction * t;
  }
}

/// The camera as the viewport's pixels see it.
///
/// The same view and projection the renderer is given, so what is drawn over
/// the texture lands exactly on what is drawn in it. Two nearly-identical
/// cameras is how an overlay ends up half a pixel out at one zoom and a
/// centimetre out at another.
class ViewportProjection {
  ViewportProjection({required OrbitCamera camera, required this.size})
      : eye = camera.toRenderCamera().position {
    final view = camera.toRenderCamera();
    _viewProjection = makePerspectiveMatrix(
      radians(view.fieldOfView),
      size.width / math.max(size.height, 1),
      0.1,
      1000,
    ).multiplied(makeViewMatrix(view.position, view.target, Vector3(0, 1, 0)));
    _inverse = Matrix4.inverted(_viewProjection);
    _forward = (view.target - view.position)..normalize();
  }

  final Size size;
  final Vector3 eye;

  late final Matrix4 _viewProjection;
  late final Matrix4 _inverse;
  late final Vector3 _forward;

  /// Which way the camera is looking.
  Vector3 get forward => _forward;

  /// Where a world point lands on screen, or null when it is behind the eye.
  Offset? project(Vector3 world) {
    final clip = _viewProjection.transform(Vector4(world.x, world.y, world.z, 1));
    // Behind the camera the perspective divide flips the point to the far side
    // of the screen, which would draw the gizmo where the object is not.
    if (clip.w <= 1e-6) return null;
    return Offset(
      (clip.x / clip.w * 0.5 + 0.5) * size.width,
      (1 - (clip.y / clip.w * 0.5 + 0.5)) * size.height,
    );
  }

  /// The ray from the eye through one pixel.
  ViewRay rayThrough(Offset pixel) {
    final ndc = Vector4(
      pixel.dx / size.width * 2 - 1,
      1 - pixel.dy / size.height * 2,
      -1,
      1,
    );
    final near = _inverse.transformed(ndc);
    final point = Vector3(near.x, near.y, near.z) / near.w;
    return ViewRay(eye.clone(), (point - eye)..normalize());
  }

  /// How long a world-space handle has to be to look the same size on screen
  /// wherever the camera is.
  ///
  /// A gizmo that shrinks with distance is one you cannot grab across a large
  /// scene, and one that does not is a gizmo the size of a building when you
  /// step back from a doorknob.
  double handleLength(Vector3 pivot) =>
      math.max((pivot - eye).length * 0.16, 0.05);
}

/// The three handles, where they are, and what dragging one does.
///
/// Held apart from the widget that draws it so the arithmetic — which axis a
/// pointer is over, how far along it a drag has gone — can be tested without a
/// window, a texture or a frame.
class Gizmo {
  Gizmo({
    required this.mode,
    required this.pivot,
    required this.projection,
  });

  final GizmoMode mode;

  /// Where the handles sit: the world position of what is selected.
  final Vector3 pivot;

  final ViewportProjection projection;

  /// How close the pointer has to be to a handle, in pixels.
  ///
  /// Generous on purpose. A handle you have to hit exactly is one that fails
  /// often enough to be worth avoiding, and the cost of a near miss is only
  /// that the view orbits instead.
  static const double grabRadius = 9;

  /// How many points a ring is drawn and measured with.
  static const int _ringSteps = 48;

  double get length => projection.handleLength(pivot);

  /// The far end of one arm.
  Vector3 endOf(GizmoAxis axis) => pivot + axis.direction * length;

  /// The ring around one axis, in world space.
  List<Vector3> ringOf(GizmoAxis axis) {
    // Two directions across the axis, so the circle lies in the plane the axis
    // turns things in.
    final normal = axis.direction;
    final across = normal.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
    final u = across.cross(normal)..normalize();
    final v = normal.cross(u)..normalize();

    return [
      for (var step = 0; step <= _ringSteps; step++)
        pivot +
            (u * math.cos(step / _ringSteps * 2 * math.pi) +
                    v * math.sin(step / _ringSteps * 2 * math.pi)) *
                length,
    ];
  }

  /// The ring as it lands on screen, with anything behind the eye left out.
  List<Offset> ringOnScreen(GizmoAxis axis) => [
        for (final point in ringOf(axis)) ?projection.project(point),
      ];

  /// Which handle is under [pixel], or null for none.
  ///
  /// Nearest wins, so where two handles cross the one whose line the pointer is
  /// actually on is the one that answers.
  GizmoAxis? axisAt(Offset pixel) {
    GizmoAxis? best;
    var nearest = grabRadius;

    for (final axis in GizmoAxis.values) {
      final distance = mode == GizmoMode.move
          ? _toSegment(pixel, axis)
          : _toRing(pixel, axis);
      if (distance == null || distance >= nearest) continue;
      nearest = distance;
      best = axis;
    }
    return best;
  }

  double? _toSegment(Offset pixel, GizmoAxis axis) {
    final from = projection.project(pivot);
    final to = projection.project(endOf(axis));
    if (from == null || to == null) return null;
    return _distanceToSegment(pixel, from, to);
  }

  double? _toRing(Offset pixel, GizmoAxis axis) {
    final points = ringOnScreen(axis);
    if (points.length < 2) return null;

    var nearest = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final distance = _distanceToSegment(pixel, points[i], points[i + 1]);
      if (distance < nearest) nearest = distance;
    }
    return nearest;
  }

  /// Where a pointer sits along one axis, in world space.
  ///
  /// Read off a plane that holds the axis and faces the camera as squarely as
  /// it can. Using the axis alone would leave the depth of the grab undefined,
  /// and the object would jump the moment the drag began.
  Vector3? pointOnAxis(Offset pixel, GizmoAxis axis) {
    final direction = axis.direction;
    final across = direction.cross(projection.forward);
    if (across.length2 < 1e-9) return null;
    final normal = across.cross(direction)..normalize();

    final hit = projection
        .rayThrough(pixel)
        .meets(point: pivot, normal: normal);
    if (hit == null) return null;

    // Only the part along the axis matters; the rest is where the pointer
    // happened to be across it.
    return pivot + direction * (hit - pivot).dot(direction);
  }

  /// Where a pointer sits on the disc an axis turns in.
  Vector3? pointOnRing(Offset pixel, GizmoAxis axis) => projection
      .rayThrough(pixel)
      .meets(point: pivot, normal: axis.direction);

  /// How far a drag has turned something, in radians, signed about the axis.
  double angleBetween(Vector3 from, Vector3 to, GizmoAxis axis) {
    final a = (from - pivot)..normalize();
    final b = (to - pivot)..normalize();
    // The sign has to come from the axis rather than from the shorter way
    // round, or a drag past a quarter turn would spring back.
    return math.atan2(a.cross(b).dot(axis.direction), a.dot(b));
  }

  static double _distanceToSegment(Offset point, Offset from, Offset to) {
    final line = to - from;
    final lengthSquared = line.dx * line.dx + line.dy * line.dy;
    if (lengthSquared < 1e-9) return (point - from).distance;

    final t = (((point.dx - from.dx) * line.dx +
                (point.dy - from.dy) * line.dy) /
            lengthSquared)
        .clamp(0.0, 1.0);
    return (point - (from + line * t)).distance;
  }
}

/// Draws the handles over the rendered image.
///
/// In Flutter rather than as a pass in the renderer, for the same reason the
/// selection box is: an overlay that needs no depth buffer, no material and no
/// second draw of the scene, and that is always on top where a handle has to
/// be to be grabbed.
class GizmoPainter extends CustomPainter {
  const GizmoPainter({
    required this.gizmo,
    required this.hovered,
    required this.dragging,
  });

  final Gizmo? gizmo;
  final GizmoAxis? hovered;
  final GizmoAxis? dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final gizmo = this.gizmo;
    if (gizmo == null || size.isEmpty) return;

    final centre = gizmo.projection.project(gizmo.pivot);
    if (centre == null) return;

    for (final axis in GizmoAxis.values) {
      final active = dragging == axis || (dragging == null && hovered == axis);
      // Dimmed while another handle is being dragged, so what is moving is
      // never in doubt.
      final colour = dragging != null && dragging != axis
          ? axis.colour.withValues(alpha: 0.25)
          : (active ? Colors.white : axis.colour);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = active ? 3.5 : 2.5
        ..color = colour;

      if (gizmo.mode == GizmoMode.move) {
        final end = gizmo.projection.project(gizmo.endOf(axis));
        if (end == null) continue;
        canvas.drawLine(centre, end, paint);
        _arrowhead(canvas, centre, end, paint);
      } else {
        final points = gizmo.ringOnScreen(axis);
        if (points.length < 2) continue;
        canvas.drawPoints(PointMode.polygon, points, paint);
      }
    }

    // A dot at the pivot, so it is clear what the handles turn around even
    // when one of them points straight at the camera and has no length.
    canvas.drawCircle(
      centre,
      3,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  void _arrowhead(Canvas canvas, Offset from, Offset to, Paint paint) {
    final line = to - from;
    final length = line.distance;
    if (length < 12) return;

    final direction = line / length;
    final across = Offset(-direction.dy, direction.dx);
    final base = to - direction * 9;

    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(base.dx + across.dx * 4, base.dy + across.dy * 4)
        ..lineTo(base.dx - across.dx * 4, base.dy - across.dy * 4)
        ..close(),
      Paint()..color = paint.color,
    );
  }

  @override
  bool shouldRepaint(GizmoPainter old) =>
      old.gizmo?.pivot != gizmo?.pivot ||
      old.gizmo?.mode != gizmo?.mode ||
      old.hovered != hovered ||
      old.dragging != dragging;
}
