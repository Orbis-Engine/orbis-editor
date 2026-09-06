import 'dart:io';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:path/path.dart' as p;

import 'scene.dart';

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

  /// What was last written for an object, so nothing is written twice.
  final Map<String, String> _written = {};

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

    final name = '${object.id}.glb';
    final relative = p.join('.orbis', 'geometry', name);
    final stamp = _stampOf(mesh);

    if (_written[object.id] == stamp) {
      // Written already, unless somebody deleted it underneath us.
      if (File(p.join(projectRoot, relative)).existsSync()) return relative;
    }

    try {
      folder.createSync(recursive: true);
      File(p.join(projectRoot, relative))
          .writeAsBytesSync(mesh.toGlb(name: object.name));
    } on FileSystemException {
      return null;
    }

    _written[object.id] = stamp;
    return relative;
  }

  /// Whether anything has to be written for this object.
  bool isStale(SceneObject object) {
    final mesh = object.currentMesh;
    if (mesh == null) return false;
    return _written[object.id] != _stampOf(mesh);
  }

  /// Forgets an object, so the next ask writes again.
  void forget(String id) => _written.remove(id);

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
  static String _stampOf(Mesh mesh) {
    var total = 0.0;
    for (final at in mesh.positions) {
      total += at.x + at.y * 3 + at.z * 7;
    }
    var corners = 0;
    for (final face in mesh.faces) {
      corners += face.vertices.length;
    }
    return '${mesh.positions.length}/${mesh.faces.length}/$corners/'
        '${total.toStringAsFixed(4)}';
  }
}
