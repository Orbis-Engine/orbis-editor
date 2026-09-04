import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'scene.dart';

/// Properties of whatever is selected.
///
/// The fields shown depend on what the thing is, which is the whole point of
/// components: a light and a mesh are not the same object with some fields
/// greyed out, they are different sets of components on an entity.
///
/// Every field here edits the scene. A control that moved but changed nothing
/// would be the most convincing kind of broken.
class Inspector extends StatelessWidget {
  const Inspector({super.key, required this.object, required this.onChanged});

  final SceneObject object;

  /// Called after the object has been mutated, so the owner can rebuild the
  /// outliner and push a new scene to the renderer.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 288,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(left: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Text('INSPECTOR', style: OrbisText.section),
          ),
          Expanded(
            child: ListView(
              // Keyed on the object so the scroll position resets when the
              // selection changes, rather than leaving a short panel scrolled
              // to where a taller one had been.
              key: ValueKey(object.name),
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              children: [
                _Header(name: object.name, icon: object.icon),
                if (object.kind != ObjectKind.scene) _transform(),
                if (object.kind == ObjectKind.light) _light(),
                if (object.kind == ObjectKind.mesh) _mesh(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _transform() => _ComponentSection(
        title: 'Transform',
        icon: Icons.open_with,
        child: Column(
          children: [
            VectorRow(
              label: 'Position',
              value: object.position,
              step: 0.02,
              onChanged: onChanged,
            ),
            VectorRow(
              label: 'Rotation',
              value: object.rotation,
              step: 0.5,
              decimals: 1,
              onChanged: onChanged,
            ),
            VectorRow(
              label: 'Scale',
              value: object.scale,
              step: 0.02,
              minimum: 0.001,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _light() => _ComponentSection(
        title: 'Light',
        icon: Icons.wb_sunny_outlined,
        child: Column(
          children: [
            // Only Sun is offered because only Sun is rendered. The other
            // three arrive with the renderer's punctual lights.
            const ChoiceRow(
              label: 'Type',
              options: ['Sun'],
              selected: 'Sun',
            ),
            ColourRow(
              label: 'Colour',
              value: object.colour,
              onChanged: (value) {
                object.colour = value;
                onChanged();
              },
            ),
            SliderRow(
              label: 'Power',
              value: object.power,
              min: 0,
              max: 5000,
              unit: 'W',
              onChanged: (value) {
                object.power = value;
                onChanged();
              },
            ),
          ],
        ),
      );

  Widget _mesh() => _ComponentSection(
        title: 'Mesh renderer',
        icon: Icons.view_in_ar_outlined,
        child: Column(
          children: [
            ColourRow(
              label: 'Base colour',
              value: object.colour,
              onChanged: (value) {
                object.colour = value;
                onChanged();
              },
            ),
            ChoiceRow(
              label: 'Cast shadows',
              options: const ['Off', 'On'],
              selected: object.castShadows ? 'On' : 'Off',
              onSelect: (value) {
                object.castShadows = value == 'On';
                onChanged();
              },
            ),
            const TextRow(label: 'Mesh', value: 'cube'),
          ],
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.icon});

  final String name;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.md),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: OrbisColors.emberWash,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 13, color: OrbisColors.ember),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(name,
                style: OrbisText.title.copyWith(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

/// One component's worth of fields, under a heading.
class _ComponentSection extends StatelessWidget {
  const _ComponentSection({
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

/// A labelled row, so every field lines up on the same column.
class FieldRow extends StatelessWidget {
  const FieldRow({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 74,
            child: Text(label, style: OrbisText.label.copyWith(fontSize: 11.5)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A value with a slider, in real units.
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit,
    this.decimals = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? unit;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${value.toStringAsFixed(decimals)}${unit ?? ''}',
              textAlign: TextAlign.right,
              style: OrbisText.monoValue.copyWith(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three numbers that belong together, each draggable.
///
/// Dragging rather than typing, because a transform is nearly always adjusted
/// by feel against the viewport; typed entry arrives alongside undo, which it
/// needs to be safe.
class VectorRow extends StatelessWidget {
  const VectorRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.step = 0.01,
    this.decimals = 2,
    this.minimum,
  });

  final String label;

  /// Edited in place — this is the scene's own vector, not a copy.
  final Vector3 value;

  final VoidCallback onChanged;

  /// Units per logical pixel dragged.
  final double step;

  final int decimals;

  /// A floor for each component, so scale cannot be dragged through zero into
  /// a degenerate matrix.
  final double? minimum;

  // X, Y, Z tinted the way every 3D tool tints them, because the convention is
  // older than any of them and reading is faster than remembering.
  static const _axisColours = [
    Color(0xFFD9634F),
    Color(0xFF7FB069),
    Color(0xFF5B8DD9),
  ];

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: Space.xs),
            Expanded(
              child: _NumberField(
                value: value[i],
                accent: _axisColours[i],
                decimals: decimals,
                onDrag: (pixels) {
                  final next = value[i] + pixels * step;
                  value[i] = minimum == null ? next : math.max(minimum!, next);
                  onChanged();
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One draggable number.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.value,
    required this.accent,
    required this.decimals,
    required this.onDrag,
  });

  final double value;
  final Color accent;
  final int decimals;
  final ValueChanged<double> onDrag;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          decoration: BoxDecoration(
            color: _hovering ? OrbisColors.line : OrbisColors.raised,
            borderRadius: BorderRadius.circular(4),
            border: Border(left: BorderSide(color: widget.accent, width: 2)),
          ),
          alignment: Alignment.centerRight,
          child: Text(
            widget.value.toStringAsFixed(widget.decimals),
            style: OrbisText.monoValue.copyWith(fontSize: 11),
          ),
        ),
      ),
    );
  }
}

/// A short list of options, shown rather than hidden behind a menu.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    this.onSelect,
  });

  final String label;
  final List<String> options;
  final String selected;

  /// Null where there is nothing to choose — a single-option row is a
  /// statement of fact, not a control.
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Container(
        height: 24,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: OrbisColors.raised,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            for (final option in options)
              Expanded(
                child: GestureDetector(
                  onTap: onSelect == null ? null : () => onSelect!(option),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: option == selected
                          ? OrbisColors.emberDeep
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      option,
                      style: OrbisText.label.copyWith(
                        fontSize: 10.5,
                        color: option == selected
                            ? const Color(0xFFFFF0E2)
                            : OrbisColors.inkDim,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ColourRow extends StatelessWidget {
  const ColourRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Color value;
  final ValueChanged<Color> onChanged;

  // A short palette rather than a full picker: enough to see a colour change
  // reach the renderer, and a picker is a component in its own right.
  static const _swatches = [
    Color(0xFFFFF3E0),
    Color(0xFFD9634F),
    Color(0xFF7FB069),
    Color(0xFF5B8DD9),
    Color(0xFFE5B84F),
    Color(0xFF3B424C),
  ];

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Row(
        children: [
          for (final swatch in _swatches) ...[
            _Swatch(
              colour: swatch,
              selected: swatch.toARGB32() == value.toARGB32(),
              onTap: () => onChanged(swatch),
            ),
            const SizedBox(width: 3),
          ],
          const SizedBox(width: Space.xs),
          Expanded(
            child: Text(
              '#${value.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
              overflow: TextOverflow.ellipsis,
              style: OrbisText.mono.copyWith(fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }
}

class TextRow extends StatelessWidget {
  const TextRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: OrbisColors.raised,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(value, style: OrbisText.monoValue.copyWith(fontSize: 11)),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  final Color colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 20,
          width: 20,
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? OrbisColors.ember : OrbisColors.line,
              width: selected ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
