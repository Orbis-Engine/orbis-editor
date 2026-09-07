import 'package:flutter/material.dart';
import 'package:orbis_ui/orbis_ui.dart';

import '../theme/orbis_theme.dart';

/// An interface, shown the way it will be shown, with the design chrome over
/// the top.
///
/// The two halves of that sentence are the whole idea. What is underneath is
/// the same [UiSurface] a game builds, at the size the interface will be laid
/// out at, so what somebody lays out is what ships. What is over the top — the
/// canvas bounds, the safe area, the column grid, an outline on every element,
/// a highlight on the selected one — is drawn by a decorator that a game does
/// not pass.
///
/// Not hidden in the game. Never built: [designing] false means no decorator,
/// and no decorator means the chrome is not code that ran and produced
/// nothing. That is the difference between a canvas you can work against and
/// one that turns up in a screenshot.
class UiCanvasView extends StatelessWidget {
  const UiCanvasView({
    super.key,
    required this.document,
    this.previewSize,
    this.selected,
    this.hovered,
    this.designing = true,
    this.showOutlines = true,
    this.showGuides = true,
    this.showColumns = false,
    this.onSelect,
    this.onHover,
    this.onMove,
    this.onMoved,
    this.onEvent,
  });

  final UiDocument document;

  /// The screen to show this on, when it is not the one it was drawn against.
  ///
  /// A responsive interface is a different layout at every width, so a canvas
  /// that could only be seen at its own reference size would be showing the
  /// one screen nobody was worried about. Null means the reference size.
  final Size? previewSize;

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

  /// The column grid, and with it the snapping.
  ///
  /// One flag for both on purpose: columns something can be dropped onto but
  /// not seen are a mystery, and columns that can be seen but not dropped onto
  /// are wallpaper.
  final bool showColumns;

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

  /// The screen a document is being shown on, in its own pixels.
  static Size screenFor(UiDocument document, Size? previewSize) =>
      previewSize ?? Size(document.canvas.width, document.canvas.height);

  /// The size the interface is actually laid out at.
  ///
  /// The screen, when the canvas is responsive: that is what responsive means,
  /// and it is why the breakpoints fire for the device somebody picked rather
  /// than for the panel the editor happens to be in. The reference size
  /// otherwise, because every other fit magnifies one layout rather than
  /// producing a second.
  ///
  /// Static because it is also the answer to "which prefixed classes are in
  /// effect", which the toolbar has to show without building a canvas.
  static Size layoutFor(UiDocument document, Size? previewSize) =>
      document.canvas.fit == CanvasFit.responsive
          ? screenFor(document, previewSize)
          : Size(document.canvas.width, document.canvas.height);

  Size screenSize() => screenFor(document, previewSize);

  Size layoutSize() => layoutFor(document, previewSize);

