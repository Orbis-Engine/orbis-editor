import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart' show ChoiceRow, SliderRow;
import 'mesh_edit.dart';

/// What a drag in the coordinate view does.
enum UvGesture {
  /// Moves what is selected.
  move('Move', Icons.open_with),

  /// Scales it about its own middle.
  scale('Scale', Icons.zoom_out_map),

  /// Turns it about its own middle.
  turn('Turn', Icons.rotate_right);

  const UvGesture(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Where a face's texture sits.
///
/// The nought-to-one square is the texture; what is drawn over it is the
/// selected faces, laid out as the shader will read them. A face outside the
/// square is not wrong — that is how a texture repeats — but a face somebody
/// meant to fill the square and did not is the commonest thing this view is
/// opened to find out about.
class UvPanel extends StatelessWidget {
  const UvPanel({
    super.key,
    required this.mesh,
    required this.selection,
    required this.gesture,
    required this.onGesture,
    required this.onNudge,
    required this.onScale,
    required this.onTurn,
    required this.onDone,
    required this.onAction,
  });

  final Mesh? mesh;
  final ElementSelection selection;

  final UvGesture gesture;
  final ValueChanged<UvGesture> onGesture;

  /// A drag in progress. In coordinate space, so the panel does not have to
  /// know how big it is drawn.
  final ValueChanged<Vector2> onNudge;
  final ValueChanged<Vector2> onScale;
  final ValueChanged<double> onTurn;

  /// Called when a drag ends, so a run of them is one step to undo.
  final VoidCallback onDone;

  /// One of the buttons: freeze, release, fit, and the two projections.
  final ValueChanged<UvAction> onAction;

  List<Face> get _faces {
    final owner = mesh;
    if (owner == null) return const [];
    return selection.facesIn(owner);
  }

  @override
  Widget build(BuildContext context) {
    final owner = mesh;
    final chosen = _faces;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final one in UvGesture.values) ...[
              Expanded(
                child: OrbisButton(
                  label: one.label,
                  icon: one.icon,
                  expand: true,
                  tone:
                      one == gesture ? ButtonTone.primary : ButtonTone.quiet,
                  onPressed: () => onGesture(one),
                ),
              ),
              const SizedBox(width: Space.xs),
            ],
          ],
        ),
        const SizedBox(height: Space.xs),
        AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: OrbisColors.ground,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: OrbisColors.lineSoft),
            ),
            child: owner == null || chosen.isEmpty
                ? Center(
                    child: Text(
                      'Select faces to see where their texture sits.',
                      textAlign: TextAlign.center,
                      style: OrbisText.caption.copyWith(fontSize: 11),
                    ),
                  )
                : _UvCanvas(
                    mesh: owner,
                    faces: chosen,
                    gesture: gesture,
                    onNudge: onNudge,
                    onScale: onScale,
                    onTurn: onTurn,
                    onDone: onDone,
                  ),
          ),
        ),
        const SizedBox(height: Space.xs),
        Text(
          chosen.isEmpty
              ? 'Nothing selected.'
              : chosen.any((face) => face.uv.isManual)
                  ? '${chosen.length} selected · drawn by hand'
                  : '${chosen.length} selected · following the rule',
          style: OrbisText.caption.copyWith(fontSize: 11),
        ),
        const SizedBox(height: Space.xs),
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            for (final action in UvAction.values)
              OrbisButton(
                label: action.label,
                icon: action.icon,
                tone: ButtonTone.quiet,
                onPressed: chosen.isEmpty ? null : () => onAction(action),
              ),
          ],
        ),
      ],
    );
  }
}

/// The buttons that are not a drag.
enum UvAction {
  /// Turn the rule into coordinates, so they can be edited one at a time.
  freeze('Freeze', Icons.push_pin_outlined),

  /// Back to the rule, throwing away what was drawn.
  release('Follow shape', Icons.auto_fix_high_outlined),

  /// Put the whole selection in the square.
  fit('Fit', Icons.fit_screen_outlined),

  /// One texture across every selected face, from their average direction.
  planar('Project flat', Icons.crop_landscape_outlined),

  /// Each face from whichever way it points.
  box('Project per face', Icons.view_in_ar_outlined);

  const UvAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The square itself.
class _UvCanvas extends StatefulWidget {
  const _UvCanvas({
    required this.mesh,
    required this.faces,
    required this.gesture,
    required this.onNudge,
    required this.onScale,
    required this.onTurn,
    required this.onDone,
  });

