import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'history.dart';
import 'scene.dart';
import 'scene_document.dart';

/// A scene the editor knows about, loaded or not.
///
/// One scene is loaded at a time. The others are listed so they can be reached
/// without going hunting in the project browser, and hold nothing but where
/// they are — an unloaded scene is a name and a path, not a copy of a document
/// sitting in memory waiting to disagree with the file.
class SceneEntry {
  SceneEntry({
    required this.id,
    required this.name,
    this.path,
    this.scene,
    this.neverWritten = false,
  });

  final String id;

  /// What it is called in the tree.
  String name;

  /// The file it came from and goes back to. Null for one never written.
  String? path;

  /// The document, when it is loaded. Null otherwise.
  EditorScene? scene;

  /// Whether it has ever reached disk.
  bool neverWritten;

  /// The stamp the history had for it when it was last written.
  int savedStamp = 0;

  bool get isLoaded => scene != null;

  /// What to call it: its file, or its own name when it has none.
  ///
  /// The shared set keeps its name rather than taking its file's. It is not
  /// one of the scenes somebody is choosing between, and listing it as
  /// "shared" among "main" and "level2" reads as a scene that happens to be
  /// lower case rather than as the thing every scene has.
  String get title => path == null || id == sharedSceneId
      ? name
      : p.basenameWithoutExtension(path!);
}

/// What every scene in a project has in it.
const String sharedSceneId = 'shared';

/// What the shared set is written to, under the project.
const String sharedFileName = 'shared$sceneExtension';

/// The scenes the editor knows about, and the one being worked on.
class Workspace extends ChangeNotifier implements SceneHost {
  Workspace(this.projectDirectory);

  final String projectDirectory;

  final List<SceneEntry> _entries = [];
  String? _loadedId;

  /// The objects every scene has, whichever one is open.
  ///
  /// A scene of its own, held apart from the list rather than in it: it is
  /// never loaded, never closed and never one of the things somebody is
  /// choosing between. What makes it worth having is that everything else
  /// already works on scenes — a command names one, the outliner draws one,
  /// the inspector edits one — so the managers and the props that belong to
  /// the whole project need no machinery of their own.
  late final SceneEntry sharedEntry = SceneEntry(
    id: sharedSceneId,
    name: 'Shared',
    path: p.join(projectDirectory, sharedFileName),
    scene: EditorScene([], name: 'Shared'),
    neverWritten: true,
  );

  EditorScene get shared => sharedEntry.scene!;

  List<SceneEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  /// The scene being edited and drawn. Null when none is loaded.
  SceneEntry? get loaded => _loadedId == null ? null : this[_loadedId!];

  @override
  EditorScene? sceneFor(String sceneId) => this[sceneId]?.scene;

  SceneEntry? operator [](String sceneId) {
    if (sceneId == sharedSceneId) return sharedEntry;
    for (final entry in _entries) {
      if (entry.id == sceneId) return entry;
    }
    return null;
  }

  /// Which scene an object belongs to. Only a loaded scene has objects, and
  /// the shared set, which is always there.
  SceneEntry? sceneHolding(String objectId) {
    final open = loaded;
    if (open?.scene?.contains(objectId) ?? false) return open;
    if (shared.contains(objectId)) return sharedEntry;
    return null;
  }

  SceneEntry? entryFor(String path) {
    for (final entry in _entries) {
      final existing = entry.path;
      if (existing != null && p.equals(existing, path)) return entry;
    }
    return null;
  }

  void add(SceneEntry entry) {
    _entries.add(entry);
    if (entry.isLoaded) _loadedId = entry.id;
    notifyListeners();
  }

  /// Puts a document into an entry and makes it the loaded one.
  ///
  /// Whatever was loaded is emptied: only one scene's objects exist at a time,
  /// so there is never a question about which one an edit or a draw belongs to.
  void load(SceneEntry entry, EditorScene scene) {
    for (final other in _entries) {
      if (!identical(other, entry)) other.scene = null;
    }
    // The shared set is not one of the things being swapped out. It is what
    // both scenes have in common, and unloading it with the scene would make
    // it the opposite of shared.
    entry.scene = scene;
    _loadedId = entry.id;
    notifyListeners();
  }

  /// Empties an entry without forgetting that it exists.
  void unload(SceneEntry entry) {
    if (identical(entry, sharedEntry)) return;
    entry.scene = null;
    if (_loadedId == entry.id) _loadedId = null;
    notifyListeners();
  }

  void remove(String sceneId) {
    _entries.removeWhere((entry) => entry.id == sceneId);
    if (_loadedId == sceneId) _loadedId = null;
    notifyListeners();
  }

  /// A name nothing else in the list is using.
  String availableName(String base) {
    final taken = {for (final entry in _entries) entry.title};
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
