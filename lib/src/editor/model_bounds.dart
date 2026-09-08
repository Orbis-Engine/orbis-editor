import 'dart:io';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math_64.dart';

import 'scene.dart';

/// How big an imported model says it is.
///
/// The editor does not hold the geometry of a model the renderer loaded — it
/// knows a path and nothing else. But every glTF file carries the minimum and
/// maximum of its own positions, precisely so a reader can frame, cull or pick
/// against a file it has not decoded, and reading that is a few hundred bytes
/// off the front of the file.
///
/// Without it every imported model is picked and outlined as a two-metre cube
/// whatever it actually is, which for anything small means a box floating
/// round nothing.
class ModelBounds {
  ModelBounds(this.projectRoot);

  final String projectRoot;

  /// Answers by path, misses included.
  ///
  /// A model that cannot be read is remembered as unreadable, because a scene
  /// with forty objects naming a missing file would otherwise read the disk
  /// forty times a frame.
  final Map<String, ({Vector3 min, Vector3 max})?> _known = {};

  /// What [object] occupies, or null when it has no file or the file says
  /// nothing.
  ({Vector3 min, Vector3 max})? of(SceneObject object) {
    final asset = object.meshAsset;
    if (asset == null || asset.isEmpty) return null;
    if (_known.containsKey(asset)) return _known[asset];

    final path = p.isAbsolute(asset) ? asset : p.join(projectRoot, asset);
    ({Vector3 min, Vector3 max})? found;
    try {
      final file = File(path);
      if (file.existsSync()) {
        // Both glTF containers. They are the same document with the buffers
        // in different places, and neither is read here — the minimum and
        // maximum are in the document itself. A `.gltf` beside its textures
        // is how most model libraries publish, so leaving it out meant the
        // commonest kind of imported model was the one that could not say
        // how big it was.
        found = switch (p.extension(path).toLowerCase()) {
          '.glb' => boundsOfGlb(file.readAsBytesSync()),
          '.gltf' => boundsOfGltf(file.readAsStringSync()),
          _ => null,
        };
      }
    } on FileSystemException {
      found = null;
    }

    _known[asset] = found;
    return found;
  }

  /// Forgets one file, for when it has been written again.
  void forget(String asset) => _known.remove(asset);

  void clear() => _known.clear();
}
