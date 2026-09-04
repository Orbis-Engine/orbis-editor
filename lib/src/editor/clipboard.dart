import 'dart:convert';

import 'package:vector_math/vector_math_64.dart';

import 'scene.dart';
import 'scene_document.dart';

/// What a copied object needs to land where it was.
typedef ClipboardContents = ({
  List<SceneObject> objects,
  List<String> roots,
  Map<String, Matrix4> worlds,
});

/// Objects taken out of a scene, waiting to go into one.
///
/// Detached copies rather than references. A scene can be unloaded between the
/// copy and the paste — that is the whole point of having this — so anything
/// pointing back at the original document would be pointing at nothing.
class SceneClipboard {
  final List<SceneObject> _objects = [];

  /// The ids that were tops of what was copied, in order.
  final List<String> _roots = [];

  /// Where each top sat in the world when it was copied, so it can be put back
  /// there under a different parent.
  final Map<String, Matrix4> _worlds = {};

  bool get isEmpty => _objects.isEmpty;

  bool get isNotEmpty => _objects.isNotEmpty;

  /// What is on it, for a menu to say "Paste Crate" rather than just "Paste".
  String get description {
    if (_objects.isEmpty) return '';
    if (_roots.length == 1) {
      return _objects.firstWhere((o) => o.id == _roots.first).name;
    }
    return '${_roots.length} objects';
  }

  /// Takes a copy of each object and everything under it.
  ///
  /// Anything already inside something else being copied is left out. Copying
  /// a parent and its child together would otherwise paste the child twice —
  /// once as itself and once inside its parent.
  void take(EditorScene scene, Iterable<String> ids) {
    clear();

    final wanted = ids.where(scene.contains).toList();
    final tops = [
      for (final id in wanted)
        if (!wanted.any((other) => other != id && scene.isAncestorOf(other, id)))
          id,
    ];

    for (final id in tops) {
      final object = scene[id]!;
      _roots.add(id);
      _worlds[id] = scene.worldOf(id).clone();
      _objects.add(object.copy()..parentId = null);
      for (final child in scene.descendantsOf(id)) {
        _objects.add(child.copy());
      }
    }
  }

  /// Objects ready to be added to a scene, with fresh ids.
  ///
  /// New ids every time, so pasting twice gives two things rather than one
  /// thing that cannot decide which scene it is in. Parent links are remapped
  /// alongside, or a pasted child would point at the object it was copied from.
  ClipboardContents contents({
    required String Function() nextId,
    String? parentId,
  }) {
    final remap = <String, String>{for (final o in _objects) o.id: nextId()};

    return (
      objects: [
        for (final original in _objects)
          original.copyAs(
            id: remap[original.id]!,
            parentId: original.parentId == null
                ? parentId
                : remap[original.parentId],
          ),
      ],
      roots: [for (final root in _roots) remap[root]!],
      worlds: {
        for (final entry in _worlds.entries)
          remap[entry.key]!: entry.value.clone(),
      },
    );
  }

  void clear() {
    _objects.clear();
    _roots.clear();
    _worlds.clear();
  }

  // ---- the system clipboard ----

  /// What marks text as Orbis objects rather than any other JSON.
  static const String _marker = 'orbis.objects';

  /// The clipboard as text, for the system clipboard.
  ///
  /// The same encoding a scene file uses, so what lands in a text editor is
  /// readable and could be pasted back — rather than an opaque blob that only
  /// this build understands.
  String toText() => const JsonEncoder.withIndent('  ').convert({
        'kind': _marker,
        'formatVersion': SceneDocument.formatVersion,
        'roots': _roots,
        'worlds': {
          for (final entry in _worlds.entries)
            entry.key: entry.value.storage.toList(),
        },
        'objects': [for (final o in _objects) SceneDocument.objectToJson(o)],
      });

  /// Reads objects out of text, or leaves the clipboard alone.
  ///
  /// Returns whether it was Orbis objects. Anything else on the system
  /// clipboard — a path, a paragraph, JSON meaning something else — is not an
  /// error, it is simply not ours.
  bool takeText(String? text) {
    if (text == null || !text.contains(_marker)) return false;

    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return false;
    }
    if (parsed is! Map<String, Object?> || parsed['kind'] != _marker) {
      return false;
    }

    final raw = parsed['objects'];
    final roots = parsed['roots'];
    if (raw is! List || roots is! List) return false;

    final objects = <SceneObject>[];
    for (final entry in raw) {
      if (entry is! Map<String, Object?>) continue;
      final object = SceneDocument.objectFromJson(entry);
      if (object != null) objects.add(object);
    }
    if (objects.isEmpty) return false;

    clear();
    _objects.addAll(objects);
    _roots.addAll(roots.whereType<String>());

    final worlds = parsed['worlds'];
    if (worlds is Map<String, Object?>) {
      for (final entry in worlds.entries) {
        final values = entry.value;
        if (values is! List || values.length != 16) continue;
        _worlds[entry.key] = Matrix4.fromList(
          [for (final v in values) (v as num).toDouble()],
        );
      }
    }

    // A root naming an object that is not here would paste nothing.
    _roots.removeWhere((id) => !_objects.any((o) => o.id == id));
    if (_roots.isEmpty) {
      clear();
      return false;
    }
    return true;
  }
}
