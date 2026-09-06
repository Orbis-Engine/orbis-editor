import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart' show ChoiceRow, SliderRow;
import 'mesh_edit.dart';
import 'mesh_tools.dart';

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
    required this.context_,
    required this.mode,
    required this.selection,
    required this.amounts,
    required this.onShape,
    required this.onContext,
    required this.onMode,
    required this.onAction,
    required this.onAmount,
  });

  /// What it was made from, still true while [geometry] is null.
  final Shape? shape;

  /// What it is now, once somebody edited it.
  final Mesh? geometry;

  final EditContext context_;
  final ElementMode mode;
  final ElementSelection selection;

  /// How much each action does, by action name.
  final Map<String, double> amounts;

  final ValueChanged<Shape> onShape;
  final ValueChanged<EditContext> onContext;
  final ValueChanged<ElementMode> onMode;
  final ValueChanged<MeshAction> onAction;
  final void Function(String action, double amount) onAmount;

  bool get _parametric => shape != null && geometry == null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shape != null) _shapeSection(),
        _editSection(),
      ],
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

  Widget _editSection() {
    final editing = context_ == EditContext.element;
    final offered = MeshTools.availableIn(editing ? mode : null, selection);

    return _Section(
      title: 'Geometry',
      icon: Icons.build_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow(
            label: 'Editing',
            options: [for (final one in EditContext.values) one.label],
            selected: context_.label,
            onSelect: (label) => onContext(
              EditContext.values.firstWhere((one) => one.label == label),
            ),
          ),
          if (editing) ...[
            const SizedBox(height: Space.xs),
            Row(
              children: [
                for (final one in ElementMode.values) ...[
                  Expanded(
                    child: OrbisButton(
                      label: one.label,
                      icon: one.icon,
                      expand: true,
                      tone: one == mode
                          ? ButtonTone.primary
                          : ButtonTone.quiet,
                      onPressed: () => onMode(one),
                    ),
                  ),
                  const SizedBox(width: Space.xs),
                ],
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              selection.isEmpty
                  ? 'Click ${mode.label.toLowerCase()} in the viewport. '
                      'Shift to add. G changes mode, escape leaves.'
                  : '${selection.countIn(mode)} selected',
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: Space.sm),
          for (final action in offered) ...[
            _ActionRow(
              action: action,
              amount: amounts[action.label] ?? action.amount?.value ?? 1,
              onRun: () => onAction(action),
              onAmount: (value) => onAmount(action.label, value),
            ),
            const SizedBox(height: 3),
          ],
        ],
      ),
    );
  }
}

/// One action: what it does, and how much of it.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.amount,
    required this.onRun,
    required this.onAmount,
  });

  final MeshAction action;
  final double amount;
  final VoidCallback onRun;
  final ValueChanged<double> onAmount;

  @override
  Widget build(BuildContext context) {
    final takes = action.amount;

    return Tooltip(
      message: action.hint,
      waitDuration: const Duration(milliseconds: 500),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrbisButton(
            label: action.label,
            icon: action.icon,
            expand: true,
            tone: ButtonTone.normal,
            onPressed: onRun,
          ),
          // The number under the button that uses it, so it is obvious which
          // one it belongs to. A panel of sliders above a panel of buttons is
          // a guess about which goes with which.
          if (takes != null)
            SliderRow(
              label: takes.label,
              value: amount,
              min: takes.min,
              max: takes.max,
              decimals: takes.max <= 2 ? 2 : 0,
              onChanged: onAmount,
            ),
        ],
      ),
    );
  }
}

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
