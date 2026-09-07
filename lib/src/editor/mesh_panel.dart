import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'boundary.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart' show ChoiceRow, SliderRow;

/// Building geometry: the shape it started as, and what to do to it now.
///
/// One panel rather than a window of its own. A modelling tool that opens a
/// floating palette is a tool whose palette is behind the main window by the
/// third time somebody uses it, and everything here is about the thing already
/// selected in the inspector.
class MeshPanel extends StatelessWidget {
  const MeshPanel({
    super.key,
    required this.shape,
    required this.geometry,
    required this.onShape,
    required this.outline,
    required this.onOutline,
    required this.onOpenTools,
    required this.boundary,
    required this.onBoundary,
    required this.naturalSize,
  });

  /// What it was made from, still true while [geometry] is null.
  final Shape? shape;

  /// What it is now, once somebody edited it.
  final Mesh? geometry;

  final ValueChanged<Shape> onShape;
  /// The outline this shape was drawn from, if it was drawn.
  final PolyShape? outline;

  /// Called when its height or facing changes. [live] is set while a slider
  /// is moving.
  final void Function(PolyShape next, {required bool live}) onOutline;

  /// Opens the modelling panel, for when it is not on screen.
  final VoidCallback onOpenTools;

  /// Where this object begins and ends, as far as anything but the eye is
  /// concerned.
  final Boundary boundary;

  /// Called when it changes. [live] is set while a slider is moving.
  final void Function(Boundary next, {required bool live}) onBoundary;

  /// How big the object is before the boundary has any say, for showing what
  /// the padding is being added to.
  final ({Vector3 min, Vector3 max}) naturalSize;

