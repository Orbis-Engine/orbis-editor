import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/orbis_theme.dart';
import 'scene.dart';
import 'workspace.dart';

/// Where a dragged row would land if it were dropped now.
enum DropKind {
  /// Above the row it is over, as a sibling.
  before,

  /// Inside it, as a child.
  inside,

  /// Below it, as a sibling.
  after,
}

/// Where something is being dropped.
typedef Drop = ({String sceneId, String? parentId, int index});

/// One row of the flattened tree. A null [object] is a scene's own row.
typedef OutlinerRow = ({
  SceneEntry entry,
  SceneObject? object,
  int depth,
  bool hasChildren,
});

/// What is in the open scenes, as a tree.
///
/// Each scene is a root with its objects under it, so several can be worked on
/// at once and it is always clear which one a thing belongs to — the question
/// that a flat list of objects from two files cannot answer.
class Outliner extends StatefulWidget {
  const Outliner({
    super.key,
    required this.workspace,
    required this.selected,
    required this.primary,
    required this.onSelect,
    required this.onSelectScene,
    required this.onLoadScene,
    required this.onMove,
    required this.onDelete,
    required this.onCloseScene,
  });

  final Workspace workspace;

  /// The selected objects. Empty when a scene itself is selected.
  final Set<String> selected;

  /// The one the inspector shows, and the anchor a shift-click ranges from.
  final String? primary;

  /// [additive] toggles one in or out; [range] takes everything between the
  /// anchor and this row.
  final void Function(String id, {bool additive, bool range}) onSelect;

  /// Selecting a scene's row, which shows what it is without opening it.
  final ValueChanged<SceneEntry> onSelectScene;

  /// Loading a scene, which unloads whatever was loaded before.
  final ValueChanged<SceneEntry> onLoadScene;

  /// Called with what is being moved and where it should land.
  final void Function(String id, Drop drop) onMove;

  final ValueChanged<String> onDelete;
  final ValueChanged<SceneEntry> onCloseScene;

  @override
  State<Outliner> createState() => _OutlinerState();
}

class _OutlinerState extends State<Outliner> {
  /// Collapsed rather than expanded, so the set is empty for a fresh scene and
  /// a newly added object is visible rather than hidden inside a closed parent.
  final Set<String> _collapsed = {};

  /// Which scene's row is highlighted, which is not the same as which is
  /// loaded — a scene can be looked at before it is opened.
  String? _selectedScene;

  /// Rows in draw order, skipping anything inside a collapsed parent.
  List<OutlinerRow> get _rows {
    final rows = <OutlinerRow>[];

    for (final entry in widget.workspace.entries) {
      final scene = entry.scene;
      rows.add((
        entry: entry,
        object: null,
        depth: 0,
        hasChildren: scene != null && scene.roots.isNotEmpty,
      ));

      // An unloaded scene has no objects to show. Listing children it does not
      // hold would suggest they could be edited, and they cannot.
      if (scene == null || _collapsed.contains(entry.id)) continue;

      void walk(List<SceneObject> objects, int depth) {
        for (final object in objects) {
          final children = scene.childrenOf(object.id);
          rows.add((
            entry: entry,
            object: object,
            depth: depth,
            hasChildren: children.isNotEmpty,
          ));
          if (!_collapsed.contains(object.id)) walk(children, depth + 1);
        }
      }

      walk(scene.roots, 1);
    }

    return rows;
  }

  void _toggle(String key) => setState(() {
        if (!_collapsed.remove(key)) _collapsed.add(key);
      });

