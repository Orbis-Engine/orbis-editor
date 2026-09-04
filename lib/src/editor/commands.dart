import 'package:flutter/material.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'history.dart';
import 'scene.dart';
import 'sky.dart';

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
    required this.sceneId,
    required this.id,
    required this.field,
    required this.name,
    required Vector3 from,
    required Vector3 to,
  })  : _from = from.clone(),
        _to = to.clone();

  @override
  final String sceneId;

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
  void apply(SceneHost host) => _set(host, _to);

  @override
  void revert(SceneHost host) => _set(host, _from);

  void _set(SceneHost host, Vector3 value) {
    final scene = host.sceneFor(sceneId);
    final object = scene?[id];
    if (scene == null || object == null) return;
    field.of(object).setFrom(value);
    scene.invalidate();
  }
}

/// Changes an object's colour.
/// Moves or turns several objects at once, as one step.
///
/// A gizmo drag with three things selected is one gesture and has to be one
/// undo. Running a command per object would merge each into its own run and
/// leave somebody pressing undo once per thing they moved together.
class TransformMany extends EditorCommand {
  TransformMany({
    required this.sceneId,
    required this.field,
    required this.what,
    required Map<String, ({Vector3 from, Vector3 to})> changes,
  }) : _changes = {
          for (final entry in changes.entries)
            entry.key: (
              from: entry.value.from.clone(),
              to: entry.value.to.clone(),
            ),
        };

  @override
  final String sceneId;

  final TransformField field;

  /// What is being moved, for the label: a name, or how many there are.
  final String what;

  final Map<String, ({Vector3 from, Vector3 to})> _changes;

  @override
  String get label => '${field.verb} $what';

  /// One key for the whole gesture rather than one per object, which is what
  /// collapses a drag into a single step however many things it moved.
  @override
  Object? get mergeKey => (sceneId, 'gizmo', field);

  @override
  void absorb(EditorCommand later) {
    if (later is! TransformMany) return;
    for (final entry in later._changes.entries) {
      final existing = _changes[entry.key];
      // Keeps where each object started and takes where it has got to, so
      // undoing the run puts everything back where the drag began.
      _changes[entry.key] = (
        from: existing?.from ?? entry.value.from.clone(),
        to: entry.value.to.clone(),
      );
    }
  }

  @override
  void apply(SceneHost host) => _write(host, (change) => change.to);

  @override
  void revert(SceneHost host) => _write(host, (change) => change.from);

  void _write(
    SceneHost host,
    Vector3 Function(({Vector3 from, Vector3 to}) change) pick,
  ) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    for (final entry in _changes.entries) {
      final object = scene[entry.key];
      if (object == null) continue;
      field.of(object).setFrom(pick(entry.value));
    }
    scene.invalidate();
  }
}

