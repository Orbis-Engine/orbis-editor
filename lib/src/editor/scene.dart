import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// What kind of thing an object is, which decides what components it has and
/// therefore what the inspector shows.
enum ObjectKind { scene, mesh, light, camera, group }

/// One object in the edited scene.
///
/// Identified by an id rather than by name, because a rename is an ordinary
/// edit and everything that refers to an object — the selection, the undo
/// stack, a parent link — has to survive one.
class SceneObject {
  SceneObject({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    Vector3? position,
    Vector3? rotation,
    Vector3? scale,
    this.colour = const Color(0xFFD9634F),
    this.power = 1000,
    this.castShadows = true,
    this.meshAsset,
  })  : position = position ?? Vector3.zero(),
        rotation = rotation ?? Vector3.zero(),
        scale = scale ?? Vector3(1, 1, 1);

  final String id;

  String name;

  final ObjectKind kind;

  /// The object this one hangs off, or null for a root.
  String? parentId;

  /// Local to the parent, not to the world. Moving a parent carries its
  /// children, which is the whole reason a hierarchy is worth having.
  final Vector3 position;

  /// Euler angles in degrees, XYZ order — the units the inspector shows, kept
  /// as the source of truth so a value typed in comes back out unchanged
  /// instead of round-tripping through a quaternion and drifting.
  final Vector3 rotation;

  final Vector3 scale;

  Color colour;

  /// Light power in watts. Ignored by anything that is not a light.
  double power;

  bool castShadows;

  /// The mesh this object draws, as a path relative to the project.
  ///
  /// Null means the built-in cube. A referenced mesh is *still* drawn as a
  /// cube for now — the reference is recorded and shown, and the renderer
  /// honours it once glTF loading exists. Naming it here rather than pretending
  /// to load it keeps the file honest about what the scene says.
  String? meshAsset;

  IconData get icon => switch (kind) {
        ObjectKind.scene => Icons.public,
        ObjectKind.group => Icons.folder_outlined,
        ObjectKind.mesh => Icons.view_in_ar_outlined,
        ObjectKind.light => Icons.wb_sunny_outlined,
        ObjectKind.camera => Icons.videocam_outlined,
      };

  /// Whether this object is drawn.
  bool get isDrawable => kind == ObjectKind.mesh;

  /// Where the object sits relative to its parent.
  Matrix4 get localTransform => Matrix4.identity()
    ..setTranslation(position)
    ..multiply(rotationFromDegrees(rotation))
    ..multiply(Matrix4.diagonal3(scale));

  /// A copy with a new identity, for pasting.
  SceneObject copyAs({required String id, String? parentId}) => SceneObject(
        id: id,
        name: name,
        kind: kind,
        parentId: parentId,
        position: position.clone(),
        rotation: rotation.clone(),
        scale: scale.clone(),
        colour: colour,
        power: power,
        castShadows: castShadows,
        meshAsset: meshAsset,
      );

  SceneObject copy() => SceneObject(
        id: id,
        name: name,
        kind: kind,
        parentId: parentId,
        position: position.clone(),
        rotation: rotation.clone(),
        scale: scale.clone(),
        colour: colour,
        power: power,
        castShadows: castShadows,
        meshAsset: meshAsset,
      );
}

/// A rotation from XYZ degrees, applied X then Y then Z.
///
/// Built from three explicit axis rotations rather than from a library's Euler
/// constructor. vector_math's takes its three angles in an order that does not
/// match its argument names, so a rotation built with it and read back with
/// the obvious inverse comes out with the axes permuted — silently, and only
/// visible once something is animated. Owning both directions makes the
/// convention checkable, and [eulerDegreesOf] is its exact inverse.
Matrix4 rotationFromDegrees(Vector3 degreesXyz) =>
    Matrix4.rotationZ(radians(degreesXyz.z))
      ..multiply(Matrix4.rotationY(radians(degreesXyz.y)))
      ..multiply(Matrix4.rotationX(radians(degreesXyz.x)));

