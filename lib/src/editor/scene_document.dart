import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'scene.dart';
import 'sky.dart';

/// The extension a scene file carries.
const String sceneExtension = '.oscene';

/// A scene read back off disk, with anything that could not be read.
///
/// Problems are returned rather than thrown. A scene with one broken object is
/// still worth opening — losing the other ninety-nine because of it is the
/// worse outcome, and the editor can say what it dropped.
class SceneLoad {
  const SceneLoad({required this.scene, this.name, this.problems = const []});

  final EditorScene scene;

  /// What the scene calls itself, which need not match the file name.
  final String? name;

  final List<String> problems;

  bool get hasProblems => problems.isNotEmpty;
}

/// Something that made a file unreadable as a whole.
class SceneFormatException implements Exception {
  const SceneFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reading and writing a scene as text.
///
/// JSON with indentation and a stable key order, because a scene file lives in
/// somebody's repository: a format that reorders itself between saves turns
/// every commit into a diff nobody can review.
abstract final class SceneDocument {
  /// Bumped when the shape changes in a way an older editor could misread.
  ///
  /// Two, because a light's power changed units. Version one stated every
  /// light in watts and converted them all as if they were bulbs; a sun is
  /// stated in watts per square metre, and reading an old number as a new one
  /// would make every outdoor scene about twelve times too bright.
  static const int formatVersion = 2;

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  static String encode(EditorScene scene, {String? name}) {
    final json = {
      'formatVersion': formatVersion,
      'name': name ?? scene.name,
      // The scene's own settings, which belong to it rather than to anything
      // in it — there was nowhere to put them until it had a row of its own.
      'sky': _hex(scene.skyColour),
      'ambient': scene.ambient,
      // Written even when there is none, because a scene that has had its fog
      // turned off should save as fog-free rather than as silent about it.
      'fog': {
        'colour': _hex(scene.fogColour),
        'density': scene.fogDensity,
        'height': scene.fogHeight,
        'falloff': scene.fogFalloff,
        'mist': scene.mist,
        'mistSpeed': scene.mistSpeed,
        'mistSize': scene.mistSize,
      },
      // The hour is what the scene was authored at, not wherever a running
      // cycle had carried it to. A clock left going should not rewrite
      // somebody's scene every time it is saved.
      'time': {
        'hour': scene.timeOfDay,
        'cycle': scene.dayCycle,
        'hoursPerSecond': scene.hoursPerSecond,
      },
      'objects': [
        for (final object in scene.objects) objectToJson(object),
      ],
    };
    return '${_encoder.convert(json)}\n';
  }

  /// One object as JSON. Shared with the clipboard, so what is copied and
  /// what is saved are the same shape.
  static Map<String, Object?> objectToJson(SceneObject object) => {
        'id': object.id,
        'name': object.name,
        'kind': object.kind.name,
        if (object.parentId != null) 'parent': object.parentId,
        'position': _vector(object.position),
        'rotation': _vector(object.rotation),
        'scale': _vector(object.scale),
        'colour': _hex(object.colour),
        if (object.kind == ObjectKind.light) ...{
          'power': object.power,
          'lightType': object.lightType.name,
          if (object.lightType == LightType.spot) ...{
            'spotSize': object.spotSize,
            'spotBlend': object.spotBlend,
          },
          if (object.lightType == LightType.sun) ...{
            'sunAngle': object.sunAngle,
            'body': object.body.name,
          } else
            'sourceRadius': object.sourceRadius,
        },
        if (object.isDrawable) ...{
          'castShadows': object.castShadows,
          'receiveShadows': object.receiveShadows,
        },
        if (object.kind == ObjectKind.light) 'castShadows': object.castShadows,
        // Only written when it is false, so the ordinary case stays out of
        // the file and out of everybody's diffs.
        if (!object.visible) 'visible': false,
        if (object.meshAsset != null) 'mesh': object.meshAsset,
      };

  /// One object from JSON, or null if it cannot be read.
  static SceneObject? objectFromJson(
    Map<String, Object?> entry, {
    int version = formatVersion,
  }) {
    final id = entry['id'];
    if (id is! String || id.isEmpty) return null;

    final kind = ObjectKind.values
        .cast<ObjectKind?>()
        .firstWhere((k) => k!.name == entry['kind'], orElse: () => null);
    if (kind == null) return null;

    return _objectFrom(entry, id: id, kind: kind, version: version);
  }

