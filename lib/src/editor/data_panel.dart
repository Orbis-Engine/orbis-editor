import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'colour.dart';
import 'data_object.dart';
import 'data_store.dart';
import 'inspector.dart';

/// Editing a data object, in the inspector.
///
/// The same panel a scene object gets, for a file. That is the point of a data
/// object: values are a thing somebody edits, not a thing somebody codes, and
/// putting them behind a text editor puts them out of reach of the person most
/// likely to want to change them.
///
/// Writes on every change rather than on a Save button. A data object is one
/// small file, the value is shared, and a change nobody has saved is a change
/// that is not shared yet.
class DataPanel extends StatefulWidget {
  const DataPanel({
    super.key,
    required this.path,
    required this.store,
    this.onProblem,
    this.onExportTypes,
  });

  /// Where the file is, relative to the project.
  final String path;

  final DataStore store;

  final ValueChanged<String>? onProblem;

  /// Writes the TypeScript declaration a script imports this as.
  final VoidCallback? onExportTypes;

  @override
  State<DataPanel> createState() => _DataPanelState();
}

class _DataPanelState extends State<DataPanel> {
  DataObject? get _data => widget.store[widget.path];

  Timer? _writing;

  @override
  void dispose() {
    // Whatever was still pending goes to disk rather than being lost because
    // somebody clicked away from the panel.
    if (_writing?.isActive ?? false) {
      _writing!.cancel();
      _write();
    }
    super.dispose();
  }

  /// Writes shortly after the last change.
  ///
  /// Not on every keystroke: a name being typed is eight file writes and
  /// eight notifications to everything showing the value. Not on a Save
  /// button either — the value is shared, and one nobody has saved is one
  /// that is not shared yet.
  void _save() {
    setState(() {});
    _writing?.cancel();
    _writing = Timer(const Duration(milliseconds: 300), _write);
  }

  void _write() {
    final data = _data;
    if (data == null) return;
    final problem = widget.store.write(widget.path, data);
    if (problem != null) widget.onProblem?.call(problem);
  }

  Future<void> _addField() async {
    final data = _data;
    if (data == null) return;

    final type = await showDialog<DataType>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('What kind of value?', style: OrbisText.title),
        children: [
          for (final type in DataType.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(type),
              child: Row(
                children: [
                  Icon(type.icon, size: 15, color: OrbisColors.inkMid),
                  const SizedBox(width: Space.sm),
                  Text(type.label, style: OrbisText.body),
                ],
              ),
            ),
        ],
      ),
    );
    if (type == null || !mounted) return;

    data.fields.add(DataField(
      key: data.available(type.name),
      type: type,
      value: type.blank,
    ));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    if (data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Text(
            '${p.basename(widget.path)} could not be read as a data object.',
            textAlign: TextAlign.center,
            style: OrbisText.caption,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueField(
                value: data.name,
                onChanged: (value) {
                  data.name = value;
                  _save();
                },
              ),
              const SizedBox(height: Space.xs),
              Text(widget.path, style: OrbisText.mono.copyWith(fontSize: 10.5)),
              const SizedBox(height: Space.sm),
              ValueField(
                value: data.note,
                hint: 'What this is for',
                onChanged: (value) {
                  data.note = value;
                  _save();
                },
              ),
            ],
          ),
        ),
        for (var i = 0; i < data.fields.length; i++)
          _FieldEditor(
            // Keyed by position and name together: renaming a field must not
            // rebuild it as a different one mid-keystroke, and reordering
            // must not leave a text box holding the old field's value.
            key: ValueKey('${widget.path}/$i/${data.fields[i].key}'),
            field: data.fields[i],
            onChanged: _save,
            onRemove: () {
              data.fields.removeAt(i);
              _save();
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.sm, 0),
          child: OrbisButton(
            label: 'Add a value',
            icon: Icons.add,
            expand: true,
            onPressed: _addField,
          ),
        ),
        if (widget.onExportTypes != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.sm, 0),
            child: Tooltip(
              message: 'Writes a .d.ts beside this file, so a script that '
                  'reads it is checked against these fields rather than '
                  'guessing at string keys.',
              child: OrbisButton(
                label: 'Write TypeScript types',
                icon: Icons.code,
                tone: ButtonTone.quiet,
                expand: true,
                onPressed: widget.onExportTypes,
              ),
            ),
          ),
      ],
    );
  }
}

/// One value, with whatever control its type deserves.
class _FieldEditor extends StatelessWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.onChanged,
    required this.onRemove,
  });

  final DataField field;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

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
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, 0),
            child: Row(
              children: [
                Icon(field.type.icon, size: 13, color: OrbisColors.inkDim),
                const SizedBox(width: Space.sm),
                // The key is what a script writes, so it is editable here
                // rather than fixed at the moment the field was added.
                Expanded(
                  child: ValueField(
                    value: field.key,
                    onChanged: (value) {
                      final trimmed = value.trim();
                      if (trimmed.isEmpty) return;
                      field.key = trimmed;
                      onChanged();
                    },
                  ),
                ),
                _Remove(onTap: onRemove),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: Column(
              children: [
                _control(),
                FieldRow(
                  label: 'Note',
                  child: ValueField(
                    value: field.note,
                    hint: 'What it means',
                    onChanged: (value) {
                      field.note = value;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _control() => switch (field.type) {
        DataType.number => FieldRow(
            label: 'Value',
            child: ValueField(
              value: _trim(field.asNumber),
              onChanged: (value) {
                final parsed = double.tryParse(value.trim());
                if (parsed == null) return;
                field.value = parsed;
                onChanged();
              },
            ),
          ),
        DataType.text || DataType.asset => FieldRow(
            label: 'Value',
            child: ValueField(
              value: field.asText,
              hint: field.type == DataType.asset ? 'assets/…' : null,
              onChanged: (value) {
                field.value = value;
                onChanged();
              },
            ),
          ),
        DataType.toggle => ChoiceRow(
            label: 'Value',
            options: const ['Off', 'On'],
            selected: field.asToggle ? 'On' : 'Off',
            onSelect: (value) {
              field.value = value == 'On';
              onChanged();
            },
          ),
        DataType.colour => ColourRow(
            label: 'Value',
            value: field.asColour,
            onChanged: (value) {
              field.value = hexFromColour(value);
              onChanged();
            },
          ),
        DataType.vector => Column(
            children: [
              for (final axis in const ['X', 'Y', 'Z'])
                FieldRow(
                  label: axis,
                  child: ValueField(
                    value: _trim(switch (axis) {
                      'X' => field.asVector.x,
                      'Y' => field.asVector.y,
                      _ => field.asVector.z,
                    }),
                    onChanged: (value) {
                      final parsed = double.tryParse(value.trim());
                      if (parsed == null) return;
                      final at = field.asVector;
                      field.value = switch (axis) {
                        'X' => [parsed, at.y, at.z],
                        'Y' => [at.x, parsed, at.z],
                        _ => [at.x, at.y, parsed],
                      };
                      onChanged();
                    },
                  ),
                ),
            ],
          ),
      };

  /// A number without the trailing zeros nobody typed.
  static String _trim(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return value.toString();
  }
}

class _Remove extends StatelessWidget {
  const _Remove({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Remove this value',
      child: GestureDetector(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(Space.xs),
          child: Icon(Icons.close, size: 13, color: OrbisColors.inkDim),
        ),
      ),
    );
  }
}
