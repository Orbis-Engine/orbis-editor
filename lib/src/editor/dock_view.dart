import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';
import 'dock.dart';

/// Builds the contents of one panel.
typedef PanelBuilder = Widget Function(BuildContext context, DockPanel panel);

/// The editor's panels, arranged as the layout says.
///
/// The layout is data and this draws it. Everything that changes the
/// arrangement — a tab dragged somewhere, a divider moved, a panel closed —
/// goes back out through [onChanged] as a whole new layout, so there is one
/// description of where things are rather than a widget tree that has drifted
/// from the file that was supposed to describe it.
class DockView extends StatelessWidget {
  const DockView({
    super.key,
    required this.layout,
    required this.panel,
    required this.onChanged,
  });

  final DockLayout layout;
  final PanelBuilder panel;
  final ValueChanged<DockLayout> onChanged;

  @override
  Widget build(BuildContext context) => _node(context, layout.root);

  Widget _node(BuildContext context, DockNode node) => switch (node) {
        DockGroup() => _DockGroupView(
            group: node,
            layout: layout,
            panel: panel,
            onChanged: onChanged,
          ),
        DockSplit() => _DockSplitView(
            split: node,
            layout: layout,
            child: _node,
            onChanged: onChanged,
          ),
      };
}

/// A row or a column of places, with a handle between each pair.
class _DockSplitView extends StatelessWidget {
  const _DockSplitView({
    required this.split,
    required this.layout,
    required this.child,
    required this.onChanged,
  });

  final DockSplit split;
  final DockLayout layout;
  final Widget Function(BuildContext, DockNode) child;
  final ValueChanged<DockLayout> onChanged;

  static const double _handle = 5;

  @override
  Widget build(BuildContext context) {
    final shares = split.shares;

    return LayoutBuilder(
      builder: (context, constraints) {
        final along = split.axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        // The handles take space out of the total before it is shared, or the
        // panels would add up to more than the room and overflow by exactly
        // the number of dividers.
        final room = (along - _handle * (split.children.length - 1))
            .clamp(0.0, double.infinity);

        final pieces = <Widget>[];
        for (var i = 0; i < split.children.length; i++) {
          pieces.add(SizedBox(
            width: split.axis == Axis.horizontal ? room * shares[i] : null,
            height: split.axis == Axis.vertical ? room * shares[i] : null,
            child: child(context, split.children[i]),
          ));

          if (i + 1 < split.children.length) {
            pieces.add(_Handle(
              axis: split.axis,
              locked: layout.locked,
              onDrag: (delta) {
                if (room <= 0) return;
                // The two either side share what they had between them, so
                // dragging one divider does not move every other panel.
                final pair = shares[i] + shares[i + 1];
                final moved = shares[i] + delta / room;
                onChanged(layout.resize(split.id, i, moved / pair));
              },
            ));
          }
        }

        return Flex(
          direction: split.axis,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: pieces,
        );
      },
    );
  }
}

/// The bar between two panels.
class _Handle extends StatefulWidget {
  const _Handle({
    required this.axis,
    required this.locked,
    required this.onDrag,
  });

  final Axis axis;
  final bool locked;
  final ValueChanged<double> onDrag;

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hovering || _dragging;

    final bar = SizedBox(
      width: widget.axis == Axis.horizontal ? _DockSplitView._handle : null,
      height: widget.axis == Axis.vertical ? _DockSplitView._handle : null,
      child: ColoredBox(
        color: lit && !widget.locked ? OrbisColors.ember : OrbisColors.ground,
      ),
    );

    // A locked layout still draws the divider — it is the line between two
    // panels either way — but it does not offer to move.
    if (widget.locked) return bar;

    return MouseRegion(
      cursor: widget.axis == Axis.horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.axis == Axis.horizontal
            ? (_) => setState(() => _dragging = true)
            : null,
        onHorizontalDragUpdate: widget.axis == Axis.horizontal
            ? (details) => widget.onDrag(details.delta.dx)
            : null,
        onHorizontalDragEnd: widget.axis == Axis.horizontal
            ? (_) => setState(() => _dragging = false)
            : null,
        onVerticalDragStart: widget.axis == Axis.vertical
            ? (_) => setState(() => _dragging = true)
            : null,
        onVerticalDragUpdate: widget.axis == Axis.vertical
            ? (details) => widget.onDrag(details.delta.dy)
            : null,
        onVerticalDragEnd: widget.axis == Axis.vertical
            ? (_) => setState(() => _dragging = false)
            : null,
        child: bar,
      ),
    );
  }
}

/// Panels sharing a space, with the tabs above them.
class _DockGroupView extends StatefulWidget {
  const _DockGroupView({
    required this.group,
    required this.layout,
    required this.panel,
    required this.onChanged,
  });

  final DockGroup group;
  final DockLayout layout;
  final PanelBuilder panel;
  final ValueChanged<DockLayout> onChanged;

  @override
  State<_DockGroupView> createState() => _DockGroupViewState();
}

class _DockGroupViewState extends State<_DockGroupView> {
  /// Which edge the thing being dragged would land on.
  DockSide? _over;

