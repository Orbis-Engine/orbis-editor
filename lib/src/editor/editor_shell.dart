import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  late final EditorScene _scene = EditorScene.starter();
  late final History _history = History(_scene);
  late final AssetTree _assets = AssetTree(widget.project.directory);

  String? _selected = 'cube';
  bool _playing = false;

  /// How tall the project browser is, dragged by the bar above it.
  double _browserHeight = 190;

  static const _minimumBrowserHeight = 120.0;

  @override
  void initState() {
    super.initState();
    // One listener rather than a callback threaded through every panel: an
    // edit made anywhere redraws everything that reads the scene.
    _history.addListener(_onChanged);
  }

  @override
  void dispose() {
    _history
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

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
                  onPlay: () => setState(() => _playing = !_playing),
                  onClose: widget.onClose,
                  onAdd: _add,
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
                                selected: _selected,
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
    required this.onPlay,
    required this.onClose,
    required this.onAdd,
  });

  final Project project;
  final bool playing;
  final History history;
  final VoidCallback onPlay;
  final VoidCallback onClose;
  final ValueChanged<ObjectKind> onAdd;

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
  const _StatusBar({required this.objects, required this.message});

  final int objects;
  final String message;

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
