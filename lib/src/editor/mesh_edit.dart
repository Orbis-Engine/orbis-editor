import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'gizmo.dart';
import 'viewport.dart' show OrbitCamera;

/// What the editor is pointed at.
///
/// Two contexts rather than four peer modes, which is how ProBuilder has it
/// and is right: moving a whole object and moving one of its corners are
/// different jobs with different handles, and the escape key between them is
/// the one thing somebody presses without thinking.
enum EditContext {
  /// The whole object: move it, rotate it, scale it, put it somewhere.
  object('Object'),

  /// Its parts.
  element('Edit');

  const EditContext(this.label);

  final String label;
}

/// Which part of a mesh is being selected.
enum ElementMode {
  vertex('Vertices', Icons.grain),
  edge('Edges', Icons.timeline),
  face('Faces', Icons.crop_square);

  const ElementMode(this.label, this.icon);

  final String label;
  final IconData icon;

  /// The next one round, for the key that cycles them.
  ElementMode get next => values[(index + 1) % values.length];
}

/// How a click changes what is selected.
enum SelectHow {
  /// Replace what was there.
  replace,

  /// Add to it, or take away what is already in it.
  toggle,
}

/// What is selected inside one mesh.
///
/// Indices and edges rather than objects, because faces are objects and a
/// selection that held them would be a selection that went stale the moment
/// somebody extruded — every operation here makes new faces and drops old
/// ones. Positions in the list survive that; a face that has gone is a number
/// that no longer resolves, which is checked rather than crashed on.
class ElementSelection {
  ElementSelection({
    Set<int>? vertices,
    Set<MeshEdge>? edges,
    Set<int>? faces,
  })  : vertices = vertices ?? {},
        edges = edges ?? {},
        faces = faces ?? {};

  final Set<int> vertices;
  final Set<MeshEdge> edges;

  /// Faces by position in the mesh's list.
  final Set<int> faces;

  bool get isEmpty => vertices.isEmpty && edges.isEmpty && faces.isEmpty;

  int countIn(ElementMode mode) => switch (mode) {
        ElementMode.vertex => vertices.length,
        ElementMode.edge => edges.length,
        ElementMode.face => faces.length,
      };

  void clear() {
    vertices.clear();
    edges.clear();
    faces.clear();
  }

  /// The faces themselves, skipping any the mesh no longer has.
  List<Face> facesIn(Mesh mesh) => [
        for (final at in faces)
          if (at >= 0 && at < mesh.faces.length) mesh.faces[at],
      ];

  /// Everything the selection touches, whatever mode made it — which is what
  /// a transform handle needs.
  Set<int> pointsIn(Mesh mesh) => {
        ...vertices.where((i) => i >= 0 && i < mesh.positions.length),
        for (final edge in edges) ...[edge.$1, edge.$2],
        for (final face in facesIn(mesh)) ...face.vertices,
      };

  /// Where the handles should sit.
  Vector3? pivotIn(Mesh mesh) {
    final points = pointsIn(mesh);
    if (points.isEmpty) return null;

    final sum = Vector3.zero();
    for (final index in points) {
      if (index < 0 || index >= mesh.positions.length) continue;
      sum.add(mesh.positions[index]);
    }
    return sum..scale(1 / points.length);
  }

  /// An empty one that cannot be changed. See [nothingSelected].
  const ElementSelection.none()
      : vertices = const {},
        edges = const {},
        faces = const {};

  ElementSelection copy() => ElementSelection(
        vertices: {...vertices},
        edges: {...edges},
        faces: {...faces},
      );
}

/// Nothing selected, as a constant.
///
/// So a viewport that is not editing anything does not each allocate a set to
/// hold nothing, and so the default is one shared object rather than four.
const ElementSelection nothingSelected = ElementSelection.none();

/// Finding what a click landed on.
///
/// Faces are found by casting a ray, because a face is a surface and that is
/// what a surface answers to. Vertices and edges are found in screen space,
/// because they have no area: a ray through a corner of a box misses it, and
/// what somebody means by clicking near one is "that one, the nearest".
class MeshPicker {
  const MeshPicker({
    required this.mesh,
    required this.transform,
    required this.projection,
    this.seeThrough = false,
  });

  final Mesh mesh;

  /// Where the object is in the world.
  final Matrix4 transform;

  final ViewportProjection projection;

  /// Whether what is behind the surface can be selected too.
  ///
  /// Off, a click or a marquee takes only what somebody can actually see,
  /// which is nearly always what they meant. On, it takes the far side of the
  /// shape as well — which is exactly what is wanted for scaling a whole ring
  /// of a cylinder, and never what is wanted for anything else.
  final bool seeThrough;

  /// How near a click has to be, in pixels.
  static const double _reach = 12;

