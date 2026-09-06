import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'colour.dart';

/// What a field in a data object holds.
///
/// A closed set rather than anything JSON can express. Every one of these has
/// an editor that knows how to show it, and a type nothing can edit is a value
/// somebody can only change by opening the file in a text editor — which is
/// the situation data objects exist to end.
enum DataType {
  number('Number', Icons.tag),
  text('Text', Icons.text_fields),
  toggle('Toggle', Icons.toggle_on_outlined),
  colour('Colour', Icons.palette_outlined),
  vector('Vector', Icons.open_with),
  asset('Asset', Icons.attachment);

  const DataType(this.label, this.icon);

  final String label;
  final IconData icon;

  /// What a field of this type starts as.
  Object? get blank => switch (this) {
        DataType.number => 0.0,
        DataType.text => '',
        DataType.toggle => false,
        DataType.colour => '#D9634F',
        DataType.vector => const [0.0, 0.0, 0.0],
        DataType.asset => '',
      };

  static DataType? named(Object? name) {
    for (final type in values) {
      if (type.name == name) return type;
    }
    return null;
  }
}

/// One named value in a data object.
class DataField {
  DataField({
    required this.key,
    required this.type,
    required this.value,
    this.note = '',
  });

  /// What scripts and the inspector call it. Unique within an object.
  String key;

  DataType type;

  /// Held as the JSON shape rather than a Dart type per field: the file is the
  /// source of truth and every reader of it — the editor, a script, a person
  /// with a text editor — sees the same thing.
  Object? value;

  /// What the field is for, shown beside it. Data outlives whoever set it.
  String note;

  double get asNumber => value is num ? (value! as num).toDouble() : 0;

  String get asText => value is String ? value! as String : '';

  bool get asToggle => value is bool ? value! as bool : false;

  Color get asColour => colourFromHex(asText, fallback: const Color(0xFFD9634F));

  Vector3 get asVector {
    final list = value;
    if (list is! List || list.length < 3) return Vector3.zero();
    return Vector3(
      (list[0] as num?)?.toDouble() ?? 0,
      (list[1] as num?)?.toDouble() ?? 0,
      (list[2] as num?)?.toDouble() ?? 0,
    );
  }

  DataField copy() =>
      DataField(key: key, type: type, value: _copyValue(value), note: note);

  static Object? _copyValue(Object? value) =>
      value is List ? List<Object?>.from(value) : value;

  Map<String, Object?> toJson() => {
        'key': key,
        'type': type.name,
        'value': value,
        if (note.isNotEmpty) 'note': note,
      };

  static DataField? fromJson(Map<String, Object?> entry) {
    final key = entry['key'];
    final type = DataType.named(entry['type']);
    if (key is! String || key.isEmpty || type == null) return null;

    return DataField(
      key: key,
      type: type,
      // A value of the wrong shape falls back to a blank of the right one
      // rather than making the whole file unreadable.
      value: _valid(type, entry['value']) ? entry['value'] : type.blank,
      note: entry['note'] is String ? entry['note']! as String : '',
    );
  }

  static bool _valid(DataType type, Object? value) => switch (type) {
        DataType.number => value is num,
        DataType.text || DataType.colour || DataType.asset => value is String,
        DataType.toggle => value is bool,
        DataType.vector => value is List && value.length >= 3,
      };
}

/// Values that live in the project rather than in a scene.
///
/// The thing a scene object is *configured by* rather than something in the
/// world: how fast the ball moves, what a crate weighs, which colour a faction
/// is. One asset, referenced by everything that needs it, so the value is
/// changed in one place and every user of it changes with it — instead of the
/// same number typed onto forty objects and thirty-nine of them missed.
///
/// It is also what lets data outlive a scene. A scene is loaded and unloaded;
/// a data object is a file, and a script, a second scene and a person with a
/// text editor can all read the same one.
class DataObject {
  DataObject({required this.name, required this.fields, this.note = ''});

  /// What it is called, which need not match the file name.
  String name;

  /// What it is for. The first thing somebody opening it in six months needs.
  String note;

  final List<DataField> fields;

  static const String marker = 'orbis.data';
  static const int formatVersion = 1;
  static const String extension = '.odata';

  /// A new one, with a field already in it.
  ///
  /// Not empty: an empty data object gives nothing to react to, and the first
  /// thing anybody does is add a field anyway.
  factory DataObject.blank(String name) => DataObject(
        name: name,
        fields: [
          DataField(key: 'value', type: DataType.number, value: 0.0),
        ],
      );

  DataField? operator [](String key) {
    for (final field in fields) {
      if (field.key == key) return field;
    }
    return null;
  }

  /// A key nothing else here is using.
  String available(String wanted) {
    if (this[wanted] == null) return wanted;
    for (var i = 2;; i++) {
      if (this['$wanted$i'] == null) return '$wanted$i';
    }
  }