  /// The fields of an object, once its id and kind are known.
  ///
  /// One reader for the clipboard and the file, because the two have to agree:
  /// a field the file remembers and a paste forgets is a property that
  /// silently resets when somebody copies something.
  static SceneObject _objectFrom(
    Map<String, Object?> entry, {
    required String id,
    required ObjectKind kind,
    required int version,
  }) {
    double number(String key, double fallback) =>
        entry[key] is num ? (entry[key]! as num).toDouble() : fallback;
    bool flag(String key, {bool fallback = true}) =>
        entry[key] is bool ? entry[key]! as bool : fallback;

    final type = LightType.values
            .cast<LightType?>()
            .firstWhere((t) => t!.name == entry['lightType'],
                orElse: () => null) ??
        // Every light in a version-one file was drawn as a sun, whatever it
        // called itself, so that is what it is read back as.
        LightType.sun;

    var power = number('power', 1000);
    // Version one stated a light's power in watts and turned it into lux the
    // way a bulb's would be, spread over a sphere. A sun states watts per
    // square metre, so the same look is the old number over that sphere.
    if (version < 2 && kind == ObjectKind.light && type == LightType.sun) {
      power = power / (4 * 3.141592653589793);
    }

    final body = CelestialBody.values
            .cast<CelestialBody?>()
            .firstWhere((b) => b!.name == entry['body'], orElse: () => null) ??
        CelestialBody.sun;

    return SceneObject(
      id: id,
      name: entry['name'] is String ? entry['name']! as String : id,
      kind: kind,
      parentId: entry['parent'] is String ? entry['parent']! as String : null,
      position: _readVector(entry['position']),
      rotation: _readVector(entry['rotation']),
      scale: _readVector(entry['scale'], fallback: 1),
      colour: _readColour(entry['colour']),
      power: power,
      lightType: type,
      spotSize: number('spotSize', 45),
      spotBlend: number('spotBlend', 0.15),
      sourceRadius: number('sourceRadius', 0.1),
      sunAngle: number('sunAngle', 0.526),
      body: body,
      castShadows: flag('castShadows'),
      receiveShadows: flag('receiveShadows'),
      visible: flag('visible'),
      meshAsset: entry['mesh'] is String ? entry['mesh']! as String : null,
    );
  }

  static SceneLoad decode(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (error) {
      throw SceneFormatException('This is not a scene file: ${error.message}');
    }

    if (parsed is! Map<String, Object?>) {
      throw const SceneFormatException(
        'A scene file has to be a JSON object, and this one is not.',
      );
    }

    final version = parsed['formatVersion'];
    if (version is! int) {
      throw const SceneFormatException(
        'This file does not say what format version it is, so it cannot be '
        'read safely.',
      );
    }
    if (version > formatVersion) {
      // Refused rather than half-read: a newer file may mean something
      // different by the same keys, and guessing loses somebody's work.
      throw SceneFormatException(
        'This scene was written by a newer Orbis (format $version; this one '
        'reads up to $formatVersion).',
      );
    }

    final problems = <String>[];
    final objects = <SceneObject>[];
    final seen = <String>{};

    // Scenes written before objects carried transforms. The shape only
    // existed briefly, and it holds names but no positions, so it is
    // converted rather than refused — and the conversion says what it could
    // not recover instead of leaving somebody to wonder why everything is
    // stacked at the origin.
    if (parsed['objects'] == null && parsed['entities'] is List) {
      return _fromEntities(parsed['entities']! as List, parsed['name']);
    }

    final raw = parsed['objects'];
    if (raw is! List) {
      throw const SceneFormatException(
        'This scene has no list of objects in it.',
      );
    }

    for (final (index, entry) in raw.indexed) {
      if (entry is! Map<String, Object?>) {
        problems.add('Object $index is not an object, and was left out.');
        continue;
      }

      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        problems.add('Object $index has no id, and was left out.');
        continue;
      }
      if (!seen.add(id)) {
        problems.add('Two objects share the id "$id"; the second was dropped.');
        continue;
      }

      final kindName = entry['kind'];
      final kind = ObjectKind.values
          .cast<ObjectKind?>()
          .firstWhere((k) => k!.name == kindName, orElse: () => null);
      if (kind == null) {
        problems.add(
          'Object "$id" is a "$kindName", which this editor does not know '
          'about. It was left out.',
        );
        continue;
      }

      objects.add(
        _objectFrom(entry, id: id, kind: kind, version: version),
      );
    }

    // A parent that is not in the file would leave the object unreachable, so
    // it becomes a root instead of disappearing.
    for (final object in objects) {
      final parent = object.parentId;
      if (parent == null) continue;
      if (!seen.contains(parent)) {
        problems.add(
          '"${object.name}" belonged to something that is not in this file, '
          'and is now at the top level.',
        );
        object.parentId = null;
      }
    }

    _breakCycles(objects, problems);

    final name = parsed['name'] is String ? parsed['name']! as String : null;

