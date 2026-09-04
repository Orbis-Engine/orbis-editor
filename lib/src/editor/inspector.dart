import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';

/// Properties of whatever is selected.
///
/// The fields shown depend on what the thing is, which is the whole point of
/// components: a light and a mesh are not the same object with some fields
/// greyed out, they are different sets of components on an entity.
class Inspector extends StatefulWidget {
  const Inspector({super.key, required this.selected});

  final String selected;

  @override
  State<Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<Inspector> {
  // Blender's model: light power in watts, radius in metres, spot angles in
  // degrees. Real units rather than an arbitrary zero-to-one, so a value copied
  // from a reference means the same thing here.
  double _power = 1000;
  double _radius = 0.1;
  double _spotSize = 45;
  double _spotBlend = 0.15;
  Color _colour = const Color(0xFFFFF3E0);

  bool get _isLight => widget.selected == 'Sun';

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
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              children: [
                _Header(name: widget.selected),
                const _ComponentSection(
                  title: 'Transform',
                  icon: Icons.open_with,
                  child: Column(
                    children: [
                      VectorRow(label: 'Position', values: [0, 4.2, 0]),
                      VectorRow(label: 'Rotation', values: [-45, 30, 0]),
                      VectorRow(label: 'Scale', values: [1, 1, 1]),
                    ],
                  ),
                ),
                if (_isLight)
                  _ComponentSection(
                    title: 'Light',
                    icon: Icons.wb_sunny_outlined,
                    child: Column(
                      children: [
                        const ChoiceRow(
                          label: 'Type',
                          options: ['Point', 'Sun', 'Spot', 'Area'],
                          selected: 'Sun',
                        ),
                        ColourRow(
                          label: 'Colour',
                          value: _colour,
                          onChanged: (value) =>
                              setState(() => _colour = value),
                        ),
                        SliderRow(
                          label: 'Power',
                          value: _power,
                          min: 0,
                          max: 5000,
                          unit: 'W',
                          onChanged: (value) => setState(() => _power = value),
                        ),
                        SliderRow(
                          label: 'Radius',
                          value: _radius,
                          min: 0,
                          max: 2,
                          unit: 'm',
                          decimals: 2,
                          onChanged: (value) =>
                              setState(() => _radius = value),
                        ),
                        SliderRow(
                          label: 'Spot size',
                          value: _spotSize,
                          min: 1,
                          max: 180,
                          unit: '°',
                          onChanged: (value) =>
                              setState(() => _spotSize = value),
                        ),
                        SliderRow(
                          label: 'Blend',
                          value: _spotBlend,
                          min: 0,
                          max: 1,
                          decimals: 2,
                          onChanged: (value) =>
                              setState(() => _spotBlend = value),
                        ),
                      ],
                    ),
                  )
                else
                  const _ComponentSection(
                    title: 'Mesh renderer',
                    icon: Icons.view_in_ar_outlined,
                    child: Column(
                      children: [
                        ChoiceRow(
                          label: 'Cast shadows',
                          options: ['Off', 'On'],
                          selected: 'On',
                        ),
                        TextRow(label: 'Material', value: 'default.fmat'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name});

  final String name;

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
            child: const Icon(Icons.category_outlined,
                size: 13, color: OrbisColors.ember),
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

/// Three numbers that belong together.
class VectorRow extends StatelessWidget {
  const VectorRow({super.key, required this.label, required this.values});

  final String label;
  final List<double> values;

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
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                decoration: BoxDecoration(
                  color: OrbisColors.raised,
                  borderRadius: BorderRadius.circular(4),
                  border: Border(
                    left: BorderSide(color: _axisColours[i], width: 2),
                  ),
                ),
                alignment: Alignment.centerRight,
                child: Text(
                  values[i].toStringAsFixed(2),
                  style: OrbisText.monoValue.copyWith(fontSize: 11),
                ),
              ),
            ),
          ],
        ],
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
  });

  final String label;
  final List<String> options;
  final String selected;

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

  @override
  Widget build(BuildContext context) {
    return FieldRow(
      label: label,
      child: Row(
        children: [
          Container(
            height: 22,
            width: 44,
            decoration: BoxDecoration(
              color: value,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: OrbisColors.line),
            ),
          ),
          const SizedBox(width: Space.sm),
          Text(
            '#${value.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
            style: OrbisText.mono.copyWith(fontSize: 11),
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