  /// Whether a point on the mesh can be seen from where the camera is.
  ///
  /// A ray from the eye to the point: anything the mesh puts in the way first
  /// hides it. The margin matters — a corner lies exactly on the faces that
  /// meet there, and without it every vertex hides itself.
  bool visible(Vector3 world) {
    if (seeThrough) return true;

    final eye = projection.eye;
    final away = world - eye;
    final reach = away.length;
    if (reach < 1e-6) return true;
    final direction = away / reach;

    for (final face in mesh.faces) {
      if (face.vertices.length < 3) continue;
      final points = [
        for (final index in face.vertices)
          if (index >= 0 && index < mesh.positions.length) _worldOf(index),
      ];
      if (points.length < 3) continue;

      for (var i = 1; i + 1 < points.length; i++) {
        final hit = _rayHitsTriangle(
          eye,
          direction,
          points.first,
          points[i],
          points[i + 1],
        );
        if (hit != null && hit < reach - 1e-3) return false;
      }
    }
    return true;
  }

  Vector3 _worldOf(int index) =>
      transform.transformed3(mesh.positions[index]);

  /// The face under a pixel, or null.
  int? faceAt(Offset pixel) {
    final ray = projection.rayThrough(pixel);

    var nearest = double.infinity;
    int? found;

    for (var at = 0; at < mesh.faces.length; at++) {
      final face = mesh.faces[at];
      if (face.vertices.length < 3) continue;

      final points = [
        for (final index in face.vertices)
          if (index >= 0 && index < mesh.positions.length) _worldOf(index),
      ];
      if (points.length < 3) continue;

      // A fan from the first corner, the same way it is triangulated for
      // drawing — so what is clicked is what is on screen.
      for (var i = 1; i + 1 < points.length; i++) {
        final hit = _rayHitsTriangle(
          ray.origin,
          ray.direction,
          points.first,
          points[i],
          points[i + 1],
        );
        if (hit == null || hit >= nearest) continue;
        nearest = hit;
        found = at;
      }
    }
    return found;
  }

  /// The vertex nearest a pixel, within reach.
  int? vertexAt(Offset pixel) {
    var nearest = _reach;
    int? found;

    for (var index = 0; index < mesh.positions.length; index++) {
      final world = _worldOf(index);
      final at = projection.project(world);
      if (at == null) continue;
      final away = (at - pixel).distance;
      if (away >= nearest) continue;
      if (!visible(world)) continue;
      nearest = away;
      found = index;
    }
    return found;
  }

  /// Every vertex inside a box on screen.
  List<int> verticesIn(Rect box) {
    final found = <int>[];
    for (var index = 0; index < mesh.positions.length; index++) {
      final world = _worldOf(index);
      final at = projection.project(world);
      if (at == null || !box.contains(at)) continue;
      if (!visible(world)) continue;
      found.add(index);
    }
    return found;
  }

  /// Every edge inside a box, whole.
  ///
  /// Both ends in, not either: a marquee that took every edge it clipped
  /// would take half the shape behind whatever was being framed, and
  /// "everything I drew round" is what somebody means.
  List<MeshEdge> edgesIn(Rect box) {
    final found = <MeshEdge>[];
    for (final edge in mesh.allEdges) {
      final a = _worldOf(edge.$1);
      final b = _worldOf(edge.$2);
      final pa = projection.project(a);
      final pb = projection.project(b);
      if (pa == null || pb == null) continue;
      if (!box.contains(pa) || !box.contains(pb)) continue;
      if (!visible(a) && !visible(b)) continue;
      found.add(edge);
    }
    return found;
  }

  /// Every face whose middle is inside a box.
  ///
  /// The middle rather than every corner, so a face bigger than the box is
  /// still caught by drawing over the part of it somebody can see. A face
  /// only partly inside is not: the middle decides, which is one rule rather
  /// than an argument about how much counts.
  List<int> facesIn(Rect box) {
    final found = <int>[];
    for (var index = 0; index < mesh.faces.length; index++) {
      final face = mesh.faces[index];
      if (face.vertices.length < 3) continue;
      final middle = transform.transformed3(mesh.centreOf(face));
      final at = projection.project(middle);
      if (at == null || !box.contains(at)) continue;
      if (!visible(middle)) continue;
      found.add(index);
    }
    return found;
  }

  /// The edge nearest a pixel, within reach.
  MeshEdge? edgeAt(Offset pixel) {
    var nearest = _reach;
    MeshEdge? found;

    for (final edge in mesh.allEdges) {
      final a = projection.project(_worldOf(edge.$1));
      final b = projection.project(_worldOf(edge.$2));
      if (a == null || b == null) continue;

      final away = _pixelToSegment(pixel, a, b);
      if (away >= nearest) continue;
      // Either end being visible is enough: an edge running away from the
      // camera can have its far corner behind the shape and still be an edge
      // somebody is looking straight at.
      if (!visible(_worldOf(edge.$1)) && !visible(_worldOf(edge.$2))) continue;
      nearest = away;
      found = edge;
    }
    return found;
  }

