import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'commands.dart';
import 'history.dart';
import 'scene.dart';
import 'workspace.dart';

/// Properties of whatever is selected.
///
/// The fields shown depend on what the thing is, which is the whole point of
/// components: a light and a mesh are not the same object with some fields
/// greyed out, they are different sets of components on an entity.
///
/// Every field runs a command. Nothing here writes to the scene directly, so
/// there is no edit that undo does not know about.
class Inspector extends StatelessWidget {
  const Inspector({
    super.key,
    required this.entry,
    required this.object,
    required this.history,
    required this.onLoad,
  });

  /// The scene being looked at, which need not be the loaded one — a scene can
  /// be inspected before it is opened.
  final SceneEntry? entry;

  /// The object selected, or null when the scene itself is.
  final SceneObject? object;

  final History history;

  final ValueChanged<SceneEntry> onLoad;

  @override
  Widget build(BuildContext context) {
    final entry = this.entry;
    final selected = object;

    return Container(
      width: 296,
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
            child: entry == null
                ? Center(
                    child: Text('No scene loaded.', style: OrbisText.caption),
                  )
                : (selected == null
                    ? _SceneFields(
                        key: ValueKey('scene/${entry.id}'),
                        entry: entry,
                        history: history,
                        onLoad: onLoad,
                      )
                    : _Fields(
                        key: ValueKey(selected.id),
                        sceneId: entry.id,
                        scene: entry.scene!,
                        object: selected,
                        history: history,
                      )),
          ),
        ],
      ),
    );
  }
}

/// The scene's own settings.
///
/// A scene is a thing with properties, not just a container — the sky and the
/// light it casts belong to it rather than to anything in it, and there was
/// nowhere to put them until it had a row of its own.
class _SceneFields extends StatelessWidget {
  const _SceneFields({
    super.key,
    required this.entry,
    required this.history,
    required this.onLoad,
  });

  final SceneEntry entry;
  final History history;
  final ValueChanged<SceneEntry> onLoad;