    return SceneLoad(
      scene: EditorScene(
        objects,
        name: name ?? 'Scene',
        skyColour: parsed['sky'] == null
            ? null
            : _readColour(parsed['sky'], fallback: const Color(0xFF59616F)),
        ambient:
            parsed['ambient'] is num ? (parsed['ambient']! as num).toDouble() : 28000,
        fogColour: _readColour(
          _fogField(parsed, 'colour'),
          fallback: const Color(0xFF7D8794),
        ),
        fogDensity: _fogNumber(parsed, 'density', 0),
        fogHeight: _fogNumber(parsed, 'height', 0),
        fogFalloff: _fogNumber(parsed, 'falloff', 0.2),
        mist: _fogNumber(parsed, 'mist', 0),
        mistSpeed: _fogNumber(parsed, 'mistSpeed', 0.08),
        mistSize: _fogNumber(parsed, 'mistSize', 30),
        timeOfDay: _timeNumber(parsed, 'hour', 10),
        dayCycle: _timeField(parsed, 'cycle') is bool
            ? _timeField(parsed, 'cycle')! as bool
            : false,
        hoursPerSecond: _timeNumber(parsed, 'hoursPerSecond', 0.5),
      ),
      name: name,
      problems: problems,
    );
  }

  /// Reads the shape scenes had before they stored transforms.
  static SceneLoad _fromEntities(List entities, Object? name) {
    final objects = <SceneObject>[];

    for (final (index, entry) in entities.indexed) {
      if (entry is! Map<String, Object?>) continue;
      final components = entry['components'];
      final named = components is List ? components.join(' ') : '';

      objects.add(SceneObject(
        id: 'legacy$index',
        name: entry['name'] is String ? entry['name']! as String : 'Object',
        // The old shape said what components a thing had, which is enough to
        // tell a light from a camera from everything else.
        kind: named.contains('Light')
            ? ObjectKind.light
            : (named.contains('Camera') ? ObjectKind.camera : ObjectKind.mesh),
      ));
    }

    return SceneLoad(
      scene: EditorScene(objects, name: name is String ? name : 'Scene'),
      name: name is String ? name : null,
      problems: objects.isEmpty
          ? const []
          : [
              'This scene was written before Orbis stored positions, so its '
                  '${objects.length} objects are all at the origin.',
            ],
    );
  }

  /// Cuts any parent loop, so the tree is a tree.
  ///
  /// A hand-edited or merged file can name a loop, and a loop would hang the
  /// outliner while it drew — which is the worst place to find one.
  static void _breakCycles(List<SceneObject> objects, List<String> problems) {
    final byId = {for (final o in objects) o.id: o};

    for (final object in objects) {
      final walked = <String>{object.id};
      var current = object.parentId;
      while (current != null) {
        if (!walked.add(current)) {
          problems.add(
            '"${object.name}" was inside itself, and is now at the top level.',
          );
          object.parentId = null;
          break;
        }
        current = byId[current]?.parentId;
      }
    }
  }

  /// One field of the fog block, or null when a file predates having one.
  static Object? _fogField(Map<String, Object?> parsed, String key) {
    final fog = parsed['fog'];
    return fog is Map<String, Object?> ? fog[key] : null;
  }

  static double _fogNumber(
    Map<String, Object?> parsed,
    String key,
    double fallback,
  ) {
    final value = _fogField(parsed, key);
    return value is num ? value.toDouble() : fallback;
  }

  /// One field of the time block, or null when a file predates having one.
  static Object? _timeField(Map<String, Object?> parsed, String key) {
    final time = parsed['time'];
    return time is Map<String, Object?> ? time[key] : null;
  }

  static double _timeNumber(
    Map<String, Object?> parsed,
    String key,
    double fallback,
  ) {
    final value = _timeField(parsed, key);
    return value is num ? value.toDouble() : fallback;
  }

  static List<double> _vector(Vector3 value) => [value.x, value.y, value.z];

  static Vector3 _readVector(Object? raw, {double fallback = 0}) {
    if (raw is! List || raw.length < 3) {
      return Vector3.all(fallback);
    }
    double at(int i) => raw[i] is num ? (raw[i]! as num).toDouble() : fallback;
    return Vector3(at(0), at(1), at(2));
  }

  static String _hex(Color colour) =>
      '#${colour.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  static Color _readColour(
    Object? raw, {
    Color fallback = const Color(0xFFD9634F),
  }) {
    if (raw is! String) return fallback;
    final digits = raw.startsWith('#') ? raw.substring(1) : raw;
    final value = int.tryParse(digits, radix: 16);
    if (value == null || digits.length != 6) return fallback;
    return Color(0xFF000000 | value);
  }
}
