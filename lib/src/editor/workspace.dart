import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'history.dart';
import 'scene.dart';
import 'scene_document.dart';

/// One scene open in the editor.
///
/// A scene is a file, and several can be open at once — which is what makes
/// dragging something out of one and into another possible, and what lets a
/// level be split into pieces that load separately.
class OpenScene {
  OpenScene({
    required this.id,
    required this.scene,
    this.path,
    this.neverWritten = false,
  });

  final String id;
  final EditorScene scene;

  /// The file it came from and goes back to. Null for one never written.
  String? path;

  /// Whether it has ever reached disk.
  ///
  /// Separate from the history's idea of changed, which only knows about
  /// edits: a new scene has been edited zero times and still exists nowhere.
  bool neverWritten;

  /// The stamp the history had for this scene when it was last written.
  int savedStamp = 0;

  String get name => scene.name;

  /// What to call it in the tree: its file, or its own name if it has none.
  String get title =>
      path == null ? scene.name : p.basenameWithoutExtension(path!);
}

/// Every scene open at once, and which one new work goes into.
class Workspace extends ChangeNotifier implements SceneHost {
  Workspace(this.projectDirectory);

  final String projectDirectory;

  final List<OpenScene> _scenes = [];
  String? _activeId;

  List<OpenScene> get scenes => List.unmodifiable(_scenes);

  bool get isEmpty => _scenes.isEmpty;

  @override
  EditorScene? sceneFor(String sceneId) {
    for (final open in _scenes) {
      if (open.id == sceneId) return open.scene;
    }
    return null;
  }

  OpenScene? operator [](String sceneId) {
    for (final open in _scenes) {
      if (open.id == sceneId) return open;
    }
    return null;
  }

  /// The scene a new object goes into, and whose sky lights the viewport.
  ///
  /// Filament renders one environment, so with several scenes open the sky has
  /// to come from somewhere — the active one, the same way a light setting
  /// belongs to whichever scene is being worked on.
  OpenScene? get active => _activeId == null ? null : this[_activeId!];

  set active(OpenScene? open) {
    if (open == null || _activeId == open.id) return;
    _activeId = open.id;
    notifyListeners();
  }

  /// Which scene an object belongs to.
  OpenScene? sceneHolding(String objectId) {
    for (final open in _scenes) {
      if (open.scene.contains(objectId)) return open;
    }
    return null;
  }

  /// Whether a file is already open, so it is shown rather than opened twice.
  OpenScene? openedFrom(String path) {
    for (final open in _scenes) {
      final existing = open.path;
      if (existing != null && p.equals(existing, path)) return open;
    }
    return null;
  }

  void add(OpenScene open, {bool makeActive = true}) {
    _scenes.add(open);
    if (makeActive || _activeId == null) _activeId = open.id;
    notifyListeners();
  }

  void remove(String sceneId) {
    _scenes.removeWhere((open) => open.id == sceneId);
    if (_activeId == sceneId) {
      _activeId = _scenes.isEmpty ? null : _scenes.last.id;
    }
    notifyListeners();
  }

  /// A scene name nothing else open is using, so two tabs are never the same.
  String availableName(String base) {
    final taken = {for (final open in _scenes) open.title};
    if (!taken.contains(base)) return base;
    for (var i = 2;; i++) {
      if (!taken.contains('$base $i')) return '$base $i';
    }
  }

  /// Where a scene of this name would be written.
  String pathFor(String name) => p.join(
        projectDirectory,
        'scenes',
        name.endsWith(sceneExtension) ? name : '$name$sceneExtension',
      );

  void touched() => notifyListeners();
}