  final Mesh mesh;
  final List<Face> faces;
  final UvGesture gesture;
  final ValueChanged<Vector2> onNudge;
  final ValueChanged<Vector2> onScale;
  final ValueChanged<double> onTurn;
  final VoidCallback onDone;

  @override
  State<_UvCanvas> createState() => _UvCanvasState();
}

class _UvCanvasState extends State<_UvCanvas> {
  /// How many coordinate units the square is across, and where its middle is.
  ///
  /// The view zooms rather than the coordinates being clamped: a tiling face
  /// covers eight units and a stretched one covers one, and a view that only
  /// ever showed nought to one would show the first as a smear over the
  /// whole square.
  double _span = 1.4;
  Vector2 _centre = Vector2(0.5, 0.5);

  Offset? _from;
  Vector2? _grabbed;

  /// Where the view sits, worked out from what is selected.
  ///
  /// Only when nothing is being dragged: reframing mid-drag would move what
  /// somebody is holding.
  void _frame() {
    if (_from != null) return;
    final box = widget.mesh.uvBoundsOf(widget.faces);
    if (box == null) return;

    final wide = math.max(box.max.x - box.min.x, box.max.y - box.min.y);
    // The unit square is always in shot, whatever the selection covers, so
    // "is this face inside the texture" can be answered by looking.
    final span = math.max(math.max(wide, 1.0) * 1.25, 0.2);
    final middle = (box.min + box.max)..scale(0.5);

    _span = span;
    _centre = Vector2(
      (middle.x + 0.5) / 2,
      (middle.y + 0.5) / 2,
    );
  }

