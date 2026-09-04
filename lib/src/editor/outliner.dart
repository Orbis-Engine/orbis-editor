import 'package:flutter/material.dart';

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
  OpenScene open,
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
    required this.onSelect,
    required this.onSelectScene,
    required this.onMove,
    required this.onDelete,
    required this.onCloseScene,
  });

  final Workspace workspace;

  /// The selected object, or null when a scene itself is selected.
  final String? selected;

  final ValueChanged<String> onSelect;

  /// Selecting a scene's own row, which also makes it the active one.
  final ValueChanged<OpenScene> onSelectScene;

  /// Called with what is being moved and where it should land.
  final void Function(String id, Drop drop) onMove;

  final ValueChanged<String> onDelete;
  final ValueChanged<OpenScene> onCloseScene;

  @override
  State<Outliner> createState() => _OutlinerState();
}

class _OutlinerState extends State<Outliner> {
  /// Collapsed rather than expanded, so the set is empty for a fresh scene and
  /// a newly added object is visible rather than hidden inside a closed parent.
  final Set<String> _collapsed = {};

  /// Rows in draw order, skipping anything inside a collapsed parent.
  List<OutlinerRow> get _rows {
    final rows = <OutlinerRow>[];

    for (final open in widget.workspace.scenes) {
      rows.add((
        open: open,
        object: null,
        depth: 0,
        hasChildren: open.scene.roots.isNotEmpty,
      ));
      if (_collapsed.contains(open.id)) continue;

      void walk(List<SceneObject> objects, int depth) {
        for (final object in objects) {
          final children = open.scene.childrenOf(object.id);
          rows.add((
            open: open,
            object: object,
            depth: depth,
            hasChildren: children.isNotEmpty,
          ));
          if (!_collapsed.contains(object.id)) walk(children, depth + 1);
        }
      }

      walk(open.scene.roots, 1);
    }

    return rows;
  }

  void _toggle(String key) => setState(() {
        if (!_collapsed.remove(key)) _collapsed.add(key);
      });

  /// Turns a drop on a row into a place in the tree.
  Drop _placeFor(OutlinerRow row, DropKind kind) {
    final object = row.object;
    final scene = row.open.scene;

    // Onto a scene's own row: into that scene, at the top level.
    if (object == null) {
      return (
        sceneId: row.open.id,
        parentId: null,
        index: kind == DropKind.before ? 0 : scene.roots.length,
      );
    }

    if (kind == DropKind.inside) {
      return (
        sceneId: row.open.id,
        parentId: object.id,
        index: scene.childrenOf(object.id).length,
      );
    }

    final at = scene.indexOf(object.id);
    return (
      sceneId: row.open.id,
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
                  '${widget.workspace.scenes.length} '
                  'scene${widget.workspace.scenes.length == 1 ? '' : 's'}',
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
                final key = row.object?.id ?? row.open.id;

                return _Row(
                  key: ValueKey('${row.open.id}/$key'),
                  row: row,
                  workspace: widget.workspace,
                  selected: row.object == null
                      ? widget.selected == null &&
                          widget.workspace.active?.id == row.open.id
                      : row.object!.id == widget.selected,
                  collapsed: _collapsed.contains(key),
                  onTap: () => row.object == null
                      ? widget.onSelectScene(row.open)
                      : widget.onSelect(row.object!.id),
                  onToggle: () => _toggle(key),
                  onDrop: (id, kind) =>
                      widget.onMove(id, _placeFor(row, kind)),
                  onDelete: () => row.object == null
                      ? widget.onCloseScene(row.open)
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
    required this.collapsed,
    required this.onTap,
    required this.onToggle,
    required this.onDrop,
    required this.onDelete,
  });

  final OutlinerRow row;
  final Workspace workspace;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
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
    final object = widget.row.object;
    if (object == null) return true;
    if (id == object.id) return false;

    // Only within one scene: moving an object between scenes means moving its
    // whole subtree between two documents, which is a different operation and
    // not one to trigger by accident.
    final holder = widget.workspace.sceneHolding(id);
    if (holder == null || holder.id != widget.row.open.id) return false;

    return !holder.scene.isAncestorOf(id, object.id);
  }

  @override
  Widget build(BuildContext context) {
    final object = widget.row.object;
    final name = object?.name ?? widget.row.open.title;
    final icon = object?.icon ?? Icons.public;

    final colour = widget.selected
        ? OrbisColors.ember
        : (_hovering ? OrbisColors.ink : OrbisColors.inkMid);

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
          child: GestureDetector(
            onTap: widget.onTap,
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
                  if (_isScene && widget.row.open.neverWritten)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text('•',
                          style: OrbisText.mono
                              .copyWith(color: OrbisColors.ember)),
                    ),
                  if (_hovering)
                    _RowAction(
                      icon: _isScene ? Icons.close : Icons.close,
                      tooltip: _isScene ? 'Close $name' : 'Delete $name',
                      onTap: widget.onDelete,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    // A scene's row is a drop target and a heading, not something to drag.
    if (_isScene) return row;

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
