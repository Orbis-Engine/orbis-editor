import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../launcher/project.dart';
import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'asset_browser.dart';
import 'assets.dart';
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

  @override
  void initState() {
    super.initState();
    _history.addListener(_onChanged);
    _workspace.addListener(_onChanged);

    final opened = _read(_defaultScenePath(), quiet: true);
    _workspace.add(OpenScene(
      id: 'scene${_nextSceneId++}',
      scene: opened.scene,
      path: opened.path,
      neverWritten: opened.isNew,
    ));
    _selected = null;

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

  /// The scene an edit goes into: the one holding the selection, or the active
  /// one when nothing is selected.
  OpenScene? get _current {
    final id = _selected;
    if (id != null) {
      final holder = _workspace.sceneHolding(id);
      if (holder != null) return holder;
    }
    return _workspace.active;
  }

  /// Whether a scene has changes that are not on disk.
  bool _isUnsaved(OpenScene open) =>
      open.neverWritten || _history.stampFor(open.id) != open.savedStamp;

  bool get _anyUnsaved => _workspace.scenes.any(_isUnsaved);

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

  /// Opens a scene alongside the ones already open.
  ///
  /// Added rather than replacing: several scenes open at once is the point of
  /// the hierarchy showing them as roots, and a file already open is brought
  /// forward rather than loaded twice.
  void _openScene(String path) {
    final already = _workspace.openedFrom(path);
    if (already != null) {
      setState(() {
        _workspace.active = already;
        _selected = null;
      });
      _say('${already.title} is already open.');
      return;
    }

    final opened = _read(path);
    if (opened.path == null) {
      _report(opened.problems);
      return;
    }

    _workspace.add(OpenScene(
      id: 'scene${_nextSceneId++}',
      scene: opened.scene,
      path: opened.path,
      neverWritten: opened.isNew,
    ));
    setState(() => _selected = null);
    _report(opened.problems);
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

  /// Writes one scene back to the file it came from.
  ///
  /// Synchronous on purpose. An awaited write leaves a gap between encoding
  /// the scene and recording that it was saved — an edit landing in that gap
  /// is not in the file, but the history would call itself clean.
  void _save([OpenScene? which]) {
    final open = which ?? _current;
    if (open == null) return;

    final path = open.path;
    if (path == null) {
      _saveAs(open);
      return;
    }

    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(SceneDocument.encode(open.scene));
    } on FileSystemException catch (error) {
      _say('Could not save ${open.title}: ${error.message}');
      return;
    }

    setState(() {
      open
        ..neverWritten = false
        ..savedStamp = _history.stampFor(open.id);
    });
    _say('Saved ${_assets.relative(path)}');
  }

  void _saveAll() {
    for (final open in _workspace.scenes) {
      if (_isUnsaved(open)) _save(open);
    }
  }

  Future<void> _saveAs([OpenScene? which]) async {
    final open = which ?? _current;
    if (open == null) return;

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

  /// Adds a new empty scene to the workspace.
  void _newScene() {
    final name = _workspace.availableName('Untitled');
    _workspace.add(OpenScene(
      id: 'scene${_nextSceneId++}',
      scene: EditorScene.starter()..name = name,
      neverWritten: true,
    ));
    setState(() => _selected = null);
  }

  /// Takes a scene out of the workspace, asking first if it has changes.
  Future<void> _closeScene(OpenScene open) async {
    if (_isUnsaved(open)) {
      final answer = await _confirmDiscard(open);
      if (answer == null) return;
      if (answer) _save(open);
    }

    // The steps belonging to it go too: undoing into a scene that is no longer
    // open would be a step that appears to do nothing.
    _history.forget(open.id);
    _workspace.remove(open.id);
    setState(() => _selected = null);
  }

  /// True to save, false to discard, null to stop.
  Future<bool?> _confirmDiscard(OpenScene open) async {
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Save ${open.title} first?', style: OrbisText.title),
        content: Text(
          'It has changes that have not been written to disk.',
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
    if (open == null) {
      _say('There is no scene open to add to.');
      return;
    }

    final name = _uniqueName(open.scene, switch (kind) {
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
    final selected = _selected == null ? null : open.scene[_selected!];
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
    final object = open?.scene[id];
    if (open == null || object == null) return;

    _run(DeleteObject(sceneId: open.id, id: id, name: object.name));
    if (_selected == id) setState(() => _selected = null);
  }

  /// Moves an object in the tree, by reparenting, reordering, or both.
  void _move(String id, Drop drop) {
    final open = _workspace.sceneHolding(id);
    final object = open?.scene[id];
    if (open == null || object == null) return;

    // Between scenes is a different operation — moving a subtree between two
    // documents — and not one to trigger by dragging.
    if (drop.sceneId != open.id) {
      _say('Objects cannot be dragged between scenes yet.');
      return;
    }

    final fromIndex = open.scene.indexOf(id);
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
    final open = _current;
    if (open == null) return;

    final bounds = id == null || !open.scene.contains(id)
        ? open.scene.boundsOfEverything()
        : open.scene.boundsOf(id);

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
    if (open == null) {
      _say('There is no scene open to add to.');
      return;
    }

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: _uniqueName(open.scene, p.basenameWithoutExtension(path)),
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
    final open = _workspace[sceneId];
    if (open == null) return;
    setState(() {
      _workspace.active = open;
      if (_selected != null && !open.scene.contains(_selected!)) {
        _selected = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _current;
    final selected =
        _selected == null ? null : open?.scene[_selected!];

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
                  onSaveAll: _saveAll,
                  onNewScene: _newScene,
                  onUndo: _undo,
                  onRedo: _redo,
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
                          final holder = _workspace.sceneHolding(id);
                          if (holder != null) _workspace.active = holder;
                        }),
                        onSelectScene: (open) => setState(() {
                          _selected = null;
                          _workspace.active = open;
                        }),
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
                        open: open,
                        object: selected,
                        history: _history,
                      ),
                    ],
                  ),
                ),
                _StatusBar(
                  objects: _workspace.scenes
                      .fold(0, (total, open) => total + open.scene.length),
                  message: _history.undoLabel == null
                      ? 'Ready'
                      : 'Last change: ${_history.undoLabel}',
                  file: open == null
                      ? 'No scene'
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
    required this.onSaveAll,
    required this.onNewScene,
    required this.onUndo,
    required this.onRedo,
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
  final VoidCallback onSaveAll;
  final VoidCallback onNewScene;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

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
            onSaveAll: onSaveAll,
            onNewScene: onNewScene,
          ),
          const SizedBox(width: Space.xs),
          _AddMenu(onAdd: onAdd),
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
    required this.onSaveAll,
    required this.onNewScene,
  });

  final bool dirty;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback onSaveAll;
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
        MenuItemButton(
          onPressed: onSaveAll,
          leadingIcon: const Icon(Icons.done_all,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Save all', style: OrbisText.label),
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