  @override
  Widget build(BuildContext context) {
    final scene = entry.scene;

    // An unloaded scene has no document to show settings from. Saying where it
    // is and offering to open it beats a panel of fields that would edit
    // nothing.
    if (scene == null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        children: [
          _Header(
            name: entry.title,
            icon: Icons.public_off,
            onRename: (_) {},
            onRenameDone: () {},
            editable: false,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
            child: Text(
              entry.path ?? 'Never saved',
              overflow: TextOverflow.ellipsis,
              style: OrbisText.mono.copyWith(fontSize: 11),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: OrbisButton(
              label: 'Load scene',
              icon: Icons.folder_open,
              expand: true,
              onPressed: () => onLoad(entry),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Text(
              'Loading a scene replaces the one open. Only one scene is in the '
              'viewport at a time.',
              style: OrbisText.caption,
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      children: [
        _Header(
          name: scene.name,
          icon: Icons.public,
          onRename: (value) {
            if (value == scene.name) return;
            history.run(RenameScene(
              sceneId: entry.id,
              from: scene.name,
              to: value,
            ));
          },
          onRenameDone: history.seal,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
          child: Text(
            entry.path == null
                ? 'Not saved to a file yet'
                : entry.path!.split('/').last,
            overflow: TextOverflow.ellipsis,
            style: OrbisText.mono.copyWith(fontSize: 11),
          ),
        ),
        _ComponentSection(
          title: 'Environment',
          icon: Icons.wb_twilight,
          child: Column(
            children: [
              ColourRow(
                label: 'Sky',
                value: scene.skyColour,
                onChanged: (value) => history
                  ..run(SetSceneSky(
                    sceneId: entry.id,
                    fromColour: scene.skyColour,
                    toColour: value,
                    fromAmbient: scene.ambient,
                    toAmbient: scene.ambient,
                  ))
                  ..seal(),
              ),
              SliderRow(
                label: 'Ambient',
                value: scene.ambient,
                min: 0,
                max: 120000,
                unit: ' lx',
                onChanged: (value) => history.run(SetSceneSky(
                  sceneId: entry.id,
                  fromColour: scene.skyColour,
                  toColour: scene.skyColour,
                  fromAmbient: scene.ambient,
                  toAmbient: value,
                )),
                onSettled: history.seal,
              ),
            ],
          ),
        ),
        _ComponentSection(
          title: 'Contents',
          icon: Icons.list,
          child: Column(
            children: [
              TextRow(label: 'Objects', value: '${scene.length}'),
              TextRow(
                label: 'Drawn',
                value: '${scene.objects.where((o) => o.isDrawable).length}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Fields extends StatelessWidget {
  const _Fields({
    super.key,
    required this.sceneId,
    required this.scene,
    required this.object,
    required this.history,
  });

  final String sceneId;
  final EditorScene scene;
  final SceneObject object;
  final History history;

  @override
  Widget build(BuildContext context) {
    final parent = object.parentId == null ? null : scene[object.parentId!];

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      children: [
        _Header(
          name: object.name,
          icon: object.icon,
          onRename: (value) {
            if (value == object.name) return;
            history.run(Rename(
              sceneId: sceneId,
              id: object.id,
              from: object.name,
              to: value,
            ));
          },
          onRenameDone: history.seal,
        ),
        if (parent != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right,
                    size: 12, color: OrbisColors.inkDim),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    'in ${parent.name}',
                    overflow: TextOverflow.ellipsis,
                    style: OrbisText.caption.copyWith(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        if (object.kind != ObjectKind.scene) _transform(),
        if (object.kind == ObjectKind.light) _light(),
        if (object.kind == ObjectKind.mesh) _mesh(),
      ],
    );
  }

  Widget _transform() => _ComponentSection(
        title: 'Transform',
        icon: Icons.open_with,
        child: Column(
          children: [
            VectorRow(
              label: 'Position',
              sceneId: sceneId,
              object: object,
              field: TransformField.position,
              history: history,
              step: 0.02,
            ),
            VectorRow(
              label: 'Rotation',
              sceneId: sceneId,
              object: object,
              field: TransformField.rotation,
              history: history,
              step: 0.5,
              decimals: 1,
            ),
            VectorRow(
              label: 'Scale',
              sceneId: sceneId,
              object: object,
              field: TransformField.scale,
              history: history,
              step: 0.02,
              minimum: 0.001,
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
            const ChoiceRow(label: 'Type', options: ['Sun'], selected: 'Sun'),
            ColourRow(
              label: 'Colour',
              value: object.colour,
              onChanged: (value) => history
                ..run(SetColour(
                  sceneId: sceneId,
                  id: object.id,
                  name: object.name,
                  from: object.colour,
                  to: value,
                ))
                ..seal(),
            ),
            SliderRow(
              label: 'Power',
              value: object.power,
              min: 0,
              max: 5000,
              unit: 'W',
              onChanged: (value) => history.run(SetPower(
                sceneId: sceneId,
                id: object.id,
                name: object.name,
                from: object.power,
                to: value,
              )),
              onSettled: history.seal,
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
              onChanged: (value) => history
                ..run(SetColour(
                  sceneId: sceneId,
                  id: object.id,
                  name: object.name,
                  from: object.colour,
                  to: value,
                ))
                ..seal(),
            ),
            ChoiceRow(
              label: 'Cast shadows',
              options: const ['Off', 'On'],
              selected: object.castShadows ? 'On' : 'Off',
              onSelect: (value) {
                final wanted = value == 'On';
                if (wanted == object.castShadows) return;
                history
                  ..run(SetCastShadows(
                    sceneId: sceneId,
                    id: object.id,
                    name: object.name,
                    to: wanted,
                  ))
                  ..seal();
              },
            ),
            TextRow(
              label: 'Mesh',
              value: object.meshAsset ?? 'cube (built in)',
            ),

          ],
        ),
      );
}

/// The object's icon and its name, which is editable in place.
class _Header extends StatefulWidget {
  const _Header({
    required this.name,
    required this.icon,
    required this.onRename,
    required this.onRenameDone,
    this.editable = true,
  });

  final String name;
  final IconData icon;
  final ValueChanged<String> onRename;
  final VoidCallback onRenameDone;
  final bool editable;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.name);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Renaming merges into one undo step while the field has focus, and seals
    // when it loses it — so undo returns to the old name, not to a prefix of
    // the new one.
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onRenameDone();
    });
  }

  @override
  void didUpdateWidget(_Header oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An undo changes the name behind the field's back; without this the box
    // would go on showing what was typed.
    if (widget.name != _controller.text && !_focus.hasFocus) {
      _controller.text = widget.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: OrbisColors.emberWash,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(widget.icon, size: 13, color: OrbisColors.ember),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              readOnly: !widget.editable,
              style: OrbisText.title.copyWith(fontSize: 13.5),
              cursorColor: OrbisColors.ember,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
              onChanged: (value) {
                if (value.trim().isEmpty) return;
                widget.onRename(value.trim());
              },
              onSubmitted: (_) => widget.onRenameDone(),
            ),
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
    this.onSettled,
    this.unit,
    this.decimals = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  /// Called when the drag finishes, so a run of changes becomes one step.
  final VoidCallback? onSettled;

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
                onChangeEnd: (_) => onSettled?.call(),
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
/// by feel against the viewport. The whole drag is one undo step: the command
/// merges while the pointer is down and seals when it lifts, so undo returns
/// to where the drag started rather than stepping back through every frame.
class VectorRow extends StatelessWidget {
  const VectorRow({
    super.key,
    required this.label,
    required this.sceneId,
    required this.object,
    required this.field,
    required this.history,
    this.step = 0.01,
    this.decimals = 2,
    this.minimum,
  });

  final String label;
  final String sceneId;
  final SceneObject object;
  final TransformField field;
  final History history;

  /// Units per logical pixel dragged.
  final double step;

  final int decimals;

  /// A floor for each component, so scale cannot be dragged through zero into
  /// a matrix that cannot be inverted.
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
    final value = field.of(object);

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
                  final next = Vector3.copy(field.of(object));
                  final moved = next[i] + pixels * step;
                  next[i] = minimum == null
                      ? moved
                      : (moved < minimum! ? minimum! : moved);

                  history.run(SetTransform(
                    sceneId: sceneId,
                    id: object.id,
                    field: field,
                    name: object.name,
                    from: field.of(object),
                    to: next,
                  ));
                },
                onSettled: history.seal,
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
    required this.onSettled,
  });

  final double value;
  final Color accent;
  final int decimals;
  final ValueChanged<double> onDrag;
  final VoidCallback onSettled;

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
        onHorizontalDragEnd: (_) => widget.onSettled(),
        onHorizontalDragCancel: widget.onSettled,
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