  @override
  Widget build(BuildContext context) {
    final canvas = document.canvas;
    final screen = screenSize();
    final laidOutAt = layoutSize();

    // How much of the screen the interface takes up: what the fit decides.
    // One for a responsive canvas, which fills it by being laid out at it.
    final inScreen = canvas
        .scaleFor(screen.width, screen.height)
        .clamp(0.05, 8.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The screen is drawn at its own size and then scaled to the panel,
        // rather than laid out into whatever space there is. Otherwise the
        // editor would be showing a different interface from the game — one
        // that had reflowed to fit a panel.
        final room = Size(
          constraints.maxWidth - Space.xl * 2,
          constraints.maxHeight - Space.xl * 2,
        );
        final zoom = _fitInto(screen, room);

        return ColoredBox(
          color: OrbisColors.ground,
          child: Center(
            child: SizedBox(
              width: screen.width * zoom,
              height: screen.height * zoom,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: screen.width,
                  height: screen.height,
                  // Clipped to the screen: an "actual size" canvas larger than
                  // the device is exactly the case somebody needs to see, and
                  // letting it spill past the bezel would hide the problem.
                  child: ClipRect(
                    child: Stack(
                      children: [
                        // Behind the interface and outside it: the bars a fit
                        // leaves. Darker than the canvas ground so they read
                        // as space the game will not draw in.
                        const Positioned.fill(
                          child: ColoredBox(color: Color(0xFF07090C)),
                        ),
                        Center(
                          child: SizedBox(
                            width: laidOutAt.width * inScreen,
                            height: laidOutAt.height * inScreen,
                            child: FittedBox(
                              fit: BoxFit.fill,
                              child: SizedBox(
                                width: laidOutAt.width,
                                height: laidOutAt.height,
                                child: _surface(canvas, laidOutAt),
                              ),
                            ),
                          ),
                        ),
                        if (designing && showGuides)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _Screen(
                                  showing: screen != laidOutAt ||
                                      inScreen != 1.0,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// How much to shrink [what] by to get it inside [room].
  static double _fitInto(Size what, Size room) {
    if (what.width <= 0 || what.height <= 0) return 1;
    if (room.width <= 0 || room.height <= 0) return 0.05;
    final byWidth = room.width / what.width;
    final byHeight = room.height / what.height;
    return (byWidth < byHeight ? byWidth : byHeight).clamp(0.05, 4.0);
  }

  Widget _surface(UiCanvas canvas, Size laidOutAt) {
    final interface = UiSurface(
      description: document.root,
      canvas: canvas,
      // The width the layout answers to is the one being drawn, not the one
      // the editor's panel happens to be. A phone previewed inside a wide
      // window has to be a phone the whole way down.
      width: laidOutAt.width,
      onEvent: onEvent,
      decorate: designing
          ? (node, path, built) => _decorate(node, path, built, laidOutAt)
          : null,
    );

    if (!designing) return interface;

    return Stack(
      children: [
        // A ground under the interface, so an element with no background is
        // visible against something rather than against whatever the editor
        // happens to be painted in.
        const Positioned.fill(child: ColoredBox(color: Color(0xFF11141A))),
        Positioned.fill(child: interface),
        if (showGuides || showColumns)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _Guides(
                  canvas: canvas,
                  edges: showGuides,
                  columns: showColumns,
                ),
              ),
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
  Widget _decorate(UiNode node, List<int> path, Widget built, Size laidOutAt) {
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
                // boxes that scale the canvas into the panel, and Flutter
                // hands a recognizer the delta in the coordinates of whatever
                // won the hit test — so the element follows the pointer at any
                // zoom, and dividing by the zoom here would move it twice.
                var left = at.left + details.delta.dx;

                // Pulled onto a column edge when the grid is up. Done here
                // rather than when the drag ends so somebody can see it land
                // and, if it landed wrong, keep dragging.
                if (showColumns) {
                  left = document.canvas.snapAcross(left, laidOutAt.width) ??
                      left;
                }

                onMove!(path, Offset(left, at.top + details.delta.dy));
              },
        onPanEnd: !free ? null : (_) => onMoved?.call(),
        onPanCancel: !free ? null : () => onMoved?.call(),
        child: wrapped,
      ),
    );
  }
}

/// The canvas edge, the safe area and the column grid, drawn over everything.
class _Guides extends CustomPainter {
  const _Guides({
    required this.canvas,
    required this.edges,
    required this.columns,
  });

  final UiCanvas canvas;
  final bool edges;
  final bool columns;

  @override
  void paint(Canvas paint, Size size) {
    // Under the edges, because the grid is the thing being laid out against
    // and the edges are the thing being laid out inside.
    if (columns) _paintColumns(paint, size);
    if (edges) _paintEdges(paint, size);
  }

  /// The columns as bands rather than as lines.
  ///
  /// A line marks a boundary; a band shows the space something can occupy and
  /// the gutter it may not. Filled faintly, so an interface is still readable
  /// through the grid it is being laid out against.
  void _paintColumns(Canvas paint, Size size) {
    final bands = canvas.columnsAcross(size.width);
    if (bands.isEmpty) return;

    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = OrbisColors.ember.withValues(alpha: 0.055);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrbisColors.ember.withValues(alpha: 0.3);

    for (final band in bands) {
      final rect = Rect.fromLTRB(band.left, 0, band.right, size.height);
      paint.drawRect(rect, fill);
      // The two edges of the band, which are the two lines anything dropped
      // near them snaps to.
      paint.drawLine(Offset(band.left, 0), Offset(band.left, size.height),
          edge);
      paint.drawLine(Offset(band.right, 0), Offset(band.right, size.height),
          edge);
    }
  }

  void _paintEdges(Canvas paint, Size size) {
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
  bool shouldRepaint(_Guides old) =>
      old.edges != edges ||
      old.columns != columns ||
      old.canvas.safeArea != canvas.safeArea ||
      old.canvas.columns != canvas.columns ||
      old.canvas.gutter != canvas.gutter;
}

/// The device's own edge, when it is not the canvas's.
///
/// Only drawn when there is something to say: a canvas shown at its own size
/// and filling it has one rectangle, and two rectangles on top of each other
/// read as a rendering fault rather than as a screen.
class _Screen extends CustomPainter {
  const _Screen({required this.showing});

  final bool showing;

  @override
  void paint(Canvas paint, Size size) {
    if (!showing) return;
    paint.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = OrbisColors.inkDim.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(_Screen old) => old.showing != showing;
}
