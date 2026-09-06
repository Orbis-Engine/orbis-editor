import 'dart:convert';

import 'package:vector_math/vector_math_64.dart';

import 'scene.dart';
import 'scene_document.dart';

/// An object and everything under it, saved as an asset and reusable.
///
/// The point of one is that the thing exists in the project rather than in a
/// scene: a lamp post made once can be dropped down a street a hundred times,
/// and when the lamp changes, the street changes. Without prefabs the only way
/// to have a hundred of something is a hundred copies, and the hundred-and-
/// first change has to be made a hundred times.
///
/// The file is the same JSON a scene uses for its objects, so a prefab is
/// readable, diffable and mergeable, and a scene and a prefab cannot drift
/// into two encodings of the same object.
class Prefab {
  const Prefab({
    required this.name,
    required this.rootId,
    required this.objects,
  });

  /// What the thing is called. The file name without its extension is what
  /// wins on disk; this is what an instance is named when it is dropped in.
  final String name;

  /// The id of the object everything else hangs off, inside this file.
  final String rootId;

  /// The root and its descendants. Ids are local to the prefab: they are
  /// remapped on the way into a scene, so the same prefab can be instanced
  /// twice without the two arguing over an id.
  final List<SceneObject> objects;

  static const String marker = 'orbis.prefab';
  static const int formatVersion = 1;

  static const String extension = '.oprefab';

  /// Takes an object out of a scene, with everything under it.
  ///
  /// The root's own transform is dropped: a prefab is a thing, not a thing at
  /// a place, and one saved from an object standing at x=40 should not arrive
  /// forty metres away every time it is used. Its rotation and scale are kept,
  /// because those are usually part of what the thing *is*.
  static Prefab fromScene(EditorScene scene, String id) {
    final root = scene[id];
    if (root == null) {
      throw SceneError('That object is not in this scene.');
    }

    final copy = root.copy()
      ..parentId = null
      ..prefab = null;
    copy.position.setZero();

    return Prefab(
      name: root.name,
      rootId: root.id,
      objects: [
        copy,
        for (final child in scene.descendantsOf(id)) child.copy()..prefab = null,
      ],
    );
  }

  /// The file's contents.
  String toText() => '${const JsonEncoder.withIndent('  ').convert({
        'kind': marker,
        'formatVersion': formatVersion,
        'sceneFormatVersion': SceneDocument.formatVersion,
        'name': name,
        'root': rootId,
        'objects': [for (final o in objects) SceneDocument.objectToJson(o)],
      })}\n';

  /// Reads a prefab, or says why it could not.
  ///
  /// Null rather than an exception: a `.oprefab` in a project may have been
  /// written by a newer build, edited by hand, or half-copied, and a browser
  /// that throws on one bad file shows nothing at all.
  static Prefab? read(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?> || parsed['kind'] != marker) {
      return null;
    }

    final raw = parsed['objects'];
    if (raw is! List) return null;

    final version = parsed['sceneFormatVersion'];
    final objects = <SceneObject>[];
    for (final entry in raw) {
      if (entry is! Map<String, Object?>) continue;
      final object = SceneDocument.objectFromJson(
        entry,
        version: version is int ? version : SceneDocument.formatVersion,
      );
      if (object != null) objects.add(object);
    }
    if (objects.isEmpty) return null;

    final root = parsed['root'];
    final rootId = root is String && objects.any((o) => o.id == root)
        ? root
        // A file whose root is missing still has a root: the one object with
        // no parent. Better than refusing to open something recoverable.
        : objects.firstWhere((o) => o.parentId == null, orElse: () => objects.first).id;

    return Prefab(
      name: parsed['name'] is String ? parsed['name']! as String : 'Prefab',
      rootId: rootId,
      objects: objects,
    );
  }

  /// Fresh objects ready to go into a scene, linked back to this prefab.
  ///
  /// New ids every time and parent links remapped alongside, so two instances
  /// of the same prefab are two things rather than one thing counted twice.
  ({List<SceneObject> objects, String rootId}) instantiate({
    required String Function() nextId,
    required String source,
    String? parentId,
    Vector3? at,
    String? name,
  }) {
    final remap = <String, String>{for (final o in objects) o.id: nextId()};

    final made = [
      for (final original in objects)
        original.copyAs(
          id: remap[original.id]!,
          parentId: original.parentId == null
              ? parentId
              : remap[original.parentId],
        )..prefab = source,
    ];

    final rootKey = remap[rootId]!;
    final root = made.firstWhere((o) => o.id == rootKey);
    if (at != null) root.position.setFrom(at);
    if (name != null) root.name = name;

    return (objects: made, rootId: rootKey);
  }

  /// This prefab's objects laid over an instance already in a scene.
  ///
  /// What a revert produces, and what applying to one prefab pushes out to
  /// every other instance of it. The instance keeps two things it is entitled
  /// to keep — where it stands and what it is called — because those are what
  /// make it *this* lamp post rather than the lamp post. Everything else comes
  /// from the asset.
  ///
  /// Children are matched to the prefab's by walking both trees in the same
  /// order, so ids survive a revert wherever the shape has not changed and the
  /// selection is not lost under somebody's cursor.
  ({List<SceneObject> objects, String rootId}) resyncing(
    EditorScene scene,
    String instanceId, {
    required String Function() nextId,
    required String source,
  }) {
    final instance = scene[instanceId];
    if (instance == null) {
      throw SceneError('That instance is not in this scene.');
    }

    // Prefab id -> the id in the scene to reuse, where there is one.
    final keep = <String, String>{rootId: instanceId};
    _match(scene, instanceId, rootId, keep);

    final remap = <String, String>{
      for (final o in objects) o.id: keep[o.id] ?? nextId(),
    };

    final made = [
      for (final original in objects)
        original.copyAs(
          id: remap[original.id]!,
          parentId: original.parentId == null
              ? instance.parentId
              : remap[original.parentId],
        )..prefab = source,
    ];

    final root = made.firstWhere((o) => o.id == instanceId);
    root.position.setFrom(instance.position);
    root.name = instance.name;

    return (objects: made, rootId: instanceId);
  }

  /// Pairs a prefab's children with a scene subtree's, by order.
  void _match(
    EditorScene scene,
    String sceneParent,
    String prefabParent,
    Map<String, String> keep,
  ) {
    final mine = [for (final o in objects) if (o.parentId == prefabParent) o];
    final theirs = scene.childrenOf(sceneParent);

    for (var i = 0; i < mine.length && i < theirs.length; i++) {
      keep[mine[i].id] = theirs[i].id;
      _match(scene, theirs[i].id, mine[i].id, keep);
    }
  }
}