/// A transform's rotation, back into the XYZ degrees the inspector shows.
///
/// Scale is divided out first. Reading the angles straight off the upper 3x3
/// works only while the scale is one, and gives quietly wrong angles the
/// moment somebody resizes the object.
Vector3 eulerDegreesOf(Matrix4 transform) {
  final m = transform.getRotation();

  // A column's length is that axis's scale, because the rotation part is
  // orthonormal before scaling.
  double column(int index) => Vector3(
        m.entry(0, index),
        m.entry(1, index),
        m.entry(2, index),
      ).length;

  final scales = [column(0), column(1), column(2)];
  double r(int row, int col) {
    final scale = scales[col];
    // A zero-scaled axis carries no direction; treating it as unscaled keeps
    // the matrix well-formed rather than filling it with infinities.
    return scale < 1e-12 ? (row == col ? 1.0 : 0.0) : m.entry(row, col) / scale;
  }

  // The inverse of Rz * Ry * Rx. Clamped before asin: a value a hair outside
  // [-1, 1] from rounding returns NaN, and a NaN in a transform makes the
  // object vanish with nothing to say why.
  final sinPitch = (-r(2, 0)).clamp(-1.0, 1.0);
  final y = math.asin(sinPitch);

  final double x, z;
  if (sinPitch.abs() < 0.9999) {
    x = math.atan2(r(2, 1), r(2, 2));
    z = math.atan2(r(1, 0), r(0, 0));
  } else {
    // Gimbal lock: the object points straight up or down, so two of the three
    // angles turn about the same axis and only their sum survives. It all goes
    // into one of them.
    x = math.atan2(-r(0, 1), r(1, 1));
    z = 0;
  }

  return Vector3(degrees(x), degrees(y), degrees(z));
}

/// Something an edit could not do, worth saying out loud.
class SceneError extends StateError {
  SceneError(super.message);
}

/// The scene being edited.
///
/// A flat list plus a parent link rather than nested children: reparenting is
/// then one field, ordering survives it, and there is no second copy of the
/// tree to keep in step with the first.
class EditorScene {
  EditorScene(
    List<SceneObject> objects, {
    this.name = 'Scene',
    Color? skyColour,
    this.ambient = 28000,
  })  : _objects = objects,
        skyColour = skyColour ?? const Color(0xFF1A2029) {
    for (final object in objects) {
      if (_byId.containsKey(object.id)) {
        throw SceneError('Two objects share the id "${object.id}".');
      }
      _byId[object.id] = object;
    }
  }

  /// Where an object sits among its siblings, for reordering.
  int indexOf(String id) {
    final object = _byId[id];
    if (object == null) return -1;
    return siblingsOf(object.parentId).indexWhere((o) => o.id == id);
  }

  /// The objects sharing a parent, in the order they are drawn in the tree.
  List<SceneObject> siblingsOf(String? parentId) =>
      [for (final o in _objects) if (o.parentId == parentId) o];

  /// Moves an object to a new parent at a given position among its siblings.
  ///
  /// Order is the list's own order rather than a number on each object: an
  /// index stored per object has to be renumbered on every move, and the
  /// renumbering is what goes wrong.
  void moveTo(String id, {String? parentId, required int index}) {
    final object = _byId[id];
    if (object == null) return;

    if (parentId != null) {
      if (parentId == id || isAncestorOf(id, parentId)) {
        throw SceneError(
          'Cannot put "${object.name}" inside itself or its own children.',
        );
      }
      if (!_byId.containsKey(parentId)) return;
    }

    _objects.remove(object);
    object.parentId = parentId;

    // Placed relative to its new siblings rather than at an absolute position
    // in the flat list, which is what makes the tree read in the right order.
    final siblings = siblingsOf(parentId);
    final at = index.clamp(0, siblings.length);
    if (at >= siblings.length) {
      // After the last sibling and everything nested under it, so it does not
      // land in the middle of somebody else's children.
      final last = siblings.isEmpty ? null : siblings.last;
      final tail = last == null
          ? null
          : (descendantsOf(last.id).isEmpty ? last : descendantsOf(last.id).last);
      final anchor = tail == null ? -1 : _objects.indexOf(tail);
      _objects.insert(anchor + 1, object);
    } else {
      _objects.insert(_objects.indexOf(siblings[at]), object);
    }

    invalidate();
  }