  String toText() => '${const JsonEncoder.withIndent('  ').convert({
        'kind': marker,
        'formatVersion': formatVersion,
        'name': name,
        if (note.isNotEmpty) 'note': note,
        'fields': [for (final field in fields) field.toJson()],
      })}\n';

  /// Reads one, or null if it is not a data object.
  ///
  /// Null rather than an exception: a `.odata` may have been written by a
  /// newer build or edited by hand, and a browser that throws on one bad file
  /// shows nothing at all.
  static DataObject? read(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?> || parsed['kind'] != marker) return null;

    final raw = parsed['fields'];
    return DataObject(
      name: parsed['name'] is String ? parsed['name']! as String : 'Data',
      note: parsed['note'] is String ? parsed['note']! as String : '',
      fields: [
        if (raw is List)
          for (final entry in raw)
            if (entry is Map<String, Object?>) ?DataField.fromJson(entry),
      ],
    );
  }

  /// The TypeScript a script would import this as.
  ///
  /// Generated rather than written by hand, so a field renamed in the editor
  /// is a type error in the script rather than an undefined at runtime — which
  /// is the whole reason to have the data in a file the editor understands.
  String toTypeScript(String importName) {
    String typeOf(DataField field) => switch (field.type) {
          DataType.number => 'number',
          DataType.text || DataType.colour || DataType.asset => 'string',
          DataType.toggle => 'boolean',
          DataType.vector => '[number, number, number]',
        };

    final lines = [
      '// Written by the editor from $importName$extension. Do not edit.',
      '//',
      '// $name${note.isEmpty ? '' : ' — $note'}',
      '',
      'export interface ${_pascal(name)} {',
      for (final field in fields) ...[
        if (field.note.isNotEmpty) '  /** ${field.note} */',
        '  ${field.key}: ${typeOf(field)};',
      ],
      '}',
      '',
      'declare const data: ${_pascal(name)};',
      'export default data;',
      '',
    ];
    return lines.join('\n');
  }

  /// The C++ a script includes to read this.
  ///
  /// The same declaration as [toTypeScript], in the other language. Both are
  /// generated from this one object, which is the point: a field renamed here
  /// breaks the build of everything that reads it rather than quietly
  /// returning nothing at runtime.
  ///
  /// Accessors rather than a struct of values, because the value is read every
  /// frame from the file — a struct would be a copy, and a copy is exactly
  /// what a shared data object is not.
  String toCpp(String importName) {
    List<String> reader(DataField field) => switch (field.type) {
          DataType.number => [
              'inline double ${field.key}(double fallback = 0) {',
              '  return ::orbis::number(asset, "${field.key}", fallback);',
              '}',
            ],
          DataType.toggle => [
              'inline bool ${field.key}(bool fallback = false) {',
              '  return ::orbis::toggle(asset, "${field.key}", fallback);',
              '}',
            ],
          DataType.text || DataType.colour || DataType.asset => [
              'inline const char *${field.key}() {',
              '  return ::orbis::text(asset, "${field.key}");',
              '}',
            ],
          // A vector is three numbers under one key, read as three: the host
          // table carries scalars, and a struct return would be a fourth call
          // shape for the sake of one type.
          DataType.vector => [
              'inline double ${field.key}(int axis, double fallback = 0) {',
              '  static const char *const keys[3] = {',
              '      "${field.key}.x", "${field.key}.y", "${field.key}.z"};',
              '  if (axis < 0 || axis > 2) return fallback;',
              '  return ::orbis::number(asset, keys[axis], fallback);',
              '}',
            ],
        };

    final type = _pascal(name);

    return [
      '// Written by the editor from $importName$extension. Do not edit.',
      '//',
      '// $name${note.isEmpty ? '' : ' — $note'}',
      '',
      '#pragma once',
      '',
      '#include "orbis_script.h"',
      '',
      '/// Read every frame rather than copied at start: the value is a file',
      '/// somebody can change while the game is running, and that is the',
      '/// reason it is a data object rather than a constant in this header.',
      'namespace $type {',
      '',
      'inline constexpr const char *asset = "$importName$extension";',
      '',
      for (final field in fields) ...[
        if (field.note.isNotEmpty) '/// ${field.note}',
        ...reader(field),
        '',
      ],
      '}  // namespace $type',
      '',
    ].join('\n');
  }

  static String _pascal(String words) {
    final parts = words
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty);
    if (parts.isEmpty) return 'Data';
    final joined = [
      for (final part in parts) part[0].toUpperCase() + part.substring(1),
    ].join();
    // A type name cannot start with a digit, and a data object called "3rd
    // faction" is a perfectly reasonable thing to have.
    return RegExp(r'^[0-9]').hasMatch(joined) ? 'Data$joined' : joined;
  }
}
