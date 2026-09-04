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
  late EditorScene _scene;
  late History _history;
  late final AssetTree _assets = AssetTree(widget.project.directory);

  /// The file the scene came from, and goes back to. Null for a scene that has
  /// never been written.
  String? _scenePath;

  /// Whether this scene has ever reached disk.
  ///
  /// Separate from the history's own idea of dirty, which only knows about
  /// edits. A project opened with no scene file shows the starter scene, and
  /// that scene exists nowhere — closing would lose it, so it counts as
  /// unsaved even though nothing has been edited.
  bool _neverWritten = false;

  bool get _unsaved => _neverWritten || _history.isDirty;

  String? _selected;
  bool _playing = false;

  /// The viewport's camera, owned here so F can frame the selection from
  /// anywhere and so the outliner and viewport agree about what is in view.
  OrbitCamera _camera = OrbitCamera();

  /// How tall the project browser is, dragged by the bar above it.
  double _browserHeight = 190;

  static const _minimumBrowserHeight = 120.0;

  @override
  void initState() {
    super.initState();

    // Assigned directly rather than through _load, which disposes the history
    // it is replacing — there is not one yet.
    final opened = _read(_defaultScenePath(), quiet: true);
    _scene = opened.scene;
    _history = History(_scene)..addListener(_onChanged);
    _scenePath = opened.path;
    _neverWritten = opened.isNew;
    _selected = _scene.objects.isEmpty ? null : _scene.objects.last.id;

    if (opened.problems.isNotEmpty) {
      // After the first frame: there is no ScaffoldMessenger to talk to yet.
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
    _assets.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// Where a project's scene lives by default.
  String _defaultScenePath() =>
      p.join(widget.project.directory, 'scenes', 'main$sceneExtension');

  /// Reads a scene file without touching any state.
  ///
  /// A missing file is a fresh scene rather than an error, because a project
  /// that has never been saved is an ordinary thing to open.
  ({EditorScene scene, String? path, bool isNew, List<String> problems}) _read(
    String path, {
    bool quiet = false,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      return (
        scene: EditorScene.starter(),
        // Remembered anyway, so the first save writes where the project
        // expects its scene rather than asking.
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

  /// Opens a scene file in place of the one being edited.
  void _load(String path) {
    final opened = _read(path);

    // A file that could not be read at all leaves the current scene alone —
    // replacing it with an empty one would lose work to somebody's misclick.
    if (opened.path == null) {
      _report(opened.problems);
      return;
    }

    setState(() {
      _history
        ..removeListener(_onChanged)
        ..dispose();
      _scene = opened.scene;
      // One listener rather than a callback threaded through every panel: an
      // edit made anywhere redraws everything that reads the scene.
      _history = History(_scene)..addListener(_onChanged);
      _scenePath = opened.path;
      _neverWritten = opened.isNew;
      _selected =
          _scene.objects.isEmpty ? null : _scene.objects.last.id;
      _camera = OrbitCamera();
    });

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

  /// Writes the scene back to the file it came from.
  ///
  /// Synchronous on purpose. A scene file is small, and an awaited write leaves
  /// a gap between encoding the scene and recording that it was saved — an
  /// edit landing in that gap is not in the file, but the history would call
  /// itself clean.
  void _save() {
    final path = _scenePath;
    if (path == null) {
      // Nowhere to write yet, so Save becomes Save As rather than guessing.
      _saveAs();
      return;
    }
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        SceneDocument.encode(_scene, name: p.basenameWithoutExtension(path)),
      );
    } on FileSystemException catch (error) {
      _say('Could not save: ${error.message}');
      return;
    }

    setState(() {
      _scenePath = path;
      _neverWritten = false;
    });
    _history.markSaved();
    _say('Saved to ${_assets.relative(path)}');
  }

  /// Names meshes the renderer could not load.
  ///
  /// Said once per file rather than every frame: the scene is republished on
  /// every drag, and a failure would otherwise appear a hundred times while
  /// somebody moves the object it belongs to.
  final Set<String> _reportedMeshes = {};

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

  /// Writes the scene somewhere new, and edits it there from then on.
  Future<void> _saveAs() async {
    final name = await promptForName(
      context,
      title: 'Save scene as',
      initial: _scenePath == null
          ? 'main'
          : p.basenameWithoutExtension(_scenePath!),
      hint: 'Goes in scenes/, as $sceneExtension.',
      action: 'Save',
    );
    if (!mounted) return;

    final trimmed = name;
    if (trimmed == null || trimmed.isEmpty) return;
    if (trimmed.contains(p.separator)) {
      _say('A scene name cannot contain a path.');
      return;
    }

    final path = p.join(
      widget.project.directory,
      'scenes',
      trimmed.endsWith(sceneExtension) ? trimmed : '$trimmed$sceneExtension',
    );

    // Refused rather than merged: overwriting a scene somebody else authored
    // is not something to do on a name collision.
    if (File(path).existsSync() &&
        (_scenePath == null || !p.equals(path, _scenePath!))) {
      _say('There is already a scene called $trimmed.');
      return;
    }

    setState(() => _scenePath = path);
    _save();
  }

  /// Starts an empty scene, asking about the current one first.
  Future<void> _newScene() async {
    if (_unsaved && !await _confirmDiscard()) return;

    setState(() {
      _history
        ..removeListener(_onChanged)
        ..dispose();
      _scene = EditorScene.starter();
      _history = History(_scene)..addListener(_onChanged);
      // No path: the next save asks where it goes rather than overwriting
      // whatever was open before.
      _scenePath = null;
      _neverWritten = true;
      _selected = _scene.objects.isEmpty ? null : _scene.objects.last.id;
      _camera = OrbitCamera();
      _reportedMeshes.clear();
    });
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

  /// Frames whatever is selected, keeping the angle the camera is already at.
  void _frameSelection() {
    final id = _selected;
    if (id == null || !_scene.contains(id)) return;
    final bounds = _scene.boundsOf(id);
    setState(() {
      _camera = _camera.framing(
        centre: bounds.centre,
        radius: bounds.radius,
      );
    });
  }

  /// Puts an asset into the scene.
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

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: _uniqueName(p.basenameWithoutExtension(path)),
      kind: ObjectKind.mesh,
      meshAsset: _assets.relative(path),
    );

    _run(AddObject(object));
    setState(() => _selected = object.id);
  }

  /// Opens a scene file, asking first if the current one has changes.
  Future<void> _openScene(String path) async {
    if (_unsaved && !await _confirmDiscard()) return;
    _load(path);
  }

  Future<bool> _confirmDiscard() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Save changes first?', style: OrbisText.title),
        content: Text(
          'This scene has changes that have not been written to disk.',
          style: OrbisText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    // Cancel means stop; Save writes and continues; Discard carries on.
    if (answer == false) return false;
    if (answer == true) _save();
    return true;
  }

  /// Runs a command, and says so if the scene refuses it.
  void _run(EditorCommand command) {
    try {
      _history.run(command);
    } on SceneError catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          backgroundColor: OrbisColors.raised,
          behavior: SnackBarBehavior.floating,
          width: 380,
        ),
      );
    }
  }

  void _add(ObjectKind kind) {
    final name = _uniqueName(switch (kind) {
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
    final selected = _selected == null ? null : _scene[_selected!];
    final parent = selected == null
        ? null
        : (selected.kind == ObjectKind.group ? selected.id : selected.parentId);

    _run(AddObject(object, parentId: parent));
    setState(() => _selected = object.id);
  }

  /// A name nothing else in the scene is using.
  String _uniqueName(String base) {
    final taken = {for (final o in _scene.objects) o.name};
    if (!taken.contains(base)) return base;
    for (var i = 2;; i++) {
      final candidate = '$base $i';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  void _delete(String id) {
    final object = _scene[id];
    if (object == null) return;
    _run(DeleteObject(id: id, name: object.name));
    if (_selected == id || !_scene.contains(_selected ?? '')) {
      setState(() => _selected = null);
    }
  }

  void _reparent(String id, String? parentId) {
    final object = _scene[id];
    if (object == null || object.parentId == parentId) return;
    _run(Reparent(
      id: id,
      name: object.name,
      from: object.parentId,
      to: parentId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected == null ? null : _scene[_selected!];

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
          _UndoIntent: CallbackAction<_UndoIntent>(
            onInvoke: (_) => _history.undo(),
          ),
          _RedoIntent: CallbackAction<_RedoIntent>(
            onInvoke: (_) => _history.redo(),
          ),
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
                  dirty: _unsaved,
                  onPlay: () => setState(() => _playing = !_playing),
                  onClose: widget.onClose,
                  onAdd: _add,
                  onSave: _save,
                  onSaveAs: _saveAs,
                  onNewScene: _newScene,
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Outliner(
                        scene: _scene,
                        selected: _selected,
                        onSelect: (id) => setState(() => _selected = id),
                        onReparent: _reparent,
                        onDelete: _delete,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SceneViewport(
                                scene: _scene,
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
                                // Dragging up grows the browser, so the height
                                // moves against the pointer.
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
                        scene: _scene,
                        object: selected,
                        history: _history,
                      ),
                    ],
                  ),
                ),
                _StatusBar(
                  objects: _scene.length,
                  message: _history.undoLabel == null
                      ? 'Ready'
                      : 'Last change: ${_history.undoLabel}',
                  file: _scenePath == null
                      ? 'Unsaved scene'
                      : _assets.relative(_scenePath!),
                  dirty: _unsaved,
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
    required this.onNewScene,
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
            onTap: history.undo,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.redo,
            tooltip: history.redoLabel == null
                ? 'Nothing to redo'
                : 'Redo ${history.redoLabel}',
            active: false,
            enabled: history.canRedo,
            onTap: history.redo,
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
