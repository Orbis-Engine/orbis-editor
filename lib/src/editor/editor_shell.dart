import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../launcher/project.dart';
import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'asset_browser.dart';
import 'assets.dart';
import 'clipboard.dart';
import 'commands.dart';
import 'history.dart';
import 'inspector.dart';
import 'outliner.dart';
import 'scene.dart';
import 'scene_document.dart';
import 'viewport.dart';
import 'workspace.dart';

/// The editor, once a project is open.
///
/// Regions rather than free-floating windows: a fixed rail, an outliner, the
/// viewport, an inspector and a status bar. Docking comes later, and it comes
/// more easily to a layout that already knows what its regions are.
class EditorShell extends StatefulWidget {
  const EditorShell({
    super.key,
    required this.project,
    required this.onClose,
  });

  final Project project;

  /// Back to the launcher.
  final VoidCallback onClose;

  @override
  State<EditorShell> createState() => _EditorShellState();
}

class _EditorShellState extends State<EditorShell> {
  late final Workspace _workspace = Workspace(widget.project.directory);
  late final History _history = History(_workspace);
  late final AssetTree _assets = AssetTree(widget.project.directory);

  /// The selected object, or null when the active scene itself is selected.
  String? _selected;

  bool _playing = false;
  OrbitCamera _camera = OrbitCamera();
  double _browserHeight = 190;

  static const _minimumBrowserHeight = 120.0;

  /// Meshes already complained about, so a failure is named once rather than
  /// on every frame of a drag.
  final Set<String> _reportedMeshes = {};

  int _nextSceneId = 0;

  /// Survives a scene being unloaded, which is what makes moving something
  /// from one scene to another possible at all.
  final SceneClipboard _clipboard = SceneClipboard();

  @override
  void initState() {
    super.initState();
    _history.addListener(_onChanged);
    _workspace.addListener(_onChanged);

    final opened = _read(_defaultScenePath(), quiet: true);
    _workspace.add(SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: opened.scene.name,
      scene: opened.scene,
      path: opened.path,
      neverWritten: opened.isNew,
    ));
    _selected = null;

    // Every other scene in the project is listed but not loaded, so they can
    // be reached without going hunting for them.
    _listSiblingScenes();