  Vector2 _toUv(Offset at, Size size) {
    final scale = _span / size.width;
    return Vector2(
      _centre.x + (at.dx - size.width / 2) * scale,
      // Down the screen is down in V, which is the way a texture is read.
      _centre.y - (at.dy - size.height / 2) * scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    _frame();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            _from = details.localPosition;
            _grabbed = _toUv(details.localPosition, size);
          },
          onPanUpdate: (details) {
            final from = _from;
            final grabbed = _grabbed;
            if (from == null || grabbed == null) return;

            final now = _toUv(details.localPosition, size);
            switch (widget.gesture) {
              case UvGesture.move:
                widget.onNudge(now - grabbed);
              case UvGesture.scale:
                // How much further from the middle the pointer is than it
                // was. Along both axes together, because a corner handle is
                // what this gesture is: dragging out makes it bigger.
                final was = grabbed - _centre;
                final is_ = now - _centre;
                final by = Vector2(
                  was.x.abs() < 1e-6 ? 1 : is_.x / was.x,
                  was.y.abs() < 1e-6 ? 1 : is_.y / was.y,
                );
                widget.onScale(by);
              case UvGesture.turn:
                final was = math.atan2(grabbed.y - _centre.y,
                    grabbed.x - _centre.x);
                final now_ = math.atan2(now.y - _centre.y, now.x - _centre.x);
                widget.onTurn((now_ - was) * 180 / math.pi);
            }
            _grabbed = now;
          },
          onPanEnd: (_) {
            _from = null;
            _grabbed = null;
            widget.onDone();
          },
          onPanCancel: () {
            _from = null;
            _grabbed = null;
            widget.onDone();
          },
          child: CustomPaint(
            painter: _UvPainter(
              mesh: widget.mesh,
              faces: widget.faces,
              span: _span,
              centre: _centre,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _UvPainter extends CustomPainter {
  const _UvPainter({
    required this.mesh,
    required this.faces,
    required this.span,
    required this.centre,
  });

  final Mesh mesh;
  final List<Face> faces;
  final double span;
  final Vector2 centre;

  Offset _at(Vector2 uv, Size size) {
    final scale = size.width / span;
    return Offset(
      size.width / 2 + (uv.x - centre.x) * scale,
      size.height / 2 - (uv.y - centre.y) * scale,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // The texture's own square, which is the one thing in here that is not
    // the geometry: everything is read as a fraction of it.
    final square = Rect.fromPoints(
      _at(Vector2(0, 0), size),
      _at(Vector2(1, 1), size),
    );
    canvas
      ..drawRect(square, Paint()..color = const Color(0x14FFFFFF))
      ..drawRect(
        square,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x66FFFFFF),
      );

    // Quarters, so a face can be seen to be half a texture across without
    // anybody measuring.
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color(0x22FFFFFF);
    for (var i = 1; i < 4; i++) {
      final part = i / 4;
      canvas
        ..drawLine(_at(Vector2(part, 0), size), _at(Vector2(part, 1), size),
            guide)
        ..drawLine(_at(Vector2(0, part), size), _at(Vector2(1, part), size),
            guide);
    }

    final fill = Paint()..color = const Color(0x33E5893F);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFE5893F);
    final corner = Paint()..color = const Color(0xFFE5893F);

    for (final face in faces) {
      final uvs = mesh.uvsOf(face);
      if (uvs.length < 3) continue;

      final path = Path();
      for (var i = 0; i < uvs.length; i++) {
        final point = _at(uvs[i], size);
        i == 0
            ? path.moveTo(point.dx, point.dy)
            : path.lineTo(point.dx, point.dy);
      }
      path.close();

      canvas
        ..drawPath(path, fill)
        ..drawPath(path, edge);
      for (final uv in uvs) {
        canvas.drawCircle(_at(uv, size), 2.5, corner);
      }
    }
  }

  @override
  bool shouldRepaint(_UvPainter old) => true;
}

/// The rule's own numbers, for the faces that are still following one.
class UvRuleControls extends StatelessWidget {
  const UvRuleControls({
    super.key,
    required this.uv,
    required this.onChanged,
    required this.onDone,
  });

  final FaceUv uv;

  /// [live] is set while a slider is being dragged.
  final void Function(FaceUv next, {required bool live}) onChanged;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceRow(
          label: 'Fill',
          options: [for (final one in UvFit.values) _labelOf(one)],
          selected: _labelOf(uv.fit),
          onSelect: (label) => onChanged(
            uv.copyWith(
              fit: UvFit.values.firstWhere((one) => _labelOf(one) == label),
            ),
            live: false,
          ),
        ),
        SliderRow(
          label: 'Repeat across',
          value: uv.scale.x,
          min: 0.05,
          max: 8,
          decimals: 2,
          onChanged: (value) => onChanged(
            uv.copyWith(scale: Vector2(value, uv.scale.y)),
            live: true,
          ),
        ),
        SliderRow(
          label: 'Repeat down',
          value: uv.scale.y,
          min: 0.05,
          max: 8,
          decimals: 2,
          onChanged: (value) => onChanged(
            uv.copyWith(scale: Vector2(uv.scale.x, value)),
            live: true,
          ),
        ),
        SliderRow(
          label: 'Turn',
          value: uv.rotation,
          min: -180,
          max: 180,
          decimals: 0,
          onChanged: (value) =>
              onChanged(uv.copyWith(rotation: value), live: true),
        ),
        SliderRow(
          label: 'Across',
          value: uv.offset.x,
          min: -2,
          max: 2,
          decimals: 2,
          onChanged: (value) => onChanged(
            uv.copyWith(offset: Vector2(value, uv.offset.y)),
            live: true,
          ),
        ),
        SliderRow(
          label: 'Down',
          value: uv.offset.y,
          min: -2,
          max: 2,
          decimals: 2,
          onChanged: (value) => onChanged(
            uv.copyWith(offset: Vector2(uv.offset.x, value)),
            live: true,
          ),
        ),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            for (final one in [
              (label: 'Flip across', on: uv.flipU),
              (label: 'Flip down', on: uv.flipV),
              (label: 'Swap axes', on: uv.swap),
            ]) ...[
              Expanded(
                child: OrbisButton(
                  label: one.label,
                  expand: true,
                  tone: one.on ? ButtonTone.primary : ButtonTone.quiet,
                  onPressed: () => onChanged(
                    switch (one.label) {
                      'Flip across' => uv.copyWith(flipU: !uv.flipU),
                      'Flip down' => uv.copyWith(flipV: !uv.flipV),
                      _ => uv.copyWith(swap: !uv.swap),
                    },
                    live: false,
                  ),
                ),
              ),
              const SizedBox(width: Space.xs),
            ],
          ],
        ),
      ],
    );
  }

  static String _labelOf(UvFit fit) => switch (fit) {
        UvFit.tile => 'Tile',
        UvFit.stretch => 'Stretch',
        UvFit.fit => 'Fit',
      };
}
