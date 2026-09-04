import 'scene.dart';

/// Objects taken out of a scene, waiting to go into one.
///
/// Detached copies rather than references. A scene can be unloaded between the
/// copy and the paste — that is the whole point of having this — so anything
/// pointing back at the original document would be pointing at nothing.
class SceneClipboard {
  final List<SceneObject> _objects = [];

  /// The ids that were roots of what was copied, in order.
  final List<String> _roots = [];

  bool get isEmpty => _objects.isEmpty;

  bool get isNotEmpty => _objects.isNotEmpty;

  /// What is on it, for a menu to say "Paste Crate" rather than just "Paste".
  String get description {
    if (_objects.isEmpty) return '';
    if (_roots.length == 1) {
      final root = _objects.firstWhere((o) => o.id == _roots.first);
      return root.name;
    }
    return '${_roots.length} objects';
  }

  /// Takes a copy of an object and everything under it.
  void take(EditorScene scene, String id) {
    final object = scene[id];
    if (object == null) return;

    _objects
      ..clear()
      ..add(object.copy()..parentId = null);
    _roots
      ..clear()
      ..add(object.id);

    for (final child in scene.descendantsOf(id)) {
      _objects.add(child.copy());
    }
  }

  /// Objects ready to be added to a scene, with fresh ids.
  ///
  /// New ids every time, so pasting twice gives two things rather than one
  /// thing that cannot decide which scene it is in. Parent links are remapped
  /// alongside, or a pasted child would point at the object it was copied from.
  ({List<SceneObject> objects, List<String> roots}) contents({
    required String Function() nextId,
    String? parentId,
  }) {
    final remap = <String, String>{for (final o in _objects) o.id: nextId()};

    final objects = [
      for (final original in _objects)
        original.copyAs(
          id: remap[original.id]!,
          parentId: original.parentId == null
              ? parentId
              : remap[original.parentId],
        ),
    ];

    return (
      objects: objects,
      roots: [for (final root in _roots) remap[root]!],
    );
  }

  void clear() {
    _objects.clear();
    _roots.clear();
  }
}
