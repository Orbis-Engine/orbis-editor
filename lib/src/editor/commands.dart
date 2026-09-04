import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'history.dart';
import 'scene.dart';

/// Which of an object's three vectors an edit is touching.
enum TransformField {
  position('Move'),
  rotation('Rotate'),
  scale('Scale');

  const TransformField(this.verb);

  /// The word that appears next to Undo.
  final String verb;

  Vector3 of(SceneObject object) => switch (this) {
        TransformField.position => object.position,
        TransformField.rotation => object.rotation,
        TransformField.scale => object.scale,
      };
}

/// Moves, turns or resizes one object.
///
/// Holds the whole vector either side rather than one component, so a drag on
/// X and a later drag on Y merge into one "Move" step the way somebody
/// nudging a thing into place expects.
class SetTransform extends EditorCommand {
  SetTransform({
    required this.id,
    required this.field,
    required this.name,
    required Vector3 from,
    required Vector3 to,
  })  : _from = from.clone(),
        _to = to.clone();

  final String id;
  final TransformField field;

  /// Kept for the label so it survives the object being deleted and restored.
  final String name;

  final Vector3 _from;
  Vector3 _to;

  @override
  String get label => '${field.verb} $name';

  @override
  Object? get mergeKey => (id, field);

  @override
  void absorb(EditorCommand later) {
    if (later is SetTransform) _to = later._to.clone();
  }

  @override
  void apply(EditorScene scene) => _set(scene, _to);

  @override
  void revert(EditorScene scene) => _set(scene, _from);

  void _set(EditorScene scene, Vector3 value) {
    final object = scene[id];
    if (object == null) return;
    field.of(object).setFrom(value);
    scene.invalidate();
  }
}

/// Changes an object's colour.
class SetColour extends EditorCommand {
  SetColour({
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  final String id;
  final String name;
  final Color from;
  final Color to;

  @override
  String get label => 'Recolour $name';

  @override
  void apply(EditorScene scene) => scene[id]?.colour = to;

  @override
  void revert(EditorScene scene) => scene[id]?.colour = from;
}

/// Changes a light's power, in watts.
class SetPower extends EditorCommand {
  SetPower({
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  final String id;
  final String name;
  final double from;

  /// Not final: a merged run of drags rewrites where it ends up.
  double to;

  @override
  String get label => 'Set $name power';

  @override
  Object? get mergeKey => (id, 'power');

  @override
  void absorb(EditorCommand later) {
    if (later is SetPower) to = later.to;
  }

  @override
  void apply(EditorScene scene) => scene[id]?.power = to;

  @override
  void revert(EditorScene scene) => scene[id]?.power = from;
}

/// Turns shadow casting on or off.
class SetCastShadows extends EditorCommand {
  SetCastShadows({required this.id, required this.name, required this.to});

  final String id;
  final String name;
  final bool to;

  @override
  String get label => to ? 'Cast shadows from $name' : 'Stop $name casting';

  @override
  void apply(EditorScene scene) => scene[id]?.castShadows = to;

  @override
  void revert(EditorScene scene) => scene[id]?.castShadows = !to;
}

/// Renames an object.
class Rename extends EditorCommand {
  Rename({required this.id, required this.from, required this.to});

  final String id;
  final String from;

  /// Not final: typing merges into one step rather than one per keystroke.
  String to;

  @override
  String get label => 'Rename $from';

  @override
  Object? get mergeKey => (id, 'name');

  @override
  void absorb(EditorCommand later) {
    if (later is Rename) to = later.to;
  }

  @override
  void apply(EditorScene scene) => scene[id]?.name = to;

  @override
  void revert(EditorScene scene) => scene[id]?.name = from;
}

/// Moves an object to a new parent, keeping it where it looks.
///
/// The local transform is rewritten so the object does not jump when its
/// parent changes. Dropping something into a folder should not move it — an
/// editor that teleported things on reparent would be unusable for layout.
class Reparent extends EditorCommand {
  Reparent({
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  final String id;
  final String name;
  final String? from;
  final String? to;

  Vector3? _oldPosition;
  Vector3? _oldRotation;
  Vector3? _oldScale;

  @override
  String get label => 'Reparent $name';

  @override
  void apply(EditorScene scene) {
    final object = scene[id];
    if (object == null) return;

    _oldPosition = object.position.clone();
    _oldRotation = object.rotation.clone();
    _oldScale = object.scale.clone();

    final world = scene.worldOf(id).clone();
    scene.reparent(id, to);
    _placeInWorld(scene, object, world);
  }

  @override
  void revert(EditorScene scene) {
    final object = scene[id];
    if (object == null) return;
    scene.reparent(id, from);
    object.position.setFrom(_oldPosition ?? object.position);
    object.rotation.setFrom(_oldRotation ?? object.rotation);
    object.scale.setFrom(_oldScale ?? object.scale);
    scene.invalidate();
  }

  /// Sets an object's local transform so it lands on a given world matrix.
  static void _placeInWorld(
    EditorScene scene,
    SceneObject object,
    Matrix4 world,
  ) {
    final parentId = object.parentId;
    final local = parentId == null
        ? world
        : Matrix4.inverted(scene.worldOf(parentId)).multiplied(world);

    final position = Vector3.zero();
    final rotation = Quaternion.identity();
    final scale = Vector3.zero();
    local.decompose(position, rotation, scale);

    object.position.setFrom(position);
    object.rotation.setFrom(eulerDegreesOf(local));
    object.scale.setFrom(scale);
    scene.invalidate();
  }
}

/// Adds an object to the scene.
class AddObject extends EditorCommand {
  AddObject(this.object, {this.parentId});

  final SceneObject object;
  final String? parentId;

  @override
  String get label => 'Add ${object.name}';

  @override
  void apply(EditorScene scene) {
    object.parentId = parentId;
    scene.add(object);
  }

  @override
  void revert(EditorScene scene) => scene.remove(object.id);
}

/// Deletes an object and everything under it.
class DeleteObject extends EditorCommand {
  DeleteObject({required this.id, required this.name});

  final String id;
  final String name;

  List<({SceneObject object, int index})> _removed = const [];

  @override
  String get label => 'Delete $name';

  @override
  void apply(EditorScene scene) => _removed = scene.remove(id);

  @override
  void revert(EditorScene scene) => scene.restore(_removed);
}