class SetColour extends EditorCommand {
  SetColour({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final Color from;
  final Color to;

  @override
  String get label => 'Recolour $name';

  @override
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.colour = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?[id]?.colour = from;
}

/// Changes a light's power, in watts.
class SetPower extends EditorCommand {
  SetPower({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

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
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.power = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?[id]?.power = from;
}

/// Changes what kind of light an object is.
///
/// The power comes with it, because the units change with the type: a sun is
/// stated in watts per square metre and everything else in watts, and keeping
/// the number while changing what it means is how a scene ends up blinding.
class SetLightType extends EditorCommand {
  SetLightType({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
    required this.fromPower,
    required this.toPower,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final LightType from;
  final LightType to;
  final double fromPower;
  final double toPower;

  @override
  String get label => 'Make $name a ${to.name}';

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.lightType = to;
    object.power = toPower;
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.lightType = from;
    object.power = fromPower;
  }
}

/// Changes a light's cone or the size of its source.
///
/// One command for the three, because they are three sliders on one shape and
/// an undo stack that distinguishes them buys nothing.
class SetLightShape extends EditorCommand {
  SetLightShape({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final ({double size, double blend, double radius, double sun}) from;

  /// Not final: a merged run of drags rewrites where it ends up.
  ({double size, double blend, double radius, double sun}) to;

  @override
  String get label => 'Shape $name';

  @override
  Object? get mergeKey => (id, 'light shape');

  @override
  void absorb(EditorCommand later) {
    if (later is SetLightShape) to = later.to;
  }

  @override
  void apply(SceneHost host) => _write(host, to);

  @override
  void revert(SceneHost host) => _write(host, from);

  void _write(
    SceneHost host,
    ({double size, double blend, double radius, double sun}) values,
  ) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.spotSize = values.size;
    object.spotBlend = values.blend;
    object.sourceRadius = values.radius;
    object.sunAngle = values.sun;
  }
}

/// Turns shadow receiving on or off.
class SetReceiveShadows extends EditorCommand {
  SetReceiveShadows({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final bool to;

  @override
  String get label =>
      to ? 'Let shadows fall on $name' : 'Keep shadows off $name';

  @override
  void apply(SceneHost host) =>
      host.sceneFor(sceneId)?[id]?.receiveShadows = to;

  @override
  void revert(SceneHost host) =>
      host.sceneFor(sceneId)?[id]?.receiveShadows = !to;
}

/// Shows or hides an object.
class SetVisible extends EditorCommand {
  SetVisible({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final bool to;

  @override
  String get label => to ? 'Show $name' : 'Hide $name';

  @override
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.visible = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?[id]?.visible = !to;
}

/// Turns shadow casting on or off.
class SetCastShadows extends EditorCommand {
  SetCastShadows({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final bool to;

  @override
  String get label => to ? 'Cast shadows from $name' : 'Stop $name casting';

  @override
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.castShadows = to;

  @override
  void revert(SceneHost host) =>
      host.sceneFor(sceneId)?[id]?.castShadows = !to;
}

/// Renames an object.
class Rename extends EditorCommand {
  Rename({
    required this.sceneId,
    required this.id,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

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
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.name = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?[id]?.name = from;
}

/// Moves an object: to a new parent, to a new place among its siblings, or
/// both.
///
/// One command rather than two, because dragging in a tree is one gesture and
/// the answer to "where did that go" should be one step of undo.
///
/// The local transform is rewritten so the object does not jump when its
/// parent changes. Dropping something into a folder should not move it — an
/// editor that teleported things on reparent would be unusable for layout.
class MoveObject extends EditorCommand {
  MoveObject({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
    required this.fromIndex,
    required this.toIndex,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final String? from;
  final String? to;
  final int fromIndex;
  final int toIndex;

  Vector3? _oldPosition;
  Vector3? _oldRotation;
  Vector3? _oldScale;

  @override
  String get label => from == to ? 'Reorder $name' : 'Move $name';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    final object = scene?[id];
    if (scene == null || object == null) return;

    _oldPosition = object.position.clone();
    _oldRotation = object.rotation.clone();
    _oldScale = object.scale.clone();

    final world = scene.worldOf(id).clone();
    scene.moveTo(id, parentId: to, index: toIndex);
    // Only when the parent actually changed: a reorder among siblings leaves
    // the transform alone, and recomposing it would introduce rounding for no
    // reason.
    if (from != to) placeInWorld(scene, object, world);
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    final object = scene?[id];
    if (scene == null || object == null) return;

    scene.moveTo(id, parentId: from, index: fromIndex);
    object.position.setFrom(_oldPosition ?? object.position);
    object.rotation.setFrom(_oldRotation ?? object.rotation);
    object.scale.setFrom(_oldScale ?? object.scale);
    scene.invalidate();
  }

}

/// Changes something about the scene itself rather than a thing in it.
class SetSceneSky extends EditorCommand {
  SetSceneSky({
    required this.sceneId,
    required this.fromColour,
    required this.toColour,
    required this.fromAmbient,
    required this.toAmbient,
  });

  @override
  final String sceneId;

  final Color fromColour;
  final Color toColour;
  final double fromAmbient;
  double toAmbient;

  @override
  String get label => 'Change the sky';

  @override
  Object? get mergeKey => (sceneId, 'sky');

  @override
  void absorb(EditorCommand later) {
    if (later is SetSceneSky) toAmbient = later.toAmbient;
  }

  @override
  void apply(SceneHost host) => _set(host, toColour, toAmbient);

  @override
  void revert(SceneHost host) => _set(host, fromColour, fromAmbient);

  void _set(SceneHost host, Color colour, double ambient) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    scene
      ..skyColour = colour
      ..ambient = ambient;
  }
}

/// Renames the scene itself.
/// Changes the air the scene is seen through.
class SetSceneFog extends EditorCommand {
  SetSceneFog({
    required this.sceneId,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final ({
    Color colour,
    double density,
    double height,
    double falloff,
    double mist,
    double mistSpeed,
  }) from;

  /// Not final: a merged run of drags rewrites where it ends up.
  ({
    Color colour,
    double density,
    double height,
    double falloff,
    double mist,
    double mistSpeed,
  }) to;

  @override
  String get label => 'Set fog';

  @override
  Object? get mergeKey => (sceneId, 'fog');

  @override
  void absorb(EditorCommand later) {
    if (later is SetSceneFog) to = later.to;
  }

  @override
  void apply(SceneHost host) => _write(host, to);

  @override
  void revert(SceneHost host) => _write(host, from);

  void _write(
    SceneHost host,
    ({
      Color colour,
      double density,
      double height,
      double falloff,
      double mist,
      double mistSpeed,
    }) values,
  ) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    scene.fogColour = values.colour;
    scene.fogDensity = values.density;
    scene.fogHeight = values.height;
    scene.fogFalloff = values.falloff;
    scene.mist = values.mist;
    scene.mistSpeed = values.mistSpeed;
  }
}

/// Changes the hour a scene is set at, and whether that hour advances.
class SetSceneTime extends EditorCommand {
  SetSceneTime({
    required this.sceneId,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final ({double hour, bool cycle, double speed}) from;

  /// Not final: a merged run of drags rewrites where it ends up.
  ({double hour, bool cycle, double speed}) to;

  @override
  String get label => from.cycle != to.cycle
      ? (to.cycle ? 'Start the day' : 'Stop the day')
      : 'Set the time';

  @override
  Object? get mergeKey => (sceneId, 'time');

  @override
  void absorb(EditorCommand later) {
    if (later is SetSceneTime) to = later.to;
  }

  @override
  void apply(SceneHost host) => _write(host, to);

  @override
  void revert(SceneHost host) => _write(host, from);

  void _write(SceneHost host, ({double hour, bool cycle, double speed}) v) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    scene.timeOfDay = v.hour;
    scene.dayCycle = v.cycle;
    scene.hoursPerSecond = v.speed;
    // A cycle that is starting begins at the hour it was set to rather than
    // wherever the clock had got to before it was last stopped.
    scene.clock = 0;
  }
}

/// Switches a light between being the sun and being the moon.
class SetCelestialBody extends EditorCommand {
  SetCelestialBody({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final CelestialBody from;
  final CelestialBody to;

  @override
  String get label => 'Make $name the ${to.label.toLowerCase()}';

  @override
  void apply(SceneHost host) => host.sceneFor(sceneId)?[id]?.body = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?[id]?.body = from;
}

class RenameScene extends EditorCommand {
  RenameScene({
    required this.sceneId,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String from;
  String to;

  @override
  String get label => 'Rename $from';

  @override
  Object? get mergeKey => (sceneId, 'sceneName');

  @override
  void absorb(EditorCommand later) {
    if (later is RenameScene) to = later.to;
  }

  @override
  void apply(SceneHost host) => host.sceneFor(sceneId)?.name = to;

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?.name = from;
}

/// Adds an object to the scene.
class AddObject extends EditorCommand {
  AddObject(this.object, {required this.sceneId, this.parentId});

  @override
  final String sceneId;

  final SceneObject object;
  final String? parentId;

  @override
  String get label => 'Add ${object.name}';

  @override
  void apply(SceneHost host) {
    object.parentId = parentId;
    host.sceneFor(sceneId)?.add(object);
  }

  @override
  void revert(SceneHost host) => host.sceneFor(sceneId)?.remove(object.id);
}

/// Puts objects into a scene, keeping the shape they had.
///
/// One command for the whole paste rather than one per object: a paste is one
/// thing somebody did, and undoing it halfway would leave a subtree with its
/// parent missing.
class PasteObjects extends EditorCommand {
  PasteObjects({
    required this.sceneId,
    required this.objects,
    required this.roots,
    required this.what,
    this.worlds = const {},
  });

  @override
  final String sceneId;

  /// In insertion order: a parent is always added before its children, so no
  /// object is ever briefly pointing at something that is not there.
  final List<SceneObject> objects;

  /// The tops of what was pasted, which is what a delete has to take.
  final List<String> roots;

  /// Where each top sat in the world when it was copied.
  ///
  /// Pasting into a scene whose parent chain is different would otherwise put
  /// the object somewhere else entirely, because a local transform only means
  /// anything relative to the parent it was measured against.
  final Map<String, Matrix4> worlds;

  final String what;

  @override
  String get label => 'Paste $what';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    for (final object in objects) {
      if (!scene.contains(object.id)) scene.add(object);
    }

    // After every object is in, so a root's new parent can be resolved.
    for (final root in roots) {
      final world = worlds[root];
      final object = scene[root];
      if (world != null && object != null) placeInWorld(scene, object, world);
    }
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    // Roots only: removing one takes everything under it, and asking for a
    // child that has already gone is not an error worth having.
    for (final root in roots) {
      scene.remove(root);
    }
  }
}

/// Deletes objects and everything under them.
///
/// One command however many are selected: deleting three things is one thing
/// somebody did, and undoing it a third at a time would be tedious and would
/// let a subtree come back without its parent.
class DeleteObjects extends EditorCommand {
  DeleteObjects({
    required this.sceneId,
    required this.ids,
    required this.what,
  });

  @override
  final String sceneId;

  final List<String> ids;
  final String what;

  final List<List<({SceneObject object, int index})>> _removed = [];

  @override
  String get label => 'Delete $what';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    _removed.clear();
    for (final id in ids) {
      // Already gone if it was inside something removed a moment ago, which is
      // not a mistake — the selection simply held a parent and its child.
      if (!scene.contains(id)) continue;
      _removed.add(scene.remove(id));
    }
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    // Backwards, so each restore puts things back at indices the ones after it
    // have not yet shifted.
    for (final batch in _removed.reversed) {
      scene.restore(batch);
    }
  }
}