  bool get _parametric => shape != null && geometry == null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (outline != null) _outlineSection(),
        if (shape != null) _shapeSection(),
        _boundarySection(),
        _pointer(),
      ],
    );
  }

  /// Where this object begins and ends.
  ///
  /// In the inspector rather than the modelling panel because it is a
  /// property of *this object*, like its position — not a job somebody
  /// settles into. A crate and the room it stands in want different answers
  /// and neither is a thing you do fifty times in a row.
  Widget _boundarySection() {
    final box = boundary.boxFrom(naturalSize);
    final size = box.max - box.min;
    final hasShape = (geometry ?? shape?.build()) != null;

    return _Section(
      title: 'Boundary',
      icon: Icons.select_all_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow(
            label: 'Shape',
            options: [for (final one in BoundaryKind.values) one.label],
            selected: boundary.kind.label,
            onSelect: (label) => onBoundary(
              boundary.copyWith(
                kind: BoundaryKind.values
                    .firstWhere((one) => one.label == label),
              ),
              live: false,
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            boundary.kind == BoundaryKind.mesh && !hasShape
                ? 'No geometry here, so this falls back to the box.'
                : boundary.kind.hint,
            style: OrbisText.caption.copyWith(fontSize: 11),
          ),
          if (!boundary.isNothing) ...[
            SliderRow(
              label: 'Padding',
              value: boundary.padding,
              min: -0.5,
              max: 1,
              decimals: 3,
              onChanged: (value) =>
                  onBoundary(boundary.copyWith(padding: value), live: true),
            ),
            for (final axis in const ['X', 'Y', 'Z'])
              SliderRow(
                label: 'Offset $axis',
                value: switch (axis) {
                  'X' => boundary.offset.x,
                  'Y' => boundary.offset.y,
                  _ => boundary.offset.z,
                },
                min: -5,
                max: 5,
                decimals: 3,
                onChanged: (value) => onBoundary(
                  boundary.copyWith(
                    offset: Vector3(
                      axis == 'X' ? value : boundary.offset.x,
                      axis == 'Y' ? value : boundary.offset.y,
                      axis == 'Z' ? value : boundary.offset.z,
                    ),
                  ),
                  live: true,
                ),
              ),
            const SizedBox(height: Space.xs),
            Text(
              '${size.x.toStringAsFixed(2)} × ${size.y.toStringAsFixed(2)} × '
              '${size.z.toStringAsFixed(2)} m',
              style: OrbisText.mono.copyWith(fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }

  /// Where the rest of it went.
  ///
  /// Worth a line and a button: somebody who used to find extrude here will
  /// look here for it, and being told where it is beats going and reading a
  /// menu.
  Widget _pointer() {
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Extruding, cutting, materials and export are in the modelling '
            'panel.',
            style: OrbisText.caption.copyWith(fontSize: 11),
          ),
          const SizedBox(height: Space.xs),
          OrbisButton(
            label: 'Modelling tools',
            icon: Icons.handyman_outlined,
            expand: true,
            tone: ButtonTone.quiet,
            onPressed: onOpenTools,
          ),
        ],
      ),
    );
  }

  Widget _outlineSection() {
    final drawn = outline!;
    return _Section(
      title: 'Drawn shape',
      icon: Icons.polyline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (geometry != null)
            Text(
              'Edited since it was drawn, so the outline no longer describes '
              'it. Its corners are still here if you undo back.',
              style: OrbisText.caption.copyWith(fontSize: 11),
            )
          else ...[
            Text(
              '${drawn.points.length} corners',
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
            SliderRow(
              label: 'Height',
              value: drawn.height,
              min: -8,
              max: 8,
              decimals: 2,
              onChanged: (value) => onOutline(
                PolyShape(
                  points: drawn.points,
                  height: value,
                  flipped: drawn.flipped,
                ),
                live: true,
              ),
            ),
            OrbisButton(
              label: 'Turn it over',
              icon: Icons.flip_outlined,
              expand: true,
              tone: ButtonTone.quiet,
              onPressed: () => onOutline(
                PolyShape(
                  points: drawn.points,
                  height: drawn.height,
                  flipped: !drawn.flipped,
                ),
                live: false,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shapeSection() {
    final current = shape!;

    return _Section(
      title: current.kind.label,
      icon: Icons.category_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_parametric)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Text(
                'Edited. These are what it was made from — changing one now '
                'would throw away the geometry.',
                style: OrbisText.caption.copyWith(fontSize: 11),
              ),
            ),
          // Size first: it is what somebody reaches for, and it means the same
          // thing for every one of the twelve.
          for (final axis in const ['Width', 'Height', 'Depth'])
            SliderRow(
              label: axis,
              value: switch (axis) {
                'Width' => current.width,
                'Height' => current.height,
                _ => current.depth,
              },
              min: 0.05,
              max: 20,
              decimals: 2,
              onChanged: _parametric
                  ? (value) => onShape(switch (axis) {
                        'Width' => current.copyWith(width: value),
                        'Height' => current.copyWith(height: value),
                        _ => current.copyWith(depth: value),
                      })
                  : (_) {},
            ),
          ..._parametersFor(current),
        ],
      ),
    );
  }

  /// The controls that belong to this kind of shape and no other.
  ///
  /// A cylinder has sides and a torus has a tube radius; showing every field
  /// for every shape is twenty controls of which two matter.
  List<Widget> _parametersFor(Shape current) {
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      Shape Function(double) change, {
      int decimals = 0,
    }) =>
        SliderRow(
          label: label,
          value: value,
          min: min,
          max: max,
          decimals: decimals,
          onChanged: _parametric ? (v) => onShape(change(v)) : (_) {},
        );

    Widget toggle(String label, bool on, Shape Function(bool) change) =>
        ChoiceRow(
          label: label,
          options: const ['Off', 'On'],
          selected: on ? 'On' : 'Off',
          onSelect: _parametric ? (v) => onShape(change(v == 'On')) : (_) {},
        );

    return switch (current.kind) {
      ShapeKind.plane => [
          slider('Cuts across', current.widthCuts.toDouble(), 0, 24,
              (v) => current.copyWith(widthCuts: v.round())),
          slider('Cuts along', current.heightCuts.toDouble(), 0, 24,
              (v) => current.copyWith(heightCuts: v.round())),
        ],
      ShapeKind.sphere => [
          slider('Divisions', current.subdivisions.toDouble(), 1, 5,
              (v) => current.copyWith(subdivisions: v.round())),
          toggle('Smooth', current.smooth, (v) => current.copyWith(smooth: v)),
        ],
      ShapeKind.cylinder => [
          slider('Sides', current.sides.toDouble(), 3, 64,
              (v) => current.copyWith(sides: v.round())),
          slider('Height cuts', current.heightCuts.toDouble(), 0, 24,
              (v) => current.copyWith(heightCuts: v.round())),
          toggle('Ends', current.capped, (v) => current.copyWith(capped: v)),
          toggle('Smooth', current.smooth, (v) => current.copyWith(smooth: v)),
        ],
      ShapeKind.cone => [
          slider('Sides', current.sides.toDouble(), 3, 64,
              (v) => current.copyWith(sides: v.round())),
          toggle('Base', current.capped, (v) => current.copyWith(capped: v)),
          toggle('Smooth', current.smooth, (v) => current.copyWith(smooth: v)),
        ],
      ShapeKind.pipe => [
          slider('Thickness', current.thickness, 0.01, 2,
              (v) => current.copyWith(thickness: v), decimals: 2),
          slider('Sides', current.sides.toDouble(), 3, 64,
              (v) => current.copyWith(sides: v.round())),
          slider('Height cuts', current.heightCuts.toDouble(), 0, 24,
              (v) => current.copyWith(heightCuts: v.round())),
          toggle('Rims', current.capped, (v) => current.copyWith(capped: v)),
        ],
      ShapeKind.torus => [
          slider('Rows', current.rings.toDouble(), 3, 64,
              (v) => current.copyWith(rings: v.round())),
          slider('Columns', current.columns.toDouble(), 3, 64,
              (v) => current.copyWith(columns: v.round())),
          slider('Tube', current.tubeRadius, 0.01, 2,
              (v) => current.copyWith(tubeRadius: v), decimals: 2),
          slider('Sweep', current.circumference, 1, 360,
              (v) => current.copyWith(circumference: v)),
        ],
      ShapeKind.arch => [
          slider('Thickness', current.thickness, 0.01, 2,
              (v) => current.copyWith(thickness: v), decimals: 2),
          slider('Segments', current.sides.toDouble(), 2, 64,
              (v) => current.copyWith(sides: v.round())),
          slider('Sweep', current.circumference, 1, 360,
              (v) => current.copyWith(circumference: v)),
          toggle('End caps', current.capped,
              (v) => current.copyWith(capped: v)),
        ],
      ShapeKind.door => [
          slider('Opening top', current.pedimentHeight, 0.05, 4,
              (v) => current.copyWith(pedimentHeight: v), decimals: 2),
          slider('Side width', current.sideWidth, 0.05, 4,
              (v) => current.copyWith(sideWidth: v), decimals: 2),
        ],
      ShapeKind.stairs => [
          ChoiceRow(
            label: 'Steps by',
            options: const ['Count', 'Height'],
            selected: current.byCount ? 'Count' : 'Height',
            onSelect: _parametric
                ? (v) => onShape(current.copyWith(byCount: v == 'Count'))
                : (_) {},
          ),
          if (current.byCount)
            slider('Steps', current.steps.toDouble(), 1, 64,
                (v) => current.copyWith(steps: v.round()))
          else
            slider('Step height', current.stepHeight, 0.05, 1,
                (v) => current.copyWith(stepHeight: v), decimals: 2),
        ],
      _ => const [],
    };
  }

}

/// One action: what it does, and how much of it.
/// A titled block, matching the inspector's other sections.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                Icon(icon, size: 13, color: OrbisColors.inkDim),
                const SizedBox(width: Space.sm),
                Text(title.toUpperCase(), style: OrbisText.section),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: child,
          ),
        ],
      ),
    );
  }
}
