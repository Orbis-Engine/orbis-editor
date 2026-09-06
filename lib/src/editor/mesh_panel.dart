import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart' show ChoiceRow, ColourRow, SliderRow;
import 'surface.dart';
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
    required this.seeThrough,
    required this.onSeeThrough,
    required this.surfaces,
    required this.onSurfaces,
    required this.onPaint,
    required this.format,
    required this.onFormat,
    required this.onExport,
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

  /// Whether picking reaches what is behind the surface.
  final bool seeThrough;
  final ValueChanged<bool> onSeeThrough;

  /// What this shape's faces can be painted with.
  final List<Surface> surfaces;

  /// Called with the whole list whenever one of them changes. [live] is set
  /// while a slider is being dragged, so the run is one step to undo.
  final void Function(List<Surface> surfaces, {required bool live}) onSurfaces;

  /// Paints the selected faces with the slot at this position.
  final ValueChanged<int> onPaint;

  /// Which format an export writes.
  final MeshFormat format;
  final ValueChanged<MeshFormat> onFormat;
  final VoidCallback onExport;

  bool get _parametric => shape != null && geometry == null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shape != null) _shapeSection(),
        _editSection(),
        _materialsSection(),
        _exportSection(),
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
            OrbisButton(
              label: seeThrough ? 'Seeing through' : 'See through',
              icon: seeThrough
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              expand: true,
              tone: seeThrough ? ButtonTone.primary : ButtonTone.quiet,
              onPressed: () => onSeeThrough(!seeThrough),
            ),
            const SizedBox(height: Space.xs),
            Text(
              selection.isEmpty
                  ? 'Click ${mode.label.toLowerCase()} in the viewport. '
                      'Shift to add. G changes mode, escape leaves.'
                  : '${selection.countIn(mode)} selected — drag the handles to '
                      '${mode == ElementMode.face
                          ? 'move them, shift-drag to extrude'
                          : 'move them'}',
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
extension on MeshPanel {
  /// The material slots, and what paints with them.
  Widget _materialsSection() {
    // Which slot each face wears, so a slot can say how much of the shape it
    // covers — the fastest way to find the one somebody is looking for.
    final mesh = geometry ?? shape?.build();
    final worn = <int, int>{};
    for (final face in mesh?.faces ?? const <Face>[]) {
      worn[face.material] = (worn[face.material] ?? 0) + 1;
    }
    final painting = context_ == EditContext.element &&
        mode == ElementMode.face &&
        selection.faces.isNotEmpty;

    return _Section(
      title: 'Materials',
      icon: Icons.palette_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (surfaces.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Text(
                'One material, the renderer\'s own. Add a slot to paint '
                'faces with something else.',
                style: OrbisText.caption.copyWith(fontSize: 11),
              ),
            ),
          for (var i = 0; i < surfaces.length; i++) ...[
            _SurfaceRow(
              slot: i,
              surface: surfaces[i],
              faces: worn[i] ?? 0,
              painting: painting,
              onPaint: () => onPaint(i),
              onChanged: (next, {required live}) {
                final all = [...surfaces];
                all[i] = next;
                onSurfaces(all, live: live);
              },
            ),
            const SizedBox(height: Space.xs),
          ],
          OrbisButton(
            label: 'Add material',
            icon: Icons.add,
            expand: true,
            tone: ButtonTone.quiet,
            onPressed: () => onSurfaces(
              [
                ...surfaces,
                Surface(name: 'Material ${surfaces.length + 1}'),
              ],
              live: false,
            ),
          ),
        ],
      ),
    );
  }
}

extension on MeshPanel {
  /// The way out.
  ///
  /// Not because the engine needs it — it reads its own files — but because a
  /// shape blocked out here is often the start of something finished
  /// somewhere else, and a tool that can only be a dead end is one people
  /// stop putting real work into.
  Widget _exportSection() {
    return _Section(
      title: 'Export',
      icon: Icons.ios_share_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow(
            label: 'Format',
            options: [for (final one in MeshFormat.values) one.label],
            selected: format.label,
            onSelect: (label) => onFormat(
              MeshFormat.values.firstWhere((one) => one.label == label),
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            switch (format) {
              MeshFormat.obj =>
                'Keeps faces as they were drawn, and brings a .mtl.',
              MeshFormat.glb => 'What the engine itself loads.',
              MeshFormat.stl => 'Triangles and nothing else. What a printer '
                  'takes.',
              MeshFormat.ply => 'Triangles with their normals and '
                  'coordinates.',
            },
            style: OrbisText.caption.copyWith(fontSize: 11),
          ),
          const SizedBox(height: Space.xs),
          OrbisButton(
            label: 'Export shape',
            icon: Icons.save_alt,
            expand: true,
            tone: ButtonTone.quiet,
            onPressed: onExport,
          ),
        ],
      ),
    );
  }
}

/// One material slot: what it looks like, how much of the shape wears it, and
/// the button that paints more of it.
class _SurfaceRow extends StatelessWidget {
  const _SurfaceRow({
    required this.slot,
    required this.surface,
    required this.faces,
    required this.painting,
    required this.onPaint,
    required this.onChanged,
  });

  final int slot;
  final Surface surface;
  final int faces;

  /// Whether there are faces selected for the paint button to act on.
  final bool painting;
  final VoidCallback onPaint;
  final void Function(Surface next, {required bool live}) onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.xs),
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: surface.colour,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: OrbisColors.lineSoft),
                ),
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  surface.name,
                  overflow: TextOverflow.ellipsis,
                  style: OrbisText.body.copyWith(fontSize: 11.5),
                ),
              ),
              Text(
                faces == 0 ? 'unused' : '$faces',
                style: OrbisText.caption.copyWith(fontSize: 10.5),
              ),
              const SizedBox(width: Space.xs),
              // Only when there is something to paint. A button that does
              // nothing teaches somebody nothing about when it would.
              if (painting)
                OrbisButton(
                  label: 'Paint',
                  icon: Icons.format_paint_outlined,
                  tone: ButtonTone.primary,
                  onPressed: onPaint,
                ),
            ],
          ),
          const SizedBox(height: Space.xs),
          ColourRow(
            label: 'Colour',
            value: surface.colour,
            onChanged: (colour) =>
                onChanged(surface.copyWith(colour: colour), live: false),
          ),
          SliderRow(
            label: 'Metal',
            value: surface.metallic,
            min: 0,
            max: 1,
            decimals: 2,
            onChanged: (value) =>
                onChanged(surface.copyWith(metallic: value), live: true),
          ),
          SliderRow(
            label: 'Rough',
            value: surface.roughness,
            min: 0,
            max: 1,
            decimals: 2,
            onChanged: (value) =>
                onChanged(surface.copyWith(roughness: value), live: true),
          ),
        ],
      ),
    );
  }
}

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
