import 'package:flutter/material.dart';
import 'package:orbis_ui/orbis_ui.dart';

import '../theme/orbis_theme.dart';

/// An interface, shown the way it will be shown, with the design chrome over
/// the top.
///
/// The two halves of that sentence are the whole idea. What is underneath is
/// the same [UiSurface] a game builds, at the size the canvas was authored at,
/// so what somebody lays out is what ships. What is over the top — the canvas
/// bounds, the safe area, an outline on every element, a highlight on the
/// selected one — is drawn by a decorator that a game does not pass.
///
/// Not hidden in the game. Never built: [designing] false means no decorator,
/// and no decorator means the chrome is not code that ran and produced
/// nothing. That is the difference between a canvas you can work against and
/// one that turns up in a screenshot.
class UiCanvasView extends StatelessWidget {
  const UiCanvasView({
    super.key,
    required this.document,
    this.selected,
    this.hovered,
    this.designing = true,
    this.showOutlines = true,
    this.showGuides = true,
    this.onSelect,
    this.onHover,
    this.onMove,
    this.onMoved,
    this.onEvent,
  });

  final UiDocument document;

  /// The path of the element being edited, if any.
  final List<int>? selected;

  final List<int>? hovered;

  /// False to see exactly what the game sees.
  final bool designing;

  /// An outline on every element, so an empty box is a box rather than
  /// nothing. The selected one is always outlined whatever this says: taking
  /// away the one mark that answers "what am I editing" is not a view mode,
  /// it is a lost selection.
  final bool showOutlines;

  /// The canvas edge and the safe area.
  final bool showGuides;

  final ValueChanged<List<int>>? onSelect;
  final ValueChanged<List<int>?>? onHover;

  /// Called while an element is dragged, with where it should end up.
  ///
  /// Only for an element its parent does not place — one on a stack. In a
  /// column or a row the parent decides where things go, and moving one by
  /// hand would be a position the next layout throws away.
  final void Function(List<int> path, Offset to)? onMove;

  /// Called when a drag finishes, so a whole movement can be one undo step.
  final VoidCallback? onMoved;

  /// What happens when somebody presses something while previewing.
  final UiEvent? onEvent;

  /// Whether two paths name the same element.
  ///
  /// A list compared by identity is two lists that are never equal, and the
  /// selection is rebuilt on every change.
  static bool samePath(List<int>? a, List<int>? b) {
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final canvas = document.canvas;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The canvas is drawn at the size it was authored at and then scaled,
        // rather than laid out into whatever space there is. Otherwise the
        // editor would be showing a different interface from the game — one
        // that had reflowed to fit a panel.
        final room = Size(
          constraints.maxWidth - Space.xl * 2,
          constraints.maxHeight - Space.xl * 2,
        );
        final scale = canvas.fit == CanvasFit.none
            ? 1.0
            : canvas
                .copyWith(fit: CanvasFit.contain)
                .scaleFor(room.width, room.height)
                .clamp(0.05, 4.0);

        return ColoredBox(
          color: OrbisColors.ground,
          child: Center(
            child: SizedBox(
              width: canvas.width * scale,
              height: canvas.height * scale,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: canvas.width,
                  height: canvas.height,
                  child: _surface(canvas),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _surface(UiCanvas canvas) {
    final interface = UiSurface(
      description: document.root,
      onEvent: onEvent,
      decorate: designing ? _decorate : null,
    );

    if (!designing) return interface;

    return Stack(
      children: [
        // A ground under the interface, so an element with no background is
        // visible against something rather than against whatever the editor
        // happens to be painted in.
        const Positioned.fill(child: ColoredBox(color: Color(0xFF11141A))),
        Positioned.fill(child: interface),
        if (showGuides)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _Guides(canvas: canvas)),
            ),
          ),
      ],
    );
  }

  /// Whether this element is one its parent places, or one that places
  /// itself.
  bool _isFree(List<int> path) {
    if (path.isEmpty) return false;
    final parent = document.root.at(path.sublist(0, path.length - 1));
    return parent?.type == 'stack';
  }

  /// Wraps one element with what the editor needs and the game does not.
  Widget _decorate(UiNode node, List<int> path, Widget built) {
    final isSelected = samePath(selected, path);
    final isHovered = samePath(hovered, path);
    final free = onMove != null && _isFree(path);

    Widget wrapped = built;

    if (showOutlines || isSelected || isHovered) {
      wrapped = Stack(
        children: [
          wrapped,
          // Over the element rather than around it: a border in the layout
          // would move everything by a pixel and the canvas would stop being
          // what the game shows.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isSelected
                        ? OrbisColors.ember
                        : (isHovered
                            ? OrbisColors.ember.withValues(alpha: 0.5)
                            : OrbisColors.ember.withValues(alpha: 0.14)),
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return MouseRegion(
      cursor: free ? SystemMouseCursors.move : SystemMouseCursors.click,
      onEnter: (_) => onHover?.call(path),
      onExit: (_) => onHover?.call(null),
      child: GestureDetector(
        // Translucent so a click reaches every element under the pointer and
        // the innermost wins the arena, which is what selecting the thing you
        // clicked on means in a tree of nested boxes.
        behavior: HitTestBehavior.translucent,
        onTap: onSelect == null ? null : () => onSelect!(path),
        onPanStart: !free
            ? null
            : (_) {
                // Selected as the drag starts, so the panel is showing what
                // is being moved by the time it has moved.
                if (!isSelected) onSelect?.call(path);
              },
        onPanUpdate: !free
            ? null
            : (details) {
                final at = node.placed ?? (left: 0.0, top: 0.0);
                // Already in canvas units. The gesture arrives through the
                // FittedBox that scales the canvas to the panel, and Flutter
                // hands a recognizer the delta in the coordinates of whatever
                // won the hit test — so the element follows the pointer at any
                // zoom, and dividing by the zoom here would move it twice.
                onMove!(
                  path,
                  Offset(
                    at.left + details.delta.dx,
                    at.top + details.delta.dy,
                  ),
                );
              },
        onPanEnd: !free ? null : (_) => onMoved?.call(),
        onPanCancel: !free ? null : () => onMoved?.call(),
        child: wrapped,
      ),
    );
  }
}

/// The canvas edge and the safe area, drawn over everything.
class _Guides extends CustomPainter {
  const _Guides({required this.canvas});

  final UiCanvas canvas;

  @override
  void paint(Canvas paint, Size size) {
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = OrbisColors.ember.withValues(alpha: 0.65);
    paint.drawRect(Offset.zero & size, edge);

    if (canvas.safeArea <= 0) return;

    // A guide, not a clip. An interface that deliberately bleeds to the edge
    // should be able to; this is here to say where a television's overscan and
    // a phone's notch will eat what is under them.
    final inset = Rect.fromLTRB(
      size.width * canvas.safeArea,
      size.height * canvas.safeArea,
      size.width * (1 - canvas.safeArea),
      size.height * (1 - canvas.safeArea),
    );
    final safe = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrbisColors.good.withValues(alpha: 0.5);
    paint.drawRect(inset, safe);
  }

  @override
  bool shouldRepaint(_Guides old) => old.canvas.safeArea != canvas.safeArea;
}
