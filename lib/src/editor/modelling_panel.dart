import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'drawing.dart';
import 'inspector.dart' show ChoiceRow, ColourRow, SliderRow;
import 'mesh_edit.dart';
import 'mesh_tools.dart';
import 'surface.dart';

/// The modelling tools, as a place rather than a section.
///
/// Everything somebody does *to* geometry is here: what is being edited, what
/// is selected, the operations, the two tools that are drawn, the materials
/// faces are painted with, and the way out.
///
/// A panel of its own rather than part of the inspector, because modelling is
/// a job you settle into and the inspector is a place you pass through. A tool
/// used fifty times in a row should not be four scrolls down a list of
/// somebody's transform, light and weather settings.
///
/// Docked rather than floating. A modelling palette that floats is a palette
/// behind the main window by the third time anybody uses it.
class ModellingPanel extends StatelessWidget {
  const ModellingPanel({
    super.key,
    required this.shape,
    required this.geometry,
    required this.context_,
    required this.mode,
    required this.selection,
    required this.amounts,
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
    required this.tool,
    required this.onTool,
    required this.drawing,
  });

  /// What the selected shape was made from, if it is still that.
  final Shape? shape;

  /// What it is now, once somebody edited it.
  final Mesh? geometry;

  final EditContext context_;
  final ElementMode mode;
  final ElementSelection selection;

  /// How much each action does, by action name.
  final Map<String, double> amounts;

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

  /// Which drawing tool is out, and the drawing itself.
  final ViewportTool tool;
  final ValueChanged<ViewportTool> onTool;
  final Drawing drawing;

  /// Whether there is a shape to work on at all.
  bool get hasShape => shape != null || geometry != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _drawSection(),
        if (!hasShape)
          Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: Text(
              'Select a shape to work on it, or draw one.',
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          )
        else ...[
          _editSection(),
          _materialsSection(),
          _exportSection(),
        ],
      ],
    );
  }

  /// The two tools that are drawn rather than clicked.
  ///
  /// At the top because they are the only things here that work without a
  /// shape selected — drawing one is how somebody gets a shape in the first
  /// place.
  Widget _drawSection() {
    return _Section(
      title: 'Draw',
      icon: Icons.polyline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final one in [ViewportTool.polyShape, ViewportTool.cut]) ...[
                Expanded(
                  child: OrbisButton(
                    label: one.label,
                    icon: one.icon,
                    expand: true,
                    tone: tool == one ? ButtonTone.primary : ButtonTone.quiet,
                    // Cutting needs something to cut. Offered dimmed rather
                    // than hidden, so it is clear the tool exists and what it
                    // is waiting for.
                    onPressed: one == ViewportTool.cut && !hasShape
                        ? null
                        : () => onTool(one),
                  ),
                ),
                const SizedBox(width: Space.xs),
              ],
            ],
          ),
          if (tool.isDrawing) ...[
            const SizedBox(height: Space.xs),
            Text(
              '${drawing.points.length} '
              '${drawing.points.length == 1 ? "point" : "points"} · enter '
              'finishes, backspace takes one back, escape gives up.',
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
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
          // Grouped, because twenty-five buttons in a column is a list nobody
          // reads. The three shelves are not arbitrary: one changes what is
          // selected, one changes the part of the shape that is, and one
          // changes the whole thing — and knowing which of those a button
          // does is most of knowing whether to press it.
          for (final group in ToolGroup.values) ...[
            if (offered.any((one) => one.group == group)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 3),
                child: Text(
                  group.label.toUpperCase(),
                  style: OrbisText.caption.copyWith(
                    fontSize: 9.5,
                    letterSpacing: 0.6,
                    color: OrbisColors.inkDim,
                  ),
                ),
              ),
              for (final action in offered.where((one) => one.group == group))
                ...[
                _ActionRow(
                  action: action,
                  amount: amounts[action.label] ?? action.amount?.value ?? 1,
                  onRun: () => onAction(action),
                  onAmount: (value) => onAmount(action.label, value),
                ),
                const SizedBox(height: 3),
              ],
            ],
          ],
        ],
      ),
    );
  }

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

  /// The numbers a drawn shape still has.
  ///
  /// Only while it is still the outline: once somebody edits the geometry
  /// itself the outline cannot describe it any more, and a height slider that
  /// silently threw away an extrude would be worse than not having one.


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
