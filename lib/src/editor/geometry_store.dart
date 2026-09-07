import 'dart:io';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:path/path.dart' as p;

import 'scene.dart';
import 'surface.dart';

/// Geometry built in the editor, on its way to the renderer.
///
/// An object is drawn either as the built-in cube or from a glTF file, and
/// there is no third way in. So a shape becomes a file: written once, kept
/// while it has not changed, and handed to the renderer as any model exported
/// from Blender would be. One loader, one instancing pool, one shadow pass,
/// and no second path through the renderer for geometry that came from here.
///
/// The alternative — a channel for raw vertex data — is a real piece of native
/// work and buys a faster edit loop rather than anything visible. Worth doing
/// when somebody is dragging a face and the write shows; not before.
class GeometryStore {
  GeometryStore(this.projectRoot);

  final String projectRoot;

  /// Where the written files go: inside the project, out of the way, and
  /// disposable. Nothing here is authored — every one of them can be written
  /// again from the scene.
  Directory get folder => Directory(p.join(projectRoot, '.orbis', 'geometry'));

  /// What was last written for an object.
  ///
  /// The mesh itself, not a summary of it. Geometry is *replaced* when it
  /// changes — every edit hands over a new mesh, and a shape's built one is
  /// cached against the shape it came from — so "is this the same geometry"
  /// is a pointer compare. It used to be a string built by walking every
  /// vertex and every face, on every shape in the project, on every change.
  /// A change is every frame of a drag.
  /// [seenAt] is when the file was last confirmed to still be there, and
  /// [relative] is the answer, kept so the common case builds no strings at
  /// all — a path joined and interpolated for every shape on every frame of a
  /// drag is most of what this used to cost.
  final Map<String,
      ({Mesh mesh, int materials, String relative, int seenAt})> _written = {};

  /// A monotonic clock, for the "is it still there" check.
  ///
  /// Not `DateTime.now()`: that is asked once a shape and this is asked for
  /// every shape in the project on every change, and reading a wall clock
  /// turns out to be the expensive part of doing nothing.
  final Stopwatch _clock = Stopwatch()..start();

  /// How long a "yes, it is still there" is trusted for, in milliseconds.
  static const int _trustFor = 2000;

  /// The file an object's geometry lives in, writing it if it has changed.
  ///
  /// Returns a path relative to the project, or null when the object has no
  /// geometry or the write failed. A failed write is not worth an exception:
  /// the object draws as a cube, which is visible and recoverable, and the
  /// alternative is an editor that will not open a scene because a temporary
  /// folder was read-only.
  String? pathFor(SceneObject object) {
    final mesh = object.currentMesh;
    if (mesh == null || mesh.isEmpty) return null;

    final materials = _hashOf(object.surfaces);
    final was = _written[object.id];
    final now = _clock.elapsedMilliseconds;

    if (was != null && identical(was.mesh, mesh) && was.materials == materials) {
      // Written already. Whether it is *still* there is worth asking, but not
      // worth asking sixty times a second — somebody deleting a build folder
      // under a running editor can wait two seconds to be noticed.
      if (now - was.seenAt < _trustFor) return was.relative;
      if (File(p.join(projectRoot, was.relative)).existsSync()) {
        _written[object.id] = (
          mesh: was.mesh,
          materials: was.materials,
          relative: was.relative,
          seenAt: now,
        );
        return was.relative;
      }
    }

    final relative = p.join('.orbis', 'geometry', '${object.id}.glb');

    try {
      folder.createSync(recursive: true);
      File(p.join(projectRoot, relative)).writeAsBytesSync(mesh.toGlb(
        name: object.name,
        materials: [for (final one in object.surfaces) one.toGlb()],
      ));
    } on FileSystemException {
      return null;
    }

    _written[object.id] =
        (mesh: mesh, materials: materials, relative: relative, seenAt: now);
    return relative;
  }

  /// Whether anything has to be written for this object.
  bool isStale(SceneObject object) {
    final mesh = object.currentMesh;
    if (mesh == null) return false;
    final was = _written[object.id];
    return was == null ||
        !identical(was.mesh, mesh) ||
        was.materials != _hashOf(object.surfaces);
  }

  /// Forgets an object, so the next ask writes again.
  void forget(String id) => _written.remove(id);

  /// The material slots, as one number.
  ///
  /// These *are* edited in place — a slot's colour changes without the list
  /// being replaced — so identity says nothing and they are summed every
  /// time. There are a handful of them, which is the difference.
  static int _hashOf(List<Surface> surfaces) {
    var total = surfaces.length;
    for (final one in surfaces) {
      total = total * 31 +
          Object.hash(one.name, one.colour, one.metallic, one.roughness,
              one.emissive, one.doubleSided);
    }
    return total;
  }

  /// Throws away every file. For when a project is closed.
  void clear() {
    _written.clear();
    try {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    } on FileSystemException {
      // A folder that will not delete is a folder with some stale files in
      // it, which the next write replaces anyway.
    }
  }

  /// What tells one version of a mesh from another.
  ///
  /// Counts and a sum of the coordinates rather than the whole thing hashed.
  /// This is asked once a frame per shape, and hashing ten thousand vertices
  /// to find out that nothing moved is the kind of work that only shows up
  /// once somebody has a level full of them.



}