    if (opened.problems.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _report(opened.problems),
      );
    }
  }

  @override
  void dispose() {
    _history
      ..removeListener(_onChanged)
      ..dispose();
    _workspace
      ..removeListener(_onChanged)
      ..dispose();
    _assets.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  String _defaultScenePath() =>
      p.join(widget.project.directory, 'scenes', 'main$sceneExtension');

  /// The scene an edit goes into. Only one is loaded, so there is only one.
  SceneEntry? get _current => _workspace.loaded;

  /// The scene whose settings the inspector shows: the loaded one, or one
  /// somebody has clicked to look at without opening.
  SceneEntry? get _inspected =>
      _selectedScene == null ? _workspace.loaded : _workspace[_selectedScene!];

  String? _selectedScene;

  /// Whether a scene has changes that are not on disk.
  bool _isUnsaved(SceneEntry entry) =>
      entry.isLoaded &&
      (entry.neverWritten || _history.stampFor(entry.id) != entry.savedStamp);

  bool get _anyUnsaved => _workspace.entries.any(_isUnsaved);

  /// Lists the project's other scenes without loading them.
  void _listSiblingScenes() {
    final folder = Directory(p.join(widget.project.directory, 'scenes'));
    if (!folder.existsSync()) return;

    for (final file in folder.listSync().whereType<File>()) {
      if (p.extension(file.path) != sceneExtension) continue;
      if (_workspace.entryFor(file.path) != null) continue;
      _workspace.add(SceneEntry(
        id: 'scene${_nextSceneId++}',
        name: p.basenameWithoutExtension(file.path),
        path: file.path,
      ));
    }
  }

  void _run(EditorCommand command) {
    try {
      _history.run(command);
    } on SceneError catch (error) {
      _say(error.message);
    }
  }

  /// Reads a scene file without touching any state.
  ({EditorScene scene, String? path, bool isNew, List<String> problems}) _read(
    String path, {
    bool quiet = false,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      return (
        scene: EditorScene.starter(),
        path: path,
        isNew: true,
        problems: quiet ? const <String>[] : ['There is no scene at $path.'],
      );
    }

    try {
      final load = SceneDocument.decode(file.readAsStringSync());
      return (
        scene: load.scene,
        path: path,
        isNew: false,
        problems: load.problems,
      );
    } on SceneFormatException catch (error) {
      return (
        scene: EditorScene.starter(),
        path: null,
        isNew: false,
        problems: [error.message],
      );
    } on FileSystemException catch (error) {
      return (
        scene: EditorScene.starter(),
        path: null,
        isNew: false,
        problems: ['Could not read that scene: ${error.message}'],
      );
    }
  }

  /// Loads a scene, replacing whatever was loaded.
  ///
  /// One at a time, so the viewport shows one document and there is never a
  /// question about which scene an edit belongs to. What was loaded is put
  /// back to being a name and a path — and if it had unsaved changes, that is
  /// asked about first, because unloading is the moment the work would be
  /// lost.
  Future<void> _loadScene(SceneEntry entry) async {
    if (entry.isLoaded) return;

    final leaving = _workspace.loaded;
    if (leaving != null && _isUnsaved(leaving)) {
      final answer = await _confirmLeaving(leaving);
      if (answer == null) return;
      if (answer) {
        _save(leaving);
        // Refused or failed, so the change is still only in memory.
        if (_isUnsaved(leaving)) return;
      }
    }

    final path = entry.path;
    if (path == null) {
      _say('${entry.title} has never been saved, so there is nothing to load.');
      return;
    }

    final opened = _read(path);
    if (opened.path == null) {
      _report(opened.problems);
      return;
    }

    if (leaving != null) {
      // Its steps go with it: undoing into a scene that is not loaded would be
      // a step that appears to do nothing.
      _history.forget(leaving.id);
      _workspace.unload(leaving);
    }

    _workspace.load(entry, opened.scene);
    entry
      ..name = opened.scene.name
      ..neverWritten = false
      ..savedStamp = _history.stampFor(entry.id);

    setState(() {
      _selected = null;
      _selectedScene = null;
      _camera = OrbitCamera();
      _reportedMeshes.clear();
    });
    _report(opened.problems);
  }

  /// Lists a scene file and loads it.
  Future<void> _openScene(String path) async {
    final existing = _workspace.entryFor(path);
    if (existing != null) {
      await _loadScene(existing);
      return;
    }

    final entry = SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: p.basenameWithoutExtension(path),
      path: path,
    );
    _workspace.add(entry);
    await _loadScene(entry);
  }

  void _report(List<String> problems) {
    if (problems.isEmpty) return;
    _say(
      problems.length == 1
          ? problems.single
          : '${problems.length} things in that scene could not be read. '
              'First: ${problems.first}',
    );
  }

  /// Writes the loaded scene back to the file it came from.
  ///
  /// Synchronous on purpose. An awaited write leaves a gap between encoding
  /// the scene and recording that it was saved — an edit landing in that gap
  /// is not in the file, but the history would call itself clean.
  void _save([SceneEntry? which]) {
    final entry = which ?? _current;
    final scene = entry?.scene;
    if (entry == null || scene == null) return;

    final path = entry.path;
    if (path == null) {
      _saveAs(entry);
      return;
    }

    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(SceneDocument.encode(scene));
    } on FileSystemException catch (error) {
      _say('Could not save ${entry.title}: ${error.message}');
      return;
    }

    setState(() {
      entry
        ..neverWritten = false
        ..savedStamp = _history.stampFor(entry.id);
    });
    _say('Saved ${_assets.relative(path)}');
  }

  Future<void> _saveAs([SceneEntry? which]) async {
    final open = which ?? _current;
    if (open == null || !open.isLoaded) return;

    final name = await promptForName(
      context,
      title: 'Save scene as',
      initial: open.title,
      hint: 'Goes in scenes/, as $sceneExtension.',
      action: 'Save',
    );
    if (!mounted || name == null || name.isEmpty) return;

    if (name.contains(p.separator)) {
      _say('A scene name cannot contain a path.');
      return;
    }

    final path = _workspace.pathFor(name);
    if (File(path).existsSync() &&
        (open.path == null || !p.equals(path, open.path!))) {
      _say('There is already a scene called $name.');
      return;
    }

    setState(() => open.path = path);
    _save(open);
  }

  /// Starts a new scene, replacing whatever is loaded.
  Future<void> _newScene() async {
    final leaving = _workspace.loaded;
    if (leaving != null && _isUnsaved(leaving)) {
      final answer = await _confirmLeaving(leaving);
      if (answer == null) return;
      if (answer) {
        _save(leaving);
        if (_isUnsaved(leaving)) return;
      }
    }

    if (leaving != null) {
      _history.forget(leaving.id);
      _workspace.unload(leaving);
    }

    final name = _workspace.availableName('Untitled');
    final entry = SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: name,
      neverWritten: true,
    );
    _workspace
      ..add(entry)
      ..load(entry, EditorScene.starter()..name = name);

    setState(() {
      _selected = null;
      _selectedScene = null;
      _camera = OrbitCamera();
    });
  }

  /// Takes a scene off the list, asking first if it has changes.
  Future<void> _closeScene(SceneEntry entry) async {
    if (_isUnsaved(entry)) {
      final answer = await _confirmLeaving(entry);
      if (answer == null) return;
      if (answer) {
        _save(entry);
        if (_isUnsaved(entry)) return;
      }
    }

    _history.forget(entry.id);
    _workspace.remove(entry.id);
    setState(() {
      _selected = null;
      if (_selectedScene == entry.id) _selectedScene = null;
    });
  }

  /// True to save, false to discard, null to stop.
  ///
  /// Asked whenever a scene with changes is about to stop being loaded —
  /// which is the only moment the work could be lost, and so the only moment
  /// worth interrupting for.
  Future<bool?> _confirmLeaving(SceneEntry open) async {
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Save ${open.title} first?', style: OrbisText.title),
        content: Text(
          open.path == null
              ? 'It has never been written to disk. Closing it loses it.'
              : 'It has changes that have not been written to disk.',
          style: OrbisText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (answer == 'save') return true;
    if (answer == 'discard') return false;
    return null;
  }

  void _add(ObjectKind kind) {
    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.');
      return;
    }

    final name = _uniqueName(scene, switch (kind) {
      ObjectKind.mesh => 'Cube',
      ObjectKind.light => 'Light',
      ObjectKind.camera => 'Camera',
      ObjectKind.group => 'Group',
      ObjectKind.scene => 'Scene',
    });

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      kind: kind,
      colour: kind == ObjectKind.light
          ? const Color(0xFFFFF3E0)
          : const Color(0xFFD9634F),
    );

    // Added inside whatever is selected when that can hold things, which is
    // what somebody building a hierarchy means by "add" most of the time.
    final selected = _selected == null ? null : scene[_selected!];
    final parent = selected == null
        ? null
        : (selected.kind == ObjectKind.group ? selected.id : selected.parentId);

    _run(AddObject(object, sceneId: open.id, parentId: parent));
    setState(() => _selected = object.id);
  }

  String _uniqueName(EditorScene scene, String base) {
    final taken = {for (final o in scene.objects) o.name};
    if (!taken.contains(base)) return base;
    for (var i = 2;; i++) {
      if (!taken.contains('$base $i')) return '$base $i';
    }
  }

  void _delete(String id) {
    final open = _workspace.sceneHolding(id);
    final object = open?.scene?[id];
    if (open == null || object == null) return;

    _run(DeleteObject(sceneId: open.id, id: id, name: object.name));
    if (_selected == id) setState(() => _selected = null);
  }

  /// Moves an object in the tree, by reparenting, reordering, or both.
  void _move(String id, Drop drop) {
    final open = _workspace.sceneHolding(id);
    final scene = open?.scene;
    final object = scene?[id];
    if (open == null || scene == null || object == null) return;
    if (drop.sceneId != open.id) return;

    final fromIndex = scene.indexOf(id);
    var toIndex = drop.index;
    // Removing it first shifts everything after it down by one, so an index
    // taken from the tree as drawn is one too many when moving down.
    if (object.parentId == drop.parentId && fromIndex < toIndex) toIndex -= 1;
    if (object.parentId == drop.parentId && fromIndex == toIndex) return;

    _run(MoveObject(
      sceneId: open.id,
      id: id,
      name: object.name,
      from: object.parentId,
      to: drop.parentId,
      fromIndex: fromIndex,
      toIndex: toIndex,
    ));
  }

  /// Puts the selection on the clipboard.
  void _copy() {
    final id = _selected;
    final scene = _current?.scene;
    if (id == null || scene == null) return;

    _clipboard.take(scene, id);
    setState(() {});
    _say('Copied ${_clipboard.description}.');
  }

  /// Copies the selection and then removes it.
  void _cut() {
    final id = _selected;
    final scene = _current?.scene;
    final object = id == null ? null : scene?[id];
    if (id == null || scene == null || object == null) return;

    // Copied before it is deleted, since the delete is what makes it
    // unreachable.
    _clipboard.take(scene, id);
    _delete(id);
    setState(() {});
  }

  /// Puts the clipboard into the loaded scene.
  ///
  /// Beside whatever is selected rather than inside it, which is what somebody
  /// pressing paste usually means — pasting into the thing you were looking at
  /// buries it one level down.
  void _paste() {
    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null || _clipboard.isEmpty) return;

    final beside = _selected == null ? null : scene[_selected!];
    final content = _clipboard.contents(
      nextId: _nextObjectId,
      parentId: beside?.parentId,
    );

    // Named for what it was, so the undo entry reads as the thing somebody
    // did rather than as a count.
    _run(PasteObjects(
      sceneId: open.id,
      objects: content.objects,
      roots: content.roots,
      what: _clipboard.description,
    ));

    setState(() => _selected = content.roots.firstOrNull);
  }

  /// Copies the selection and pastes it straight back.
  void _duplicate() {
    final id = _selected;
    final open = _current;
    final scene = open?.scene;
    if (id == null || open == null || scene == null) return;

    // On its own clipboard, so duplicating does not throw away what somebody
    // had copied earlier.
    final taken = SceneClipboard()..take(scene, id);
    final content = taken.contents(
      nextId: _nextObjectId,
      parentId: scene[id]?.parentId,
    );

    _run(PasteObjects(
      sceneId: open.id,
      objects: content.objects,
      roots: content.roots,
      what: taken.description,
    ));

    setState(() => _selected = content.roots.firstOrNull);
  }

  String _nextObjectId() =>
      'o${DateTime.now().microsecondsSinceEpoch}_${_nextObject++}';

  int _nextObject = 0;

  void _reportMeshErrors(Map<String, String> errors) {
    final fresh = [
      for (final entry in errors.entries)
        if (_reportedMeshes.add(entry.key)) entry,
    ];
    if (fresh.isEmpty) return;

    final first = fresh.first;
    _say(fresh.length == 1
        ? '${p.basename(first.key)}: ${first.value}'
        : '${fresh.length} meshes could not be loaded. '
            '${p.basename(first.key)}: ${first.value}');
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: OrbisColors.raised,
        behavior: SnackBarBehavior.floating,
        width: 460,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _frameSelection() {
    final id = _selected;
    final scene = _current?.scene;
    if (scene == null) return;

    final bounds = id == null || !scene.contains(id)
        ? scene.boundsOfEverything()
        : scene.boundsOf(id);

    setState(() {
      _camera = _camera.framing(
        centre: bounds.centre,
        radius: bounds.radius,
      );
    });
  }

  void _dropAsset(String path) {
    final kind = AssetKind.of(path);

    if (kind == AssetKind.scene) {
      _openScene(path);
      return;
    }
    if (kind != AssetKind.mesh) {
      _say('${p.basename(path)} is a ${kind.label.toLowerCase()}. '
          'Only meshes and scenes can be dropped into a scene so far.');
      return;
    }

    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.');
      return;
    }

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: _uniqueName(scene, p.basenameWithoutExtension(path)),
      kind: ObjectKind.mesh,
      meshAsset: _assets.relative(path),
    );

    _run(AddObject(object, sceneId: open.id));
    setState(() => _selected = object.id);
  }

  /// Undo, then show what it changed, so a step in another scene is not
  /// invisible.
  void _undo() {
    final sceneId = _history.undoSceneId;
    _history.undo();
    _reveal(sceneId);
  }

  void _redo() {
    final sceneId = _history.redoSceneId;
    _history.redo();
    _reveal(sceneId);
  }

  void _reveal(String? sceneId) {
    if (sceneId == null) return;
    final scene = _workspace[sceneId]?.scene;
    if (scene == null) return;
    setState(() {
      if (_selected != null && !scene.contains(_selected!)) _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _current;
    final selected =
        _selected == null ? null : open?.scene?[_selected!];

    return Shortcuts(
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            _RedoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyY, control: true): _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
        const SingleActivator(LogicalKeyboardKey.backspace): _DeleteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF): _FrameIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            _SaveIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _SaveIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
            _SaveAsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _NewSceneIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            _CopyIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true):
            _CutIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _PasteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            _DuplicateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _CopyIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, control: true):
            _CutIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            _DuplicateIntent(),
      },
      child: Actions(
        actions: {
          _UndoIntent: CallbackAction<_UndoIntent>(onInvoke: (_) => _undo()),
          _RedoIntent: CallbackAction<_RedoIntent>(onInvoke: (_) => _redo()),
          _DeleteIntent: CallbackAction<_DeleteIntent>(
            onInvoke: (_) {
              final id = _selected;
              if (id != null) _delete(id);
              return null;
            },
          ),
          _FrameIntent: CallbackAction<_FrameIntent>(
            onInvoke: (_) {
              _frameSelection();
              return null;
            },
          ),
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              _save();
              return null;
            },
          ),
          _SaveAsIntent: CallbackAction<_SaveAsIntent>(
            onInvoke: (_) {
              _saveAs();
              return null;
            },
          ),
          _NewSceneIntent: CallbackAction<_NewSceneIntent>(
            onInvoke: (_) {
              _newScene();
              return null;
            },
          ),
          _CopyIntent: CallbackAction<_CopyIntent>(onInvoke: (_) => _copy()),
          _CutIntent: CallbackAction<_CutIntent>(onInvoke: (_) => _cut()),
          _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) => _paste()),
          _DuplicateIntent:
              CallbackAction<_DuplicateIntent>(onInvoke: (_) => _duplicate()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: OrbisColors.ground,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  project: widget.project,
                  playing: _playing,
                  history: _history,
                  dirty: _anyUnsaved,
                  onPlay: () => setState(() => _playing = !_playing),
                  onClose: widget.onClose,
                  onAdd: _add,
                  onSave: _save,
                  onSaveAs: _saveAs,
                  onNewScene: () => _newScene(),
                  onUndo: _undo,
                  onRedo: _redo,
                  hasSelection: _selected != null,
                  clipboard: _clipboard.description,
                  onCopy: _copy,
                  onCut: _cut,
                  onPaste: _paste,
                  onDuplicate: _duplicate,
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Outliner(
                        workspace: _workspace,
                        selected: _selected,
                        onSelect: (id) => setState(() {
                          _selected = id;
                          _selectedScene = null;
                        }),
                        onSelectScene: (entry) => setState(() {
                          _selected = null;
                          _selectedScene = entry.id;
                        }),
                        onLoadScene: _loadScene,
                        onMove: _move,
                        onDelete: _delete,
                        onCloseScene: _closeScene,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SceneViewport(
                                workspace: _workspace,
                                camera: _camera,
                                onCameraChanged: (camera) =>
                                    setState(() => _camera = camera),
                                selected: _selected,
                                onDropAsset: _dropAsset,
                                projectRoot: widget.project.directory,
                                onMeshErrors: _reportMeshErrors,
                              ),
                            ),
                            _Splitter(
                              onDrag: (delta) => setState(() {
                                _browserHeight = (_browserHeight - delta).clamp(
                                  _minimumBrowserHeight,
                                  MediaQuery.sizeOf(context).height - 320,
                                );
                              }),
                            ),
                            AssetBrowser(
                              tree: _assets,
                              height: _browserHeight,
                              onOpenAsset: (asset) {
                                if (asset.kind == AssetKind.scene) {
                                  _openScene(asset.path);
                                }
                              },
                              onProblem: _say,
                            ),
                          ],
                        ),
                      ),
                      Inspector(
                        entry: _inspected,
                        object: selected,
                        history: _history,
                        onLoad: _loadScene,
                      ),
                    ],
                  ),
                ),
                _StatusBar(
                  objects: open?.scene?.length ?? 0,
                  message: _history.undoLabel == null
                      ? 'Ready'
                      : 'Last change: ${_history.undoLabel}',
                  file: open == null
                      ? 'No scene loaded'
                      : (open.path == null
                          ? '${open.title} (unsaved)'
                          : _assets.relative(open.path!)),
                  dirty: open != null && _isUnsaved(open),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UndoIntent extends Intent {}

class _RedoIntent extends Intent {}

class _DeleteIntent extends Intent {}

class _FrameIntent extends Intent {}

class _SaveIntent extends Intent {}

class _SaveAsIntent extends Intent {}

class _NewSceneIntent extends Intent {}

class _CopyIntent extends Intent {}

class _CutIntent extends Intent {}

class _PasteIntent extends Intent {}

class _DuplicateIntent extends Intent {}

/// The bar between the viewport and the project browser.
class _Splitter extends StatefulWidget {
  const _Splitter({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onVerticalDragUpdate: (details) => widget.onDrag(details.delta.dy),
        child: Container(
          height: 6,
          color: _hovering ? OrbisColors.line : Colors.transparent,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.project,
    required this.playing,
    required this.history,
    required this.dirty,
    required this.onPlay,
    required this.onClose,
    required this.onAdd,
    required this.onSave,
    required this.onSaveAs,
    required this.onNewScene,
    required this.onUndo,
    required this.onRedo,
    required this.hasSelection,
    required this.clipboard,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onDuplicate,
  });

  final Project project;
  final bool playing;
  final History history;
  final bool dirty;
  final VoidCallback onPlay;
  final VoidCallback onClose;
  final ValueChanged<ObjectKind> onAdd;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;

  final VoidCallback onNewScene;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool hasSelection;

  /// What is on the clipboard, or empty for nothing.
  final String clipboard;

  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          OrbisButton(
            label: project.name,
            icon: Icons.chevron_left,
            tone: ButtonTone.quiet,
            onPressed: onClose,
          ),
          const SizedBox(width: Space.md),
          _SceneMenu(
            dirty: dirty,
            onSave: onSave,
            onSaveAs: onSaveAs,
            onNewScene: onNewScene,
          ),
          const SizedBox(width: Space.xs),
          _AddMenu(onAdd: onAdd),
          const SizedBox(width: Space.xs),
          _EditMenu(
            hasSelection: hasSelection,
            clipboard: clipboard,
            onCopy: onCopy,
            onCut: onCut,
            onPaste: onPaste,
            onDuplicate: onDuplicate,
          ),
          const SizedBox(width: Space.md),
          // Labelled with what they would undo, so the tooltip answers the
          // question somebody actually has before they press it.
          _TransportButton(
            icon: Icons.undo,
            tooltip: history.undoLabel == null
                ? 'Nothing to undo'
                : 'Undo ${history.undoLabel}',
            active: false,
            enabled: history.canUndo,
            onTap: onUndo,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.redo,
            tooltip: history.redoLabel == null
                ? 'Nothing to redo'
                : 'Redo ${history.redoLabel}',
            active: false,
            enabled: history.canRedo,
            onTap: onRedo,
          ),
          const Spacer(),
          // Transport in the centre, where it is in every editor that has one,
          // because muscle memory is worth more than novelty here.
          _TransportButton(
            icon: playing ? Icons.pause : Icons.play_arrow,
            tooltip: playing ? 'Pause' : 'Play',
            active: playing,
            onTap: onPlay,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.stop,
            tooltip: 'Stop',
            active: false,
            onTap: () {},
          ),
          const Spacer(),
          Text('pre-alpha', style: OrbisText.caption),
        ],
      ),
    );
  }
}