  /// Which side of this group a point is nearest.
  ///
  /// The middle is a wide target on purpose: dropping a tab beside another one
  /// is the common thing, and a centre so small that every drop makes a new
  /// split is a layout somebody has to keep tidying up.
  static DockSide _sideFor(Offset local, Size size) {
    final x = local.dx / (size.width == 0 ? 1 : size.width);
    final y = local.dy / (size.height == 0 ? 1 : size.height);

    const edge = 0.25;
    final nearest = [
      (DockSide.left, x),
      (DockSide.right, 1 - x),
      (DockSide.top, y),
      (DockSide.bottom, 1 - y),
    ].reduce((a, b) => a.$2 <= b.$2 ? a : b);

    return nearest.$2 < edge ? nearest.$1 : DockSide.centre;
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final showing = group.current;

    final body = Container(
      decoration: const BoxDecoration(color: OrbisColors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Tabs(
            group: group,
            layout: widget.layout,
            onChanged: widget.onChanged,
          ),
          Expanded(
            child: showing == null
                ? const SizedBox.shrink()
                // A boundary a panel, so a panel that did not change is not
                // painted again because a different one did. Every edit
                // rebuilds the editor from the top — a drag does it sixty
                // times a second — and without these that is a repaint of the
                // whole window each time.
                : RepaintBoundary(
                    child: ClipRect(child: widget.panel(context, showing)),
                  ),
          ),
        ],
      ),
    );

    if (widget.layout.locked) return body;

    return DragTarget<PanelDrag>(
      onWillAcceptWithDetails: (details) => !widget.layout.locked,
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final side = _sideFor(box.globalToLocal(details.offset), box.size);
        if (side != _over) setState(() => _over = side);
      },
      onLeave: (_) => setState(() => _over = null),
      onAcceptWithDetails: (details) {
        final side = _over ?? DockSide.centre;
        setState(() => _over = null);
        widget.onChanged(
          widget.layout.dock(details.data.id, group.id, side),
        );
      },
      builder: (context, candidate, _) => Stack(
        children: [
          Positioned.fill(child: body),
          // Where it would land, drawn as the shape it would take rather than
          // as an arrow: a quarter of the panel highlighted says "here, this
          // size" without anybody having to learn what the arrow meant.
          if (candidate.isNotEmpty && _over != null)
            Positioned.fill(
              child: IgnorePointer(
                child: _DropHint(side: _over!),
              ),
            ),
        ],
      ),
    );
  }
}

/// The shape a dropped panel would take.
class _DropHint extends StatelessWidget {
  const _DropHint({required this.side});

  final DockSide side;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        final rect = switch (side) {
          DockSide.left => Rect.fromLTWH(0, 0, width * 0.34, height),
          DockSide.right =>
            Rect.fromLTWH(width * 0.66, 0, width * 0.34, height),
          DockSide.top => Rect.fromLTWH(0, 0, width, height * 0.34),
          DockSide.bottom =>
            Rect.fromLTWH(0, height * 0.66, width, height * 0.34),
          DockSide.centre => Rect.fromLTWH(0, 0, width, height),
        };

        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: OrbisColors.emberWash,
                  border: Border.all(color: OrbisColors.ember, width: 2),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The tabs above a group.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.group,
    required this.layout,
    required this.onChanged,
  });

  final DockGroup group;
  final DockLayout layout;
  final ValueChanged<DockLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < group.panels.length; i++)
            _PanelTab(
              panel: group.panels[i],
              selected: i == group.showing,
              locked: layout.locked,
              onTap: () => onChanged(layout.show(group.panels[i].id)),
              onClose: () => onChanged(layout.close(group.panels[i].id)),
            ),
        ],
      ),
    );
  }
}

class _PanelTab extends StatefulWidget {
  const _PanelTab({
    required this.panel,
    required this.selected,
    required this.locked,
    required this.onTap,
    required this.onClose,
  });

  final DockPanel panel;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_PanelTab> createState() => _PanelTabState();
}

class _PanelTabState extends State<_PanelTab> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    final colour = widget.selected
        ? OrbisColors.ink
        : (_hovering ? OrbisColors.inkMid : OrbisColors.inkDim);

    final tab = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          decoration: BoxDecoration(
            color: widget.selected ? OrbisColors.ground : Colors.transparent,
            border: Border(
              top: BorderSide(
                color: widget.selected ? OrbisColors.ember : Colors.transparent,
                width: 2,
              ),
              right: const BorderSide(color: OrbisColors.lineSoft),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(panel.kind.icon, size: 13, color: colour),
              const SizedBox(width: Space.sm),
              Text(
                panel.label.toUpperCase(),
                style: OrbisText.section.copyWith(color: colour),
              ),
              // Only under the cursor, so a row of tabs is a row of names
              // rather than a row of names and crosses.
              if (_hovering && !widget.locked) ...[
                const SizedBox(width: Space.sm),
                GestureDetector(
                  onTap: widget.onClose,
                  child: const Icon(Icons.close, size: 12,
                      color: OrbisColors.inkDim),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.locked) return tab;

    return Draggable<PanelDrag>(
      data: PanelDrag(panel),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragLabel(panel: panel),
      childWhenDragging: Opacity(opacity: 0.4, child: tab),
      child: tab,
    );
  }
}

/// What follows the pointer while a tab is dragged.
class _DragLabel extends StatelessWidget {
  const _DragLabel({required this.panel});

  final DockPanel panel;

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
            Icon(panel.kind.icon, size: 13, color: OrbisColors.ember),
            const SizedBox(width: Space.sm),
            Text(
              panel.label,
              style: OrbisText.label.copyWith(color: OrbisColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}