  /// How far a point is from a line between two others.
  static double _pixelToSegment(Offset at, Offset a, Offset b) {
    final along = b - a;
    final length2 = along.dx * along.dx + along.dy * along.dy;
    if (length2 < 1e-9) return (at - a).distance;

    final t = (((at - a).dx * along.dx + (at - a).dy * along.dy) / length2)
        .clamp(0.0, 1.0);
    return (at - (a + along * t)).distance;
  }

  /// Where a ray meets a triangle, or null.
  ///
  /// Möller–Trumbore. Both sides count as a hit: clicking the far wall of a
  /// room from inside it should select the far wall, and a back-face cull here
  /// would mean nothing was selectable from inside anything.
  static double? _rayHitsTriangle(
    Vector3 origin,
    Vector3 direction,
    Vector3 a,
    Vector3 b,
    Vector3 c,
  ) {
    final edge1 = b - a;
    final edge2 = c - a;
    final h = direction.cross(edge2);
    final det = edge1.dot(h);
    if (det.abs() < 1e-12) return null;

    final f = 1 / det;
    final s = origin - a;
    final u = f * s.dot(h);
    if (u < 0 || u > 1) return null;

    final q = s.cross(edge1);
    final v = f * direction.dot(q);
    if (v < 0 || u + v > 1) return null;

    final t = f * edge2.dot(q);
    return t > 1e-6 ? t : null;
  }
}

/// Drawing the parts of a mesh over the viewport.
///
/// Only while somebody is editing one. A wireframe over every object all the
/// time is a scene nobody can see, and this is drawn in Flutter over the
/// texture rather than as a pass in the renderer for the same reason the
/// selection outline is: an extra pass in Filament is real work, and a line
/// projected with the same camera is honest about where the edge is.
class ElementPainter extends CustomPainter {
  const ElementPainter({
    required this.mesh,
    required this.transform,
    required this.camera,
    required this.mode,
    required this.selection,
    this.hovered,
  });

  final Mesh mesh;
  final Matrix4 transform;
  final OrbitCamera camera;
  final ElementMode mode;
  final ElementSelection selection;

  /// What the pointer is over: an index, or an edge.
  final Object? hovered;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || mesh.isEmpty) return;

    final projection = ViewportProjection(camera: camera, size: size);
    Offset? at(int index) => index < 0 || index >= mesh.positions.length
        ? null
        : projection.project(transform.transformed3(mesh.positions[index]));

    final wire = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x66FFFFFF);

    // Every edge, faintly, so the shape of the geometry is readable even
    // where nothing is selected.
    for (final edge in mesh.allEdges) {
      final a = at(edge.$1);
      final b = at(edge.$2);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, wire);
    }

    switch (mode) {
      case ElementMode.face:
        _paintFaces(canvas, at);
      case ElementMode.edge:
        _paintEdges(canvas, at);
      case ElementMode.vertex:
        _paintVertices(canvas, at);
    }
  }

  void _paintFaces(Canvas canvas, Offset? Function(int) at) {
    final fill = Paint()..color = const Color(0x55E5893F);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFE5893F);

    for (var index = 0; index < mesh.faces.length; index++) {
      final chosen = selection.faces.contains(index);
      final under = hovered == index;
      if (!chosen && !under) continue;

      final path = Path();
      var started = false;
      for (final corner in mesh.faces[index].vertices) {
        final point = at(corner);
        if (point == null) continue;
        started ? path.lineTo(point.dx, point.dy) : path.moveTo(point.dx, point.dy);
        started = true;
      }
      if (!started) continue;
      path.close();

      canvas.drawPath(
        path,
        chosen ? fill : (Paint()..color = const Color(0x22E5893F)),
      );
      if (chosen) canvas.drawPath(path, edge);
    }
  }

  void _paintEdges(Canvas canvas, Offset? Function(int) at) {
    final chosen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFE5893F);
    final under = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x99E5893F);

    for (final edge in mesh.allEdges) {
      final isChosen = selection.edges.contains(edge);
      final isUnder = hovered == edge;
      if (!isChosen && !isUnder) continue;

      final a = at(edge.$1);
      final b = at(edge.$2);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, isChosen ? chosen : under);
    }
  }

  void _paintVertices(Canvas canvas, Offset? Function(int) at) {
    final plain = Paint()..color = const Color(0xCCD8DEE8);
    final chosen = Paint()..color = const Color(0xFFE5893F);

    for (var index = 0; index < mesh.positions.length; index++) {
      final point = at(index);
      if (point == null) continue;

      final isChosen = selection.vertices.contains(index);
      final isUnder = hovered == index;
      canvas.drawCircle(
        point,
        isChosen || isUnder ? 4.5 : 3,
        isChosen ? chosen : plain,
      );
    }
  }

  @override
  bool shouldRepaint(ElementPainter old) => true;
}

/// How far apart two directions are, for the tools that care.
double angleBetweenVectors(Vector3 a, Vector3 b) =>
    math.acos(a.normalized().dot(b.normalized()).clamp(-1.0, 1.0));