class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 32,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? OrbisColors.emberWash
                  : (_hovering && widget.enabled
                      ? OrbisColors.raised
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: !widget.enabled
                  ? OrbisColors.line
                  : (widget.active
                      ? OrbisColors.ember
                      : (_hovering ? OrbisColors.ink : OrbisColors.inkMid)),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.objects,
    required this.message,
    required this.file,
    required this.dirty,
  });

  final int objects;
  final String message;
  final String file;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(top: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          ),
          const Spacer(),
          Text(
            dirty ? '$file •' : file,
            style: OrbisText.mono.copyWith(
              fontSize: 11,
              color: dirty ? OrbisColors.ember : OrbisColors.inkDim,
            ),
          ),
          const SizedBox(width: Space.lg),
          Text('$objects objects', style: OrbisText.mono.copyWith(fontSize: 11)),
          const SizedBox(width: Space.lg),
          Text('— fps', style: OrbisText.mono.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

/// The Add menu.
class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.onAdd});

  final ValueChanged<ObjectKind> onAdd;

  static const _items = [
    (ObjectKind.mesh, 'Cube', Icons.view_in_ar_outlined),
    (ObjectKind.light, 'Light', Icons.wb_sunny_outlined),
    (ObjectKind.camera, 'Camera', Icons.videocam_outlined),
    (ObjectKind.group, 'Group', Icons.folder_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        for (final (kind, label, icon) in _items)
          MenuItemButton(
            onPressed: () => onAdd(kind),
            leadingIcon: Icon(icon, size: 14, color: OrbisColors.inkMid),
            child: Text(label, style: OrbisText.label),
          ),
      ],
      builder: (context, controller, child) => OrbisButton(
        label: 'Add',
        icon: Icons.add,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// New, Save and Save As.
class _SceneMenu extends StatelessWidget {
  const _SceneMenu({
    required this.dirty,
    required this.onSave,
    required this.onSaveAs,
    required this.onNewScene,
  });

  final bool dirty;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;

  final VoidCallback onNewScene;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: onNewScene,
          leadingIcon: const Icon(Icons.note_add_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('New scene', style: OrbisText.label),
        ),
        MenuItemButton(
          onPressed: onSave,
          leadingIcon: const Icon(Icons.save_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Save', style: OrbisText.label),
        ),
        MenuItemButton(
          onPressed: onSaveAs,
          leadingIcon: const Icon(Icons.drive_file_move_outline,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Save as…', style: OrbisText.label),
        ),
      ],
      builder: (context, controller, child) => OrbisButton(
        // The dot is the unsaved marker, in the place somebody looks for it.
        label: dirty ? 'Scene •' : 'Scene',
        icon: Icons.description_outlined,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Cut, copy, paste and duplicate.
///
/// Worth a menu rather than only shortcuts: copying between scenes is the
/// only way to move an object from one to another, and nobody discovers a
/// keystroke that is not written down anywhere.
class _EditMenu extends StatelessWidget {
  const _EditMenu({
    required this.hasSelection,
    required this.clipboard,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onDuplicate,
  });

  final bool hasSelection;
  final String clipboard;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        _item('Cut', '⌘X', Icons.content_cut, hasSelection ? onCut : null),
        _item('Copy', '⌘C', Icons.content_copy, hasSelection ? onCopy : null),
        _item(
          clipboard.isEmpty ? 'Paste' : 'Paste $clipboard',
          '⌘V',
          Icons.content_paste,
          clipboard.isEmpty ? null : onPaste,
        ),
        _item(
          'Duplicate',
          '⌘D',
          Icons.copy_all,
          hasSelection ? onDuplicate : null,
        ),
      ],
      builder: (context, controller, child) => OrbisButton(
        label: 'Edit',
        icon: Icons.content_copy,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _item(
    String label,
    String shortcut,
    IconData icon,
    VoidCallback? onPressed,
  ) {
    final enabled = onPressed != null;
    return MenuItemButton(
      onPressed: onPressed,
      leadingIcon: Icon(
        icon,
        size: 14,
        color: enabled ? OrbisColors.inkMid : OrbisColors.line,
      ),
      trailingIcon: Text(
        shortcut,
        style: OrbisText.mono.copyWith(
          fontSize: 11,
          color: enabled ? OrbisColors.inkDim : OrbisColors.line,
        ),
      ),
      child: Text(
        label,
        style: OrbisText.label.copyWith(
          color: enabled ? OrbisColors.ink : OrbisColors.line,
        ),
      ),
    );
  }
}
