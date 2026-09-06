import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'gizmo.dart' show ViewportProjection;
import 'viewport.dart' show OrbitCamera;

/// A tool that is drawn rather than clicked.
///
/// Both of these work the same way and it is worth them looking the same:
/// click to put down points, click the first one again or press enter to
/// finish, backspace to take one back, escape to give up. What differs is
/// what the points are for.
enum ViewportTool {
  /// Nothing; clicks select as usual.
  none('', Icons.near_me_outlined),

  /// An outline on a plane, pulled up into a solid.
  polyShape('Draw shape', Icons.polyline_outlined),

  /// A path across a face, dividing it.
  cut('Cut', Icons.content_cut);

  const ViewportTool(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get isDrawing => this != ViewportTool.none;
}

/// A drawing in progress.
///
/// Held by the shell rather than by a viewport, so the same outline is drawn
/// in all four views of a scene and can be finished in a different one from
/// the one it was started in — which is the whole reason for having four.
class Drawing {
  Drawing();

  ViewportTool tool = ViewportTool.none;

  /// The points so far, in world space.
  final List<Vector3> points = [];

  /// The plane they are being drawn on, fixed by the first point.
  ///
  /// Fixed rather than recomputed, because a plane worked out afresh from
  /// each click follows whatever is under the pointer — and a point placed
  /// over a wall behind would land on the wall instead of on the floor being
  /// drawn.
  Vector3? origin;
  Vector3? normal;

  /// Which face is being cut, by its position in the mesh. Null for a shape,
  /// which is not cutting anything.
  int? face;

  /// Where the pointer is now, so the line being drawn reaches it.
  Vector3? hovering;

  bool get isEmpty => points.isEmpty;

  /// Whether there is enough to finish with.
  bool get canFinish => switch (tool) {
        ViewportTool.none => false,
        // Three points enclose something; two do not.
        ViewportTool.polyShape => points.length >= 3,
        // A cut needs two ends, and both have to be on the boundary — which
        // is checked when it runs, because until then the second one is
        // still moving.
        ViewportTool.cut => points.length >= 2,
      };

  void start(ViewportTool which) {
    clear();
    tool = which;
  }

  void clear() {
    tool = ViewportTool.none;
    points.clear();
    origin = null;
    normal = null;
    face = null;
    hovering = null;
  }

  /// Puts the plane down, once.
  void planeAt(Vector3 at, Vector3 way, {int? onFace}) {
    origin ??= at.clone();
    normal ??= way.normalized();
    face ??= onFace;
  }

  /// Where a ray meets the plane, or null before there is one.
  Vector3? placeOn(Vector3 rayOrigin, Vector3 direction) {
    final at = origin;
    final way = normal;
    if (at == null || way == null) return null;
    return PolyShape.onPlane(rayOrigin, direction, at, way);
  }

  /// Adds a point, unless it is the same one again.
  ///
  /// Somebody clicking twice in the same place means one point; without this
  /// a double-click leaves an edge of no length, which is a wall of no width
  /// that nothing can be done with afterwards.
  bool add(Vector3 at) {
    if (!isNewPoint(points, at)) return false;
    points.add(at.clone());
    return true;
  }

  /// Whether this point would close the outline rather than extend it.
  bool wouldClose(Vector3 at, {double reach = 0.15}) =>
      tool == ViewportTool.polyShape && closesOutline(points, at, reach: reach);

  void undo() {
    if (points.isNotEmpty) points.removeLast();
    if (points.isEmpty) {
      // The plane belonged to the first point, so it goes with it — the next
      // click is free to choose a different surface.
      origin = null;
      normal = null;
      face = null;
    }
  }

  /// What the shape being drawn would be, for showing it before it is made.
  PolyShape asShape({double height = 0}) =>
      PolyShape(points: [for (final at in points) at.clone()], height: height);
}


/// The outline being drawn, over the viewport.
///
/// In Flutter over the texture rather than as a pass in the renderer, for the
/// same reason the selection outline is: an extra pass in Filament is real
/// work, and a line projected with the same camera is honest about where the
/// point is.
class DrawingPainter extends CustomPainter {
  const DrawingPainter({required this.drawing, required this.camera});

  final Drawing drawing;
  final OrbitCamera camera;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !drawing.tool.isDrawing) return;

    final projection = ViewportProjection(camera: camera, size: size);
    Offset? at(Vector3 world) => projection.project(world);

    final placed = [
      for (final point in drawing.points) at(point),
    ];
    final reaching = drawing.hovering == null ? null : at(drawing.hovering!);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFE5893F);
    final ghost = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x88E5893F);

    for (var i = 0; i + 1 < placed.length; i++) {
      final a = placed[i];
      final b = placed[i + 1];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, line);
    }

    // The one still following the pointer, drawn lighter so it reads as not
    // yet placed.
    if (reaching != null && placed.isNotEmpty && placed.last != null) {
      canvas.drawLine(placed.last!, reaching, ghost);
      // And back to the start, so the shape somebody is about to close is
      // the shape they can see.
      if (drawing.tool == ViewportTool.polyShape &&
          placed.length >= 2 &&
          placed.first != null) {
        canvas.drawLine(reaching, placed.first!, ghost);
      }
    }

    final dot = Paint()..color = const Color(0xFFE5893F);
    final first = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFF3C08A);

    for (var i = 0; i < placed.length; i++) {
      final point = placed[i];
      if (point == null) continue;
      canvas.drawCircle(point, 3.5, dot);
      // The first one is ringed, because clicking it again is how the shape
      // is finished and nothing else says so.
      if (i == 0 && drawing.tool == ViewportTool.polyShape) {
        canvas.drawCircle(point, 6.5, first);
      }
    }

    if (reaching != null) {
      canvas.drawCircle(reaching, 2.5, Paint()..color = const Color(0x99F3C08A));
    }
  }

  @override
  bool shouldRepaint(DrawingPainter old) => true;
}
