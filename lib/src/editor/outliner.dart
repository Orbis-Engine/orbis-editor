import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';
import 'scene.dart';

/// One row of the flattened tree.
typedef OutlinerRow = ({SceneObject object, int depth, bool hasChildren});

/// What is in the scene, as a tree.
///
/// A tree rather than a list because the hierarchy is what a transform means:
/// somebody looking for why a crate moved needs to see the thing it hangs off.
class Outliner extends StatefulWidget {
  const Outliner({
    super.key,
    required this.scene,
    required this.selected,
    required this.onSelect,
    required this.onReparent,
    required this.onDelete,
  });

  final EditorScene scene;
  final String? selected;
  final ValueChanged<String> onSelect;

  /// Called with the object being moved and its new parent, null for a root.
  final void Function(String id, String? parentId) onReparent;

  final ValueChanged<String> onDelete;

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

    void walk(List<SceneObject> objects, int depth) {
      for (final object in objects) {
        final children = widget.scene.childrenOf(object.id);
        rows.add((
          object: object,
          depth: depth,
          hasChildren: children.isNotEmpty,
        ));
        if (!_collapsed.contains(object.id)) walk(children, depth + 1);
      }
    }

    walk(widget.scene.roots, 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;

    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Row(
              children: [
                Text('OUTLINER', style: OrbisText.section),
                const Spacer(),
                Text(
                  '${widget.scene.length}',
                  style: OrbisText.mono.copyWith(fontSize: 11),
                ),
                const SizedBox(width: Space.sm),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                // Under the rows: dropping in the empty space below the tree
                // moves something out to the top level, which is otherwise
                // only reachable by dragging onto nothing.
                Positioned.fill(
                  child: DragTarget<String>(
                    onWillAcceptWithDetails: (details) =>
                        widget.scene[details.data]?.parentId != null,
                    onAcceptWithDetails: (details) =>
                        widget.onReparent(details.data, null),
                    builder: (context, candidate, _) => ColoredBox(
                      color: candidate.isEmpty
                          ? Colors.transparent
                          : OrbisColors.emberWash,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return _Row(
                      key: ValueKey(row.object.id),
                      row: row,
                      scene: widget.scene,
                      selected: row.object.id == widget.selected,
                      collapsed: _collapsed.contains(row.object.id),
                      onTap: () => widget.onSelect(row.object.id),
                      onToggle: () => setState(() {
                        if (!_collapsed.remove(row.object.id)) {
                          _collapsed.add(row.object.id);
                        }
                      }),
                      onDropOn: (id) =>
                          widget.onReparent(id, row.object.id),
                      onDelete: () => widget.onDelete(row.object.id),
                    );
                  },
                ),
              ],
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
    required this.scene,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    required this.onToggle,
    required this.onDropOn,
    required this.onDelete,
  });

  final OutlinerRow row;
  final EditorScene scene;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final ValueChanged<String> onDropOn;
  final VoidCallback onDelete;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovering = false;

  /// Whether this row would accept the thing being dragged.
  ///
  /// Refused before the drop rather than after: an editor that lets you drop
  /// and then shows an error has already made you do the work twice.
  bool _accepts(String id) =>
      id != widget.row.object.id && !widget.scene.isAncestorOf(id, widget.row.object.id);

  @override
  Widget build(BuildContext context) {
    final object = widget.row.object;
    final colour = widget.selected
        ? OrbisColors.ember
        : (_hovering ? OrbisColors.ink : OrbisColors.inkMid);

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onAcceptWithDetails: (details) => widget.onDropOn(details.data),
      builder: (context, candidate, _) {
        final dropping = candidate.isNotEmpty;

        return Draggable<String>(
          data: object.id,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _DragLabel(name: object.name, icon: object.icon),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                height: 26,
                padding: EdgeInsets.only(
                  left: Space.xs + widget.row.depth * 13.0,
                  right: Space.xs,
                ),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? OrbisColors.emberWash
                      : (_hovering ? OrbisColors.raised : Colors.transparent),
                  border: dropping
                      ? const Border(
                          bottom: BorderSide(color: OrbisColors.ember, width: 2),
                        )
                      : null,
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
                    Icon(object.icon, size: 14, color: colour),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        object.name,
                        overflow: TextOverflow.ellipsis,
                        style: OrbisText.label.copyWith(
                          color: colour,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (_hovering)
                      _RowAction(
                        icon: Icons.close,
                        tooltip: 'Delete ${object.name}',
                        onTap: widget.onDelete,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