  /// A default scene, so a new project opens on something rather than nothing.
  ///
  /// The ground is a flattened box rather than a plane because the renderer
  /// draws boxes and nothing else yet; when meshes load it becomes a mesh.
  factory EditorScene.starter() => EditorScene([
        SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light,
            rotation: Vector3(-55, 35, 0),
            colour: const Color(0xFFFFF3E0), power: 1400),
        SceneObject(id: 'ground', name: 'Ground', kind: ObjectKind.mesh,
            position: Vector3(0, -1.05, 0), scale: Vector3(8, 0.05, 8),
            colour: const Color(0xFF3B424C)),
        SceneObject(id: 'props', name: 'Props', kind: ObjectKind.group),
        SceneObject(id: 'cube', name: 'Cube', kind: ObjectKind.mesh,
            parentId: 'props', rotation: Vector3(0, 25, 0),
            colour: const Color(0xFFD9634F)),
        SceneObject(id: 'crate', name: 'Crate', kind: ObjectKind.mesh,
            parentId: 'props', position: Vector3(2.2, -0.65, 0.6),
            scale: Vector3(0.7, 0.7, 0.7),
            colour: const Color(0xFFE5B84F)),
        SceneObject(id: 'camera', name: 'Camera', kind: ObjectKind.camera,
            position: Vector3(6, 4, 8), rotation: Vector3(-20, 35, 0)),
      ]);

  /// What the scene is called, which need not match its file name.
  String name;

  /// The sky, and by the same setting the light it casts.
  ///
  /// One property rather than two, because a backdrop that lights nothing
  /// reads as a photograph behind the scene rather than the sky it stands
  /// under.
  Color skyColour;

  /// How much light the sky casts, in lux.
  double ambient;

  final List<SceneObject> _objects;
  final Map<String, SceneObject> _byId = {};

  /// Bumped by every structural change, so derived work can tell whether the
  /// answer it cached is still the answer.
  int _generation = 0;
  int _cachedGeneration = -1;
  final Map<String, Matrix4> _worldCache = {};

  List<SceneObject> get objects => List.unmodifiable(_objects);

  int get length => _objects.length;

  SceneObject? operator [](String id) => _byId[id];

  bool contains(String id) => _byId.containsKey(id);

  /// Call after mutating an object, so cached world matrices are recomputed.
  void invalidate() => _generation++;

  /// Objects with no parent, in order.
  List<SceneObject> get roots =>
      [for (final o in _objects) if (o.parentId == null) o];

  List<SceneObject> childrenOf(String id) =>
      [for (final o in _objects) if (o.parentId == id) o];

  /// Every object under [id], deepest last.
  List<SceneObject> descendantsOf(String id) {
    final found = <SceneObject>[];
    void walk(String parent) {
      for (final child in childrenOf(parent)) {
        found.add(child);
        walk(child.id);
      }
    }

    walk(id);
    return found;
  }

  /// How deep an object sits, for indenting.
  int depthOf(String id) {
    var depth = 0;
    var current = _byId[id]?.parentId;
    // Bounded rather than trusted: a cycle here would hang the outliner while
    // it drew, which is the worst place to discover one.
    while (current != null && depth < _maxDepth) {
      depth++;
      current = _byId[current]?.parentId;
    }
    return depth;
  }

  static const _maxDepth = 256;

  /// Whether [ancestor] is above [id] in the tree.
  ///
  /// The check that stops somebody dragging a parent onto its own child, which
  /// would detach the whole branch from the scene and leave it unreachable.
  bool isAncestorOf(String ancestor, String id) {
    var current = _byId[id]?.parentId;
    var steps = 0;
    while (current != null && steps < _maxDepth) {
      if (current == ancestor) return true;
      current = _byId[current]?.parentId;
      steps++;
    }
    return false;
  }

  /// Where an object ends up, with every parent applied.
  Matrix4 worldOf(String id) {
    if (_cachedGeneration != _generation) {
      _worldCache.clear();
      _cachedGeneration = _generation;
    }

    final cached = _worldCache[id];
    if (cached != null) return cached;

    final object = _byId[id];
    if (object == null) return Matrix4.identity();

    final parentId = object.parentId;
    final world = parentId == null || !_byId.containsKey(parentId)
        ? object.localTransform
        : worldOf(parentId).multiplied(object.localTransform);

    return _worldCache[id] = world;
  }

  // ---- structural edits, called by commands rather than by widgets ----

  void add(SceneObject object, {int? at}) {
    if (_byId.containsKey(object.id)) {
      throw SceneError('There is already an object with id "${object.id}".');
    }
    _byId[object.id] = object;
    _objects.insert(at ?? _objects.length, object);
    invalidate();
  }

  /// Removes an object and everything under it, and says where it was.
  ///
  /// Returns the removed objects with their positions so an undo can put them
  /// back exactly, rather than appending them to the end where they would
  /// silently reorder the outliner.
  List<({SceneObject object, int index})> remove(String id) {
    final object = _byId[id];
    if (object == null) return const [];

    final going = [object, ...descendantsOf(id)];
    final removed = <({SceneObject object, int index})>[];
    for (final gone in going) {
      final index = _objects.indexOf(gone);
      if (index < 0) continue;
      removed.add((object: gone, index: index));
    }
    // Highest index first, so each removal leaves the earlier indices valid.
    removed.sort((a, b) => b.index.compareTo(a.index));
    for (final entry in removed) {
      _objects.removeAt(entry.index);
      _byId.remove(entry.object.id);
    }

    invalidate();
    // Back into insertion order, which is the order an undo has to replay.
    return removed.reversed.toList();
  }

  void restore(List<({SceneObject object, int index})> entries) {
    for (final entry in entries) {
      _byId[entry.object.id] = entry.object;
      _objects.insert(math.min(entry.index, _objects.length), entry.object);
    }
    invalidate();
  }

  void reparent(String id, String? parentId) {
    final object = _byId[id];
    if (object == null) return;
    if (parentId != null) {
      if (parentId == id || isAncestorOf(id, parentId)) {
        throw SceneError(
          'Cannot put "${object.name}" inside itself or its own children.',
        );
      }
      if (!_byId.containsKey(parentId)) return;
    }
    object.parentId = parentId;
    invalidate();
  }

  /// Roughly where an object sits and how big it is, with its children.
  ///
  /// Built from the unit cube the renderer draws for everything, so it is only
  /// as accurate as the geometry is — which is exact today and becomes an
  /// approximation the moment real meshes load. Good enough to frame by, which
  /// is all it is for.
  ({Vector3 centre, double radius}) boundsOf(String id) {
    final objects = [
      if (this[id] != null) this[id]!,
      ...descendantsOf(id),
    ].where((o) => o.isDrawable).toList();

    // A group of nothing, or a light: frame its own position rather than
    // refusing, so F always does something.
    if (objects.isEmpty) {
      final lone = this[id];
      return (
        centre: lone == null
            ? Vector3.zero()
            : worldOf(lone.id).getTranslation(),
        radius: 1,
      );
    }

    var minimum = Vector3.all(double.infinity);
    var maximum = Vector3.all(double.negativeInfinity);

    for (final object in objects) {
      final world = worldOf(object.id);
      for (final x in const [-1.0, 1.0]) {
        for (final y in const [-1.0, 1.0]) {
          for (final z in const [-1.0, 1.0]) {
            final corner = world.transformed3(Vector3(x, y, z));
            minimum = Vector3(
              math.min(minimum.x, corner.x),
              math.min(minimum.y, corner.y),
              math.min(minimum.z, corner.z),
            );
            maximum = Vector3(
              math.max(maximum.x, corner.x),
              math.max(maximum.y, corner.y),
              math.max(maximum.z, corner.z),
            );
          }
        }
      }
    }

    final centre = (minimum + maximum)..scale(0.5);
    // Floored, so framing something flat — a ground plane — does not put the
    // camera inside it.
    final radius = math.max((maximum - minimum).length / 2, 0.5);
    return (centre: centre, radius: radius);
  }

  /// What the whole scene occupies, for framing with nothing selected.
  ({Vector3 centre, double radius}) boundsOfEverything() {
    final roots = this.roots;
    if (roots.isEmpty) return (centre: Vector3.zero(), radius: 4);

    var minimum = Vector3.all(double.infinity);
    var maximum = Vector3.all(double.negativeInfinity);
    for (final root in roots) {
      final bounds = boundsOf(root.id);
      final low = bounds.centre - Vector3.all(bounds.radius);
      final high = bounds.centre + Vector3.all(bounds.radius);
      minimum = Vector3(
        math.min(minimum.x, low.x),
        math.min(minimum.y, low.y),
        math.min(minimum.z, low.z),
      );
      maximum = Vector3(
        math.max(maximum.x, high.x),
        math.max(maximum.y, high.y),
        math.max(maximum.z, high.z),
      );
    }

    return (
      centre: (minimum + maximum)..scale(0.5),
      radius: math.max((maximum - minimum).length / 2, 1),
    );
  }

  /// Everything the renderer draws, viewed from [camera].
  ///
  /// The viewport's camera is passed in rather than taken from the scene's
  /// Camera object: the scene view and the game camera are separate things,
  /// and moving one should not move the other.
  ///
  /// [projectRoot] resolves mesh references, which are stored relative to the
  /// project so a scene file survives the folder being moved or shared, and
  /// have to be absolute by the time the renderer opens them.
  OrbisScene toRenderScene(OrbisCamera camera, {String? projectRoot}) {
    final light = _objects.cast<SceneObject?>().firstWhere(
          (o) => o!.kind == ObjectKind.light,
          orElse: () => null,
        );

    // The sun's direction comes from its world matrix, so a sun parented to a
    // rig turns with it.
    final direction = light == null
        ? Vector3(0, -1, 0)
        : (worldOf(light.id).getRotation() * Vector3(0, 0, -1))
      ..normalize();

    return OrbisScene(
      objects: [
        for (final object in _objects)
          if (object.isDrawable)
            OrbisObject(
              transform: worldOf(object.id),
              colour: linearFromColour(object.colour),
              mesh: _resolveMesh(object.meshAsset, projectRoot),
            ),
      ],
      sun: OrbisSun(
        direction: direction,
        colour: linearFromColour(light?.colour ?? const Color(0xFFFFFFFF)),
        // Watts to lux through the same 683 lm/W the light package uses, so a
        // number set here means what it means in Blender.
        illuminance: (light?.power ?? 1000) * 683 / 12.566370614359172,
      ),
      sky: OrbisSky(colour: linearFromColour(skyColour), ambient: ambient),
      camera: camera,
    );
  }

  /// A stored mesh reference as a path the renderer can open.
  static String? _resolveMesh(String? reference, String? root) {
    if (reference == null) return null;
    if (root == null || p.isAbsolute(reference)) return reference;
    return p.join(root, reference);
  }

  /// sRGB to linear, because the shading maths is linear and a colour handed
  /// over unconverted is washed out in a way that reads as a lighting bug.
  static Vector3 linearFromColour(Color colour) =>
      Vector3(_linear(colour.r), _linear(colour.g), _linear(colour.b));

  static double _linear(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}
