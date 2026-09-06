import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:orbis_weather/orbis_weather.dart';

import 'colour.dart';

import 'package:vector_math/vector_math_64.dart' hide Colors;

/// What kind of thing an object is, which decides what components it has and
/// therefore what the inspector shows.
enum ObjectKind { scene, mesh, light, camera, group, weather }

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
    this.lightType = LightType.sun,
    this.spotSize = 45,
    this.spotBlend = 0.15,
    this.sourceRadius = 0.1,
    this.sunAngle = 0.526,
    this.body = CelestialBody.sun,
    WeatherState? weather,
    this.condition = WeatherCondition.clear,
    this.cloudKind,
    this.windDirection = 135,
    this.transitionSeconds = 8,
    this.castShadows = true,
    this.receiveShadows = true,
    this.visible = true,
    this.meshAsset,
    this.prefab,
    List<String>? data,
  })  : data = data ?? [],
        weather = weather ?? WeatherState.of(condition),
        position = position ?? Vector3.zero(),
        rotation = rotation ?? Vector3.zero(),
        scale = scale ?? Vector3(1, 1, 1);

  final String id;

  /// What the renderer knows this object by.
  ///
  /// A number rather than the id, because it crosses to native code on every
  /// frame of a drag and a string would be encoded, copied and hashed each
  /// time. Assigned once and never reused, so a pasted copy gets a key of its
  /// own instead of inheriting the entity of the thing it was copied from.
  final int renderKey = _nextRenderKey++;

  static int _nextRenderKey = 1;

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

  /// Light power, in the units its [lightType] is stated in: watts per square
  /// metre for a sun, which has no total to state, and watts for everything
  /// else. Ignored by anything that is not a light.
  double power;

  /// What kind of light this is. Decides what [power] means, whether the cone
  /// applies, and what the renderer is asked for.
  LightType lightType;

  /// The full cone angle of a spot in degrees, and how much of it is falloff
  /// rather than full brightness — zero for a hard edge, one for a cone that
  /// is all gradient.
  double spotSize;
  double spotBlend;

  /// How large the emitting source is, in metres.
  ///
  /// Not a brightness control: the power is unchanged and spread over a bigger
  /// surface. What it changes is the shadow — a point source gives a knife
  /// edge, and anything with size gives a penumbra that widens with distance.
  double sourceRadius;

  /// What the air is doing, for the object that is the weather.
  ///
  /// The values rather than the name: a condition is where they came from and
  /// they are free to be moved afterwards. Held as one object because weather
  /// changes, and a change needs both ends of it in one place — eight fields
  /// on the object would be eight things to keep in step through a
  /// transition.
  WeatherState weather;

  /// The condition last applied, which is what the panel shows as chosen.
  WeatherCondition condition;

  /// Which shape of cloud the sky has, or null to take the condition's own.
  ///
  /// Separate from the condition because the same weather makes very
  /// different skies: a fair afternoon can be cauliflower cumulus with blue
  /// between them or one flat sheet, and a scene should be able to say which.
  /// Null rather than a default so that changing the condition still changes
  /// the sky for anybody who has not made a choice.
  CloudKind? cloudKind;

  /// Which way the wind blows, in degrees. Not part of a condition: a storm
  /// is windy wherever it is, and which way is a fact about the place.
  double windDirection;

  /// How long a change of condition takes to arrive, in seconds.
  double transitionSeconds;

  /// The weather this object is on its way from, and when it set off.
  ///
  /// Not saved and not part of the document: a scene reopened tomorrow is in
  /// the weather it was saved in, not halfway into it.
  WeatherState? blendFrom;
  double blendSince = 0;

  /// Which body a directional light is, when nothing else is deciding.
  ///
  /// A day cycle decides for itself — whatever is above the horizon — and this
  /// is what the light is between cycles, or in a scene that has none.
  CelestialBody body;

  /// The sun's angular diameter in degrees, which is the same idea for a light
  /// that has no position. Defaults to the real sun's.
  ///
  /// It is why a shadow outdoors is crisp at your feet and soft at its far
  /// end, and setting it to zero is the quickest way to make a scene look
  /// computer-generated.
  double sunAngle;

  bool castShadows;

  /// Whether shadows land on this object.
  bool receiveShadows;

  /// Whether it is drawn, and whether it lights anything.
  ///
  /// Hidden is not deleted: it keeps its place in the tree, its children, and
  /// the key the renderer knows it by, so showing it again is immediate.
  bool visible;

  /// The mesh this object draws, as a path relative to the project.
  ///
  /// Null means the built-in cube. A referenced mesh is *still* drawn as a
  /// cube for now — the reference is recorded and shown, and the renderer
  /// honours it once glTF loading exists. Naming it here rather than pretending
  /// to load it keeps the file honest about what the scene says.
  String? meshAsset;

  /// The prefab this came from, as a path relative to the project.
  ///
  /// Null for an ordinary object. Set on every object in an instance, root
  /// and children alike, because a change three levels down still has to know
  /// which asset it belongs to. Unpacking clears it, and from then on this is
  /// an ordinary object that happens to look like a prefab.
  String? prefab;

  /// Whether this object came from a prefab and still remembers it.
  bool get isPrefabInstance => prefab != null;

  /// Data objects this one is configured by, as paths relative to the project.
  ///
  /// A reference rather than a copy, which is the whole point: forty crates
  /// pointing at one `weight.odata` change together, and the value is edited
  /// where it lives instead of being typed onto forty objects and missed on
  /// thirty-nine. What is *in* the data object is not this object's business —
  /// the file is the source of truth, and the editor, a script and a person
  /// with a text editor all read the same one.
  final List<String> data;

  IconData get icon => switch (kind) {
        ObjectKind.scene => Icons.public,
        ObjectKind.group => Icons.folder_outlined,
        ObjectKind.mesh => Icons.view_in_ar_outlined,
        ObjectKind.light => Icons.wb_sunny_outlined,
        ObjectKind.camera => Icons.videocam_outlined,
        ObjectKind.weather => Icons.cloud_outlined,
      };

  /// Whether this object is drawn.
  bool get isDrawable => kind == ObjectKind.mesh;

  /// Where the object sits relative to its parent.
  Matrix4 get localTransform => Matrix4.identity()
    ..setTranslation(position)
    ..multiply(rotationFromDegrees(rotation))
    ..multiply(Matrix4.diagonal3(scale));

  /// A copy with a new identity, for pasting.
  SceneObject copyAs({required String id, String? parentId}) =>
      _copyWith(id: id, parentId: parentId);

  SceneObject copy() => _copyWith(id: id, parentId: parentId);

  /// One place both copies are made, so a field added to an object cannot be
  /// remembered by paste and forgotten by the clipboard.
  SceneObject _copyWith({required String id, String? parentId}) => SceneObject(
        id: id,
        name: name,
        kind: kind,
        parentId: parentId,
        position: position.clone(),
        rotation: rotation.clone(),
        scale: scale.clone(),
        colour: colour,
        power: power,
        lightType: lightType,
        spotSize: spotSize,
        spotBlend: spotBlend,
        sourceRadius: sourceRadius,
        sunAngle: sunAngle,
        body: body,
        weather: weather,
        condition: condition,
        cloudKind: cloudKind,
        windDirection: windDirection,
        transitionSeconds: transitionSeconds,
        castShadows: castShadows,
        receiveShadows: receiveShadows,
        visible: visible,
        meshAsset: meshAsset,
        prefab: prefab,
        data: List<String>.from(data),
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

/// Sets an object's local transform so it lands on a given world matrix.
///
/// What keeps a thing where it looks when its parent changes — on a reparent,
/// and on a paste into a scene whose parent chain is different. Without it,
/// dropping something into a folder teleports it.
void placeInWorld(EditorScene scene, SceneObject object, Matrix4 world) {
  final parentId = object.parentId;
  final local = parentId == null || !scene.contains(parentId)
      ? world
      : Matrix4.inverted(scene.worldOf(parentId)).multiplied(world);

  final position = Vector3.zero();
  final rotation = Quaternion.identity();
  final scale = Vector3.zero();
  local.decompose(position, rotation, scale);

  object.position.setFrom(position);
  object.rotation.setFrom(eulerDegreesOf(local));
  object.scale.setFrom(scale);
  scene.invalidate();
}

/// An object being dragged.
///
/// A type of its own rather than the bare id, because an asset path is also a
/// string and the outliner, the viewport and the project browser all take
/// drops. With one type for both, dragging a crate into the browser would look
/// exactly like dragging a file, and each target would have to guess.
class ObjectDrag {
  const ObjectDrag(this.id, this.name);

  final String id;

  /// What to call it while it is in the air, and what to name the file it
  /// lands in.
  final String name;
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
    this.timeOfDay = 10,
    this.dayCycle = false,
    this.hoursPerSecond = 0.5,
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
        // Watts per square metre, because that is what a sun's strength is
        // stated in. A hundred and ten of them is about seventy-five thousand
        // lux, which is a bright but not blinding afternoon.
        SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light,
            rotation: Vector3(-55, 35, 0),
            colour: const Color(0xFFFFF3E0), power: 110),
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
        // A fair day rather than a clear one, so the object in the tree is
        // visibly doing something the moment somebody selects it.
        SceneObject(id: 'weather', name: 'Weather',
            kind: ObjectKind.weather, condition: WeatherCondition.fair),
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

  /// The hour the scene is set at, from zero to twenty-four.
  ///
  /// What is authored, not what is showing: with a cycle running, this is
  /// where the day starts from and [currentTimeOfDay] is where it has got to.
  /// Keeping them apart means a cycle left running does not quietly rewrite
  /// the scene somebody saved.
  double timeOfDay;

  /// Whether the day runs on its own, and how fast.
  ///
  /// Off, the scene sits at its hour and the body above it is whichever one
  /// the light says it is. On, the hour advances and the sky decides.
  bool dayCycle;
  double hoursPerSecond;

  /// Seconds since the editor started animating this scene.
  ///
  /// Not saved, and not part of the document: it is the editor's clock, and a
  /// scene reopened tomorrow should be where it was left rather than wherever
  /// the ticker had got to.
  double clock = 0;

  /// Whether anything here moves without somebody moving it.
  ///
  /// Drifting cloud is not in this list. The renderer moves that on its own
  /// clock, so it keeps going at sixty frames a second without the editor
  /// republishing the scene to say so — which is the difference between mist
  /// costing a message a frame and costing nothing.
  bool get isAnimated =>
      dayCycle || _weatherIsChanging || (weatherNow?.lightning ?? 0) > 0;

  /// The object that decides what the air is doing, if there is one.
  ///
  /// The first of them. A scene with two would be two answers to one
  /// question, and the same rule the light above the scene follows: the first
  /// one is it, and the rest are reported rather than silently obeyed.
  SceneObject? get weather {
    for (final object in _objects) {
      if (object.kind == ObjectKind.weather) return object;
    }
    return null;
  }

  /// Whether more than one thing is claiming to be the weather.
  bool get hasSpareWeather =>
      _objects.where((o) => o.kind == ObjectKind.weather).length > 1;

  /// What the air is doing this instant, part of the way through whatever
  /// change it is in the middle of.
  WeatherState? get weatherNow {
    final object = weather;
    if (object == null || !isShown(object.id)) return null;

    final from = object.blendFrom;
    if (from == null || object.transitionSeconds <= 0) return object.weather;

    final t = (clock - object.blendSince) / object.transitionSeconds;
    if (t >= 1) return object.weather;
    return WeatherState.lerp(from, object.weather, t);
  }

  bool get _weatherIsChanging {
    final object = weather;
    if (object == null || object.blendFrom == null) return false;
    return clock - object.blendSince < object.transitionSeconds;
  }

  /// The hour the scene is showing, which is the authored one until a cycle
  /// starts carrying it forward.
  double get currentTimeOfDay =>
      dayCycle ? (timeOfDay + clock * hoursPerSecond) % 24 : timeOfDay;

  /// The sky at that hour.
  SkyState get skyState => DayCycle.at(currentTimeOfDay);

  /// The light everything is lit from above by, if there is one.
  ///
  /// The first directional light in the scene. A renderer draws one, so a
  /// second is a light that would be quietly ignored — and this is where the
  /// choice of which is made rather than left to chance.
  SceneObject? get celestial {
    for (final object in _objects) {
      if (object.kind == ObjectKind.light &&
          object.lightType == LightType.sun) {
        return object;
      }
    }
    return null;
  }

  /// Which body is up: the cycle's, or the one the light was told to be.
  CelestialBody get activeBody =>
      dayCycle ? skyState.body : (celestial?.body ?? CelestialBody.sun);

  /// What an object is called on screen.
  ///
  /// A celestial light that still has a body's name for a name follows the
  /// body, so a scene that runs into the night says Moon in the tree without
  /// anybody editing the document. Give it a name of your own and it keeps
  /// that instead — a rename is somebody saying they want it called that.
  String displayNameOf(SceneObject object) {
    if (!identical(object, celestial)) return object.name;
    final named = CelestialBody.values.any((b) => b.label == object.name);
    return named ? activeBody.label : object.name;
  }

  /// The icon that goes with that name.
  IconData displayIconOf(SceneObject object) =>
      identical(object, celestial) && activeBody == CelestialBody.moon
          ? Icons.nightlight_outlined
          : object.icon;

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

  /// Whether an object is shown, which means it and everything above it is.
  ///
  /// Hiding a group has to hide what is inside it. A flag that applied only to
  /// the thing it was set on would make hiding a folder do nothing visible,
  /// which reads as a broken toggle rather than as a deliberate limit.
  bool isShown(String id) {
    var current = _byId[id];
    var steps = 0;
    while (current != null && steps < _maxDepth) {
      if (!current.visible) return false;
      final parentId = current.parentId;
      if (parentId == null) return true;
      current = _byId[parentId];
      steps++;
    }
    return true;
  }

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

  /// The nearest drawable object a ray runs into, or null for empty space.
  ///
  /// Against the unit cube the renderer draws, in each object's own space, so
  /// an object that has been rotated and squashed is hit where it looks rather
  /// than inside the upright box that would contain it. A real mesh is a finer
  /// question than this can answer — that wants the geometry itself, which
  /// lives on the other side of the channel.
  String? objectAlong(Vector3 origin, Vector3 direction) {
    String? nearest;
    var closest = double.infinity;

    for (final object in _objects) {
      if (!object.isDrawable || !isShown(object.id)) continue;

      final world = worldOf(object.id);
      final inverse = Matrix4.tryInvert(world);
      // A zero scale on any axis leaves nothing to hit.
      if (inverse == null) continue;

      final from = inverse.transformed3(origin.clone());
      // As the difference of two transformed points, so the translation
      // cancels and what is left is the direction in the object's space —
      // still measured in world units, which is what makes the distances
      // comparable between objects.
      final along = inverse.transformed3(origin + direction) - from;

      final hit = _unitCubeHit(from, along);
      if (hit == null || hit >= closest) continue;
      closest = hit;
      nearest = object.id;
    }
    return nearest;
  }

  /// How far along a ray the unit cube is first met, or null for a miss.
  ///
  /// The slab method: the span of the ray inside each pair of parallel faces,
  /// intersected. If what is left is empty the ray goes past.
  static double? _unitCubeHit(Vector3 origin, Vector3 direction) {
    var near = -double.infinity;
    var far = double.infinity;

    for (var axis = 0; axis < 3; axis++) {
      final o = origin[axis];
      final d = direction[axis];

      if (d.abs() < 1e-9) {
        // Parallel to this pair of faces: either between them for the whole
        // ray, or never.
        if (o < -1 || o > 1) return null;
        continue;
      }

      final first = (-1 - o) / d;
      final second = (1 - o) / d;
      near = math.max(near, math.min(first, second));
      far = math.min(far, math.max(first, second));
      if (near > far) return null;
    }

    // Behind the eye is not in front of it.
    if (far < 0) return null;
    return near >= 0 ? near : far;
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
  /// Everything the renderer draws, viewed from [camera].
  ///
  /// [shared] is what every scene in the project has in it: its objects and
  /// its lights are drawn alongside this scene's own, and its weather and its
  /// sun stand in where this scene has none. The loaded scene wins wherever
  /// both have something to say, which is the rule that makes a shared set
  /// useful rather than something to work around — put a manager there once
  /// and every scene has it, and any scene can still overrule it.
  OrbisScene toRenderScene(
    OrbisCamera camera, {
    String? projectRoot,
    EditorScene? shared,
  }) {
    final sky = skyState;
    final driven = dayCycle;

    // What is above the scene, and what the air is doing, from whichever of
    // the two has one.
    final lit = celestial ?? shared?.celestial;
    final air = weatherNow ?? shared?.weatherNow;
    final flash = air == null || air.lightning <= 0
        ? 0.0
        : WeatherState.flashAt(clock, air.lightning);

    final lights = [
      for (final scene in [this, ?shared])
        for (final object in scene._objects)
          // A hidden light is left out rather than sent dark. Filament shades
          // one directional light and a budget of punctual ones, and a light
          // nobody can see should not be the one that fills the budget.
          if (object.kind == ObjectKind.light && scene.isShown(object.id))
            scene._lightFor(
              object,
              sky: driven && identical(object, lit) ? sky : null,
              air: identical(object, lit) ? air : null,
              flash: identical(object, lit) ? flash : 0,
            ),
    ];

    // A covered sky is one enormous diffuser: less of the light arrives from
    // one direction and more of it from everywhere. A strike lights the whole
    // of it at once, which is why lightning has no shadows worth the name.
    final ambientLux =
        (driven ? sky.ambient : ambient) * (air?.scattered ?? 1) * (1 + flash * 40);

    return OrbisScene(
      objects: [
        for (final scene in [this, ?shared])
          for (final object in scene._objects)
            if (object.isDrawable)
              OrbisObject(
                key: object.renderKey,
                transform: scene.worldOf(object.id),
                colour: linearFromColour(object.colour),
                mesh: _resolveMesh(object.meshAsset, projectRoot),
                castShadows: object.castShadows,
                receiveShadows: object.receiveShadows,
                visible: scene.isShown(object.id),
              ),
      ],
      lights: lights,
      sky: _skyFrom(
        base: _greyed(
          driven ? sky.skyColour : skyColour.tint,
          (air?.greying ?? 0) * 0.8,
        ),
        ambientLux: ambientLux,
        lights: lights,
        lit: lit,
        body: driven ? sky : null,
        air: air,
        weather: weather ?? shared?.weather,
        flash: flash,
      ),
      fog: _fogFrom(air, weather ?? shared?.weather),
      precipitation: _precipitationFrom(air, weather ?? shared?.weather),
      camera: driven ? _metered(camera, lights, ambientLux) : camera,
    );
  }

  /// The camera, set for the light this scene actually has in it.
  OrbisCamera _metered(
    OrbisCamera camera,
    List<OrbisLight> lights,
    double ambientLux,
  ) {
    final exposure =
        CameraExposure.forIlluminance(_incidentLux(lights, ambientLux));
    return camera.copyWith(
      aperture: exposure.aperture,
      shutterSpeed: exposure.shutterSpeed,
      sensitivity: exposure.sensitivity,
    );
  }

  /// How much light is actually falling on this scene, in lux.
  ///
  /// Read off the lights being sent rather than off what the day cycle
  /// intends, because those are not always the same thing. A scene whose light
  /// is a bulb rather than a sun, or one somebody has turned up, still has to
  /// be exposed for what it has — metering off the hour instead is how a night
  /// ends up a white rectangle with the shapes barely showing through it.
  ///
  /// Directional light only. A lamp lights the corner it is in rather than the
  /// scene, and a camera set for the corner would blow out everywhere else —
  /// which is exactly what a real one does, too.
  double _incidentLux(List<OrbisLight> lights, double ambientLux) {
    var total = ambientLux;
    for (final light in lights) {
      if (light.kind != OrbisLightKind.directional) continue;
      // Angled by how high it is: a sun on the horizon lays far less on the
      // ground than one overhead, and metering as though it did would leave
      // every dusk under-exposed.
      total += light.intensity * math.max(0, -light.direction.y);
    }
    return total;
  }

  /// The air, as the weather has it this instant.
  ///
  /// Two things through one setting. The even haze is what distance looks
  /// like; the sheets are what a bank of cloud looks like lying in a valley.
  /// A condition asks for both, because weather with no haze behind it reads
  /// as cut-outs hanging in clear air.
  OrbisFog _fogFrom(WeatherState? now, SceneObject? object) {
    if (now == null || object == null) return OrbisFog.none;

    final heading = WeatherState.windFrom(object.windDirection);

    return OrbisFog(
      colour: now.fogColour.linear,
      density: now.fogDensity,
      height: now.fogHeight,
      heightFalloff: now.fogFalloff,
      structure: now.mist,
      // Metres a second, which is what wind is measured in. Turning that into
      // how fast a pattern scrolls is the renderer's business, because only it
      // knows how big the pattern is.
      wind: Vector2(
        heading.x * now.windSpeed,
        heading.z * now.windSpeed,
      ),
      // Turns of the noise per metre: the reciprocal of how big a cloud is,
      // stated the way somebody would measure it rather than the way the
      // shader wants it.
      featureSize: 1 / math.max(now.mistSize, 0.5),
      // How deep the bank is, out of how fast the haze thins with altitude.
      // The two describe the same layer, and authoring them apart would let
      // somebody set a shallow haze with a bank standing out of the top of it.
      thickness: (1 / math.max(now.fogFalloff, 0.05)).clamp(1.0, 40.0),
    );
  }

  /// What is coming down, if anything is.
  ///
  /// Rain and snow are the same curtain at different settings, so a scene
  /// with some of each — which is what the temperature between them looks
  /// like — is one curtain part of the way from streaks to flakes rather than
  /// two curtains fighting.
  OrbisPrecipitation _precipitationFrom(
    WeatherState? now,
    SceneObject? object,
  ) {
    if (now == null || object == null || !now.isWet) {
      return OrbisPrecipitation.none;
    }

    final total = now.rain + now.snow;
    final asSnow = (now.snow / total).clamp(0.0, 1.0);
    double between(double wet, double white) => wet + (white - wet) * asSnow;

    final heading = WeatherState.windFrom(object.windDirection);

    return OrbisPrecipitation(
      colour: linearFromColour(
        Color.lerp(const Color(0xFFB8C6D6), const Color(0xFFF2F5F8), asSnow)!,
      ),
      amount: total.clamp(0.0, 1.0),
      // Nine metres a second for rain, under one for snow. It is the whole
      // difference in how the two read.
      fall: between(9, 0.8),
      // Snow is taken by the wind far more than rain is: it weighs nothing
      // and it has all day.
      wind: Vector2(
        heading.x * now.windSpeed * between(0.6, 1.6),
        heading.z * now.windSpeed * between(0.6, 1.6),
      ),
      dropsPerMetre: between(8, 3.5),
      // How far a drop travels while the shutter is open. A streak, or a
      // flake.
      stretch: between(30, 5),
      threshold: between(0.7, 0.55),
    );
  }

  /// The sky: its gradient, the body in it, the cloud, and any strike.
  ///
  /// One object because it is one shader on one dome. Splitting it was the
  /// mistake behind two rounds of cloud that did not read as sky: the cloud
  /// was tinted a colour somebody chose, while the sun was drawn somewhere
  /// else entirely, and nothing in the picture agreed with anything else.
  /// Here the cloud is lit by the same direction the scene is.
  OrbisSky _skyFrom({
    required Tint base,
    required double ambientLux,
    required List<OrbisLight> lights,
    required SceneObject? lit,
    required SkyState? body,
    required WeatherState? air,
    required SceneObject? weather,
    required double flash,
  }) {
    final ground = base.linear;
    final strike = _strikeFrom(air, weather);

    // Which way the body is, taken from the light that is actually lighting
    // the scene rather than from the clock. A sun drawn in one place and a
    // cloud lit from another is the single thing that gives a sky away.
    final beam = lights
        .where((light) => light.kind == OrbisLightKind.directional)
        .firstOrNull;
    final toBody = beam == null
        ? Vector3(0.35, 0.78, 0.52)
        : (-beam.direction)
      ..normalize();

    // The body's own colour, at a brightness that says which body it is. The
    // moon is the sun's light at a millionth of the strength and the exposure
    // opens right up for it, so it needs saying here or the night has a
    // second sun in it.
    final night = toBody.y < 0.999 && body != null && body.body == CelestialBody.moon;
    final bodyColour =
        (beam == null ? Vector3(1.0, 0.96, 0.90) : beam.colour.clone())
          ..scale(night ? 0.30 : 1.0);

    // Overhead is the deepest part of a sky and the horizon the palest,
    // because the horizon is where the most air is and every metre of it
    // scatters. When the body is low the horizon takes its colour, which is
    // the whole of a sunset.
    final zenith = ground.clone()..scale(0.82);
    final glow = body == null
        ? 0.30
        : (1 - (body.altitude / 0.45)).clamp(0.0, 1.0).toDouble();
    final horizon = _mix(
      _mix(ground, Vector3(0.72, 0.80, 0.92), 0.30),
      bodyColour,
      glow * 0.55,
    );

    return OrbisSky(
      colour: ground,
      zenith: zenith,
      horizon: horizon,
      ambient: ambientLux,
      // Nothing to draw a disk for if the scene has no light above it, and
      // one nobody can see should not appear in the sky either.
      showBody: lit != null,
      bodyDirection: toBody,
      bodyColour: bodyColour,
      // A degree across rather than the sun's own half-degree. A physically
      // sized disc is four pixels on a normal screen, and a sun nobody can
      // pick out of the glare is not worth drawing.
      bodySize: 0.011,
      flash: strike.flash,
      flashDirection: strike.direction,
      flashSeed: strike.seed,
      clouds: _cloudsFrom(air, weather, bodyColour),
    );
  }

  /// Component-wise interpolation, which vector_math does not offer for
  /// colours and which reads worse written out three times.
  static Vector3 _mix(Vector3 from, Vector3 to, double t) => Vector3(
    from.x + (to.x - from.x) * t,
    from.y + (to.y - from.y) * t,
    from.z + (to.z - from.z) * t,
  );

  /// The strike this instant, or none if the sky is not that kind of sky.
  Strike _strikeFrom(WeatherState? now, SceneObject? object) =>
      now == null || object == null || now.lightning <= 0
      ? Strike.none
      : WeatherState.strikeAt(clock, now.lightning);

  /// The cloud in the sky, which is not the same thing as the fog.
  ///
  /// Fog is the air between here and the horizon; cloud is a layer a long way
  /// overhead that the light comes through. A scene can have either without
  /// the other, and one setting doing both would be wrong for every scene
  /// that wants one of them.
  ///
  /// The kind is a shape, not a preset: which one is chosen decides how high
  /// the base sits, how deep the layer is and how far its noise is folded,
  /// and none of those can be reached by turning a cover slider.
  OrbisClouds _cloudsFrom(
    WeatherState? now,
    SceneObject? object,
    Vector3 bodyColour,
  ) {
    if (now == null || object == null || now.cloudCover <= 0.01) {
      return OrbisClouds.none;
    }

    // A condition that has no cloud of its own still gets one if somebody
    // has turned the cover up, because the alternative is a slider that does
    // nothing until the condition is changed too. The chosen kind wins over
    // both, including when it is None.
    final kind = object.cloudKind ??
        switch (CloudKind.forCondition(object.condition)) {
          CloudKind.none => CloudKind.cumulus,
          final chosen => chosen,
        };
    if (kind == CloudKind.none) return OrbisClouds.none;

    final heading = WeatherState.windFrom(object.windDirection);

    // Carried faster than anything at ground level, because there is nothing
    // up there to slow the wind down.
    final wind = Vector2(
      heading.x * now.windSpeed * 2.5,
      heading.z * now.windSpeed * 2.5,
    );

    final clouds = switch (kind) {
      CloudKind.none => OrbisClouds.none,
      CloudKind.cumulus => OrbisClouds.cumulus(cover: now.cloudCover, wind: wind),
      CloudKind.stratocumulus =>
        OrbisClouds.stratocumulus(cover: now.cloudCover, wind: wind),
      CloudKind.stratus => OrbisClouds.stratus(cover: now.cloudCover, wind: wind),
      CloudKind.cirrus => OrbisClouds.cirrus(cover: now.cloudCover, wind: wind),
      CloudKind.cumulonimbus =>
        OrbisClouds.cumulonimbus(cover: now.cloudCover, wind: wind),
    };

    // The kind is the shape; the height is a setting on top of it, and the
    // scene always has one.
    return clouds.copyWith(
      altitude: now.cloudHeight,
      // What the sky puts back into the shadowed side, warmed by whatever is
      // above it. A cloud lit only from one side has a black underside, and
      // no real one does.
      colour: _mix(clouds.colour, bodyColour, 0.18),
    );
  }

  /// A colour dragged towards the flat grey of a covered sky.
  static Tint _greyed(Tint colour, double amount) =>
      Tint.lerp(colour, const Tint.hex(0x9BA3AB), amount);

  /// One authored light, in the units the renderer takes.
  ///
  /// The conversion happens in `orbis_light` rather than here. Watts, metres
  /// and degrees are what a light is stated in; lumens, lux and radians are
  /// what a renderer is told. Doing that arithmetic in the editor as well
  /// would be a second place for it to drift.
  /// One light, in the units the renderer takes.
  ///
  /// Told what is happening to it rather than working it out. Which light the
  /// sky is standing in for, and what the weather is, are questions about the
  /// project rather than about the scene this light happens to live in — a sun
  /// in the shared set is still the sun of whichever scene is open.
  OrbisLight _lightFor(
    SceneObject object, {
    SkyState? sky,
    WeatherState? air,
    double flash = 0,
  }) {
    final world = worldOf(object.id);

    // A day cycle owns the one light everything is lit from above by: where it
    // is, what colour it is and how strong. The object keeps what it was
    // authored with, so turning the cycle off puts it back rather than leaving
    // it wherever the clock stopped.
    final driven = sky != null;

    // Cloud sits between the scene and whatever is above it, so it only
    // touches that one light. A lamp indoors does not care what the sky is
    // doing, and neither should a stage light somebody has aimed by hand.
    final now = air;

    final described = Light(
      type: object.lightType,
      color: _greyed(
        sky?.lightColour ?? object.colour.tint,
        now?.greying ?? 0,
      ).linear,
      // Cloud does not switch the sun off. A heavy overcast still passes a
      // good tenth of it, which is why a wet afternoon is grey rather than
      // dark: the camera opens up and the world stays legible.
      //
      // A strike goes the other way, briefly and by a lot. It comes through
      // the light that is already above the scene rather than as a second
      // one: a flash is the sky lighting up, and the sky is what that light
      // is standing in for.
      power: (sky?.power ?? object.power) *
          (now?.transmitted ?? 1) *
          (1 + flash * 60),
      radius: object.sourceRadius,
      spotSize: object.spotSize,
      spotBlend: object.spotBlend,
      // The whole difference between a bright day and a dull one. The sun is
      // a disc half a degree across; cloud turns it into a source the size of
      // the sky, and shadows lose their edges long before they lose their
      // depth.
      sunAngle: object.sunAngle * (now?.spread ?? 1),
      castShadows: object.castShadows,
      // An area light arrives as a point of the same luminous power, so the
      // size it would have emitted from becomes the size of the source that
      // stands in for it — the falloff and the total are right, and the
      // penumbra is at least a believable width.
      sizeX: object.sourceRadius * 2,
      sizeY: object.sourceRadius * 2,
    );
    final light = described.toRenderer();

    // Down the local -Z axis, which is where a light points: the same
    // convention as a camera, so a light parented to a rig turns with it.
    final direction = sky?.direction ??
        (world.getRotation() * Vector3(0, 0, -1)
          ..normalize());

    // What tells a sun from a moon at a glance, once both are white discs of
    // the same width: a sun is wrapped in glare and a moon is not.
    final body = driven ? sky.body : object.body;
    final isMoon = body == CelestialBody.moon;

    return OrbisLight(
      key: object.renderKey,
      kind: switch (light.kind) {
        RendererLightKind.directional => OrbisLightKind.directional,
        RendererLightKind.point => OrbisLightKind.point,
        RendererLightKind.spot => OrbisLightKind.spot,
      },
      colour: light.color,
      intensity: light.intensity,
      position: world.getTranslation(),
      direction: direction,
      // A sun's influence is infinite, which is not a number a renderer can
      // be given. It ignores the falloff of a directional light anyway, so
      // zero here means "not asked" rather than "no reach".
      falloffRadius: light.falloffRadius.isFinite ? light.falloffRadius : 0,
      innerConeAngle: light.innerConeAngle,
      outerConeAngle: light.outerConeAngle,
      sunAngularRadius: light.sunAngularRadius,
      sourceRadius: light.sourceRadius,
      haloSize: isMoon ? 3 : 12,
      haloFalloff: isMoon ? 240 : 70,
      castShadows: light.castShadows,
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