  /// Turns a drop on a row into a place in the tree.
  Drop _placeFor(OutlinerRow row, DropKind kind) {
    final object = row.object;
    final scene = row.entry.scene!;

    // Onto a scene's own row: into that scene, at the top level.
    if (object == null) {
      return (
        sceneId: row.entry.id,
        parentId: null,
        index: kind == DropKind.before ? 0 : scene.roots.length,
      );
    }

    if (kind == DropKind.inside) {
      return (
        sceneId: row.entry.id,
        parentId: object.id,
        index: scene.childrenOf(object.id).length,
      );
    }

    final at = scene.indexOf(object.id);
    return (
      sceneId: row.entry.id,
      parentId: object.parentId,
      index: kind == DropKind.before ? at : at + 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;

    return Container(
      width: 248,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.only(left: Space.md, right: Space.sm),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Row(
              children: [
                Text('HIERARCHY', style: OrbisText.section),
                const Spacer(),
                Text(
                  '${widget.workspace.entries.length} '
                  'scene${widget.workspace.entries.length == 1 ? '' : 's'}',
                  style: OrbisText.mono.copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                final key = row.object?.id ?? row.entry.id;

                return _Row(
                  key: ValueKey('${row.entry.id}/$key'),
                  row: row,
                  workspace: widget.workspace,
                  selected: row.object == null
                      ? widget.selected.isEmpty &&
                          _selectedScene == row.entry.id
                      : widget.selected.contains(row.object!.id),
                  primary: row.object?.id == widget.primary,
                  collapsed: _collapsed.contains(key),
                  onTap: () {
                    if (row.object != null) {
                      final keys = HardwareKeyboard.instance.logicalKeysPressed;
                      widget.onSelect(
                        row.object!.id,
                        additive: keys.contains(LogicalKeyboardKey.metaLeft) ||
                            keys.contains(LogicalKeyboardKey.metaRight) ||
                            keys.contains(LogicalKeyboardKey.controlLeft) ||
                            keys.contains(LogicalKeyboardKey.controlRight),
                        range: keys.contains(LogicalKeyboardKey.shiftLeft) ||
                            keys.contains(LogicalKeyboardKey.shiftRight),
                      );
                      return;
                    }
                    setState(() => _selectedScene = row.entry.id);
                    widget.onSelectScene(row.entry);
                  },
                  onDoubleTap: row.object == null
                      ? () => widget.onLoadScene(row.entry)
                      : null,
                  onToggle: () => _toggle(key),
                  onDrop: (id, kind) =>
                      widget.onMove(id, _placeFor(row, kind)),
                  onDelete: () => row.object == null
                      ? widget.onCloseScene(row.entry)
                      : widget.onDelete(row.object!.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.row,
    required this.workspace,
    required this.selected,
    required this.primary,
    required this.collapsed,
    required this.onTap,
    required this.onDoubleTap,
    required this.onToggle,
    required this.onDrop,
    required this.onDelete,
  });

  final OutlinerRow row;
  final Workspace workspace;
  final bool selected;

  /// The one of several the inspector is showing.
  final bool primary;

  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback onToggle;
  final void Function(String id, DropKind kind) onDrop;
  final VoidCallback onDelete;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovering = false;
  DropKind? _dropping;

  static const double _height = 26;

  bool get _isScene => widget.row.object == null;

  bool get _isLoaded => widget.row.entry.isLoaded;

  /// Which of the three the pointer is over.
  ///
  /// The edges reorder and the middle reparents, which is how every tree that
  /// does both distinguishes them — and the reason the bands are a quarter
  /// each rather than a third is that reparenting is the commoner intent and
  /// deserves the bigger target.
  DropKind _kindFor(Offset local) {
    if (_isScene) return DropKind.inside;
    if (local.dy < _height * 0.25) return DropKind.before;
    if (local.dy > _height * 0.75) return DropKind.after;
    return DropKind.inside;
  }

  /// Whether this row would accept the thing being dragged.
  ///
  /// Refused before the drop rather than after: an editor that lets you drop
  /// and then shows an error has already made you do the work twice.
  bool _accepts(String id) {
    // Nothing can be dropped into a scene that is not loaded — there is no
    // document there to put it in.
    if (!_isLoaded) return false;

    final object = widget.row.object;
    if (object == null) return true;
    if (id == object.id) return false;

    final holder = widget.workspace.sceneHolding(id);
    if (holder == null || holder.id != widget.row.entry.id) return false;

    return !holder.scene!.isAncestorOf(id, object.id);
  }

  @override
  Widget build(BuildContext context) {
    final object = widget.row.object;
    final entry = widget.row.entry;
    final name = object?.name ?? entry.title;
    final icon = object?.icon
        ?? (_isLoaded ? Icons.public : Icons.public_off);

    final colour = widget.selected
        ? OrbisColors.ember
        // An unloaded scene is dimmer, because it is a place rather than a
        // thing you can currently change.
        : (_isScene && !_isLoaded
            ? OrbisColors.inkDim
            : (_hovering ? OrbisColors.ink : OrbisColors.inkMid));

    final row = DragTarget<String>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final kind = _kindFor(box.globalToLocal(details.offset));
        if (kind != _dropping) setState(() => _dropping = kind);
      },
      onLeave: (_) => setState(() => _dropping = null),
      onAcceptWithDetails: (details) {
        final kind = _dropping ?? DropKind.inside;
        setState(() => _dropping = null);
        widget.onDrop(details.data, kind);
      },
      builder: (context, candidate, _) {
        final dropping = candidate.isEmpty ? null : _dropping;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          // The disclosure arrow sits outside the tap area rather than inside
          // it. A double-tap handler above the arrow makes every single tap on
          // it wait for the double-tap timeout, which is a real lag on the
          // commonest thing anybody does in a tree.
          child: Container(
              height: _height,
              padding: EdgeInsets.only(
                left: Space.xs + widget.row.depth * 13.0,
                right: Space.xs,
              ),
              decoration: BoxDecoration(
                color: widget.selected
                    ? OrbisColors.emberWash
                    : (dropping == DropKind.inside
                        ? OrbisColors.raised
                        : (_hovering
                            ? OrbisColors.raised
                            : Colors.transparent)),
                // A line for a reorder, a fill for a reparent: the two answers
                // look different because they are different.
                border: Border(
                  top: BorderSide(
                    color: dropping == DropKind.before
                        ? OrbisColors.ember
                        : Colors.transparent,
                    width: 2,
                  ),
                  bottom: BorderSide(
                    color: dropping == DropKind.after
                        ? OrbisColors.ember
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: widget.row.hasChildren
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onToggle,
                            child: Icon(
                              widget.collapsed
                                  ? Icons.chevron_right
                                  : Icons.expand_more,
                              size: 15,
                              color: OrbisColors.inkDim,
                            ),
                          )
                        : null,
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onTap,
                      onDoubleTap: widget.onDoubleTap,
                      child: Row(
                        children: [
                          Icon(icon, size: 14, color: colour),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: OrbisText.label.copyWith(
                                color: colour,
                                fontWeight: _isScene || widget.selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          // A quiet mark on the one of several whose fields
                          // the inspector is showing, so a multiple selection
                          // does not look like it lost track of itself.
                          if (widget.primary && widget.selected)
                            Padding(
                              padding: const EdgeInsets.only(left: Space.xs),
                              child: Icon(
                                Icons.edit_outlined,
                                size: 11,
                                color: OrbisColors.ember,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_isScene && !_isLoaded && !_hovering)
                    Text(
                      'not loaded',
                      style: OrbisText.caption.copyWith(fontSize: 10),
                    ),
                  if (_isScene && _isLoaded && entry.neverWritten)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text('•',
                          style: OrbisText.mono
                              .copyWith(color: OrbisColors.ember)),
                    ),
                  if (_hovering)
                    _RowAction(
                      icon: Icons.close,
                      tooltip: _isScene ? 'Close $name' : 'Delete $name',
                      onTap: widget.onDelete,
                    ),
                ],
              ),
            ),
        );
      },
    );

    // A scene's row is a drop target and a heading, not something to drag.
    if (_isScene) {
      return Tooltip(
        message: _isLoaded
            ? name
            : 'Double-click to load $name',
        waitDuration: const Duration(milliseconds: 700),
        child: row,
      );
    }

    return Draggable<String>(
      data: object!.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragLabel(name: name, icon: icon),
      child: row,
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(icon, size: 13, color: OrbisColors.inkDim),
        ),
      ),
    );
  }
}

/// What follows the pointer while a row is being dragged.
class _DragLabel extends StatelessWidget {
  const _DragLabel({required this.name, required this.icon});

  final String name;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          color: OrbisColors.raised,
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: OrbisColors.ember),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: OrbisColors.ember),
            const SizedBox(width: Space.sm),
            Text(name, style: OrbisText.label.copyWith(color: OrbisColors.ink)),
          ],
        ),
      ),
    );
  }
}
