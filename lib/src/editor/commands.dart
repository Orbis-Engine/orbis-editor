import 'package:flutter/material.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:orbis_weather/orbis_weather.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'history.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

import 'scene.dart';
import 'surface.dart';

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

/// Moves an object and everything under it from one scene into another.
///
/// A separate command from [MoveObject] because it is a different operation:
/// one scene loses a subtree and another gains it, and an undo has to put it
/// back in the scene it came from at the index it came from. Trying to do both
/// through one command means every field is nullable and neither case is
/// clear.
///
/// What makes it worth having at all is the shared set — the objects every
/// scene has. Without this, the only way to put something in it was to build
/// it there, and the obvious gesture of dragging a prop onto the Shared row
/// did nothing at all.
class MoveBetweenScenes extends EditorCommand {
  MoveBetweenScenes({
    required this.fromSceneId,
    required this.sceneId,
    required this.id,
    required this.name,
    required this.parentId,
    required this.index,
  });

  /// Where it came from.
  final String fromSceneId;

  /// Where it is going, which is the scene the history records this against:
  /// an undo should show the object where it will reappear.
  @override
  final String sceneId;

  final String id;
  final String name;

  /// The parent it lands under in the destination, or null for a root.
  final String? parentId;

  /// Where among its new siblings.
  final int index;

  @override
  Set<String> get touches => {sceneId, fromSceneId};

  /// What was taken out, with the indices to put it back at.
  List<({SceneObject object, int index})> _removed = const [];

  /// What actually went into the destination.
  ///
  /// The very same objects when nothing had to change, so the renderer keeps
  /// the key it knows them by and an undo puts back exactly what was there.
  /// Copies only when an id collided.
  List<SceneObject> _moved = const [];

  @override
  String get label => 'Move $name';

  @override
  void apply(SceneHost host) {
    final from = host.sceneFor(fromSceneId);
    final to = host.sceneFor(sceneId);
    final object = from?[id];
    if (from == null || to == null || object == null) return;

    // Read before the move, so the thing lands where it looked rather than
    // wherever its old local transform points under a new parent.
    final world = from.worldOf(id).clone();

    _removed = from.remove(id);

    // Two scenes can hold the same id — the starter scene names its objects
    // outright — and adding a second one would throw. Renaming on the way
    // across rather than refusing keeps the drag working.
    final clash = <String, String>{
      for (final entry in _removed)
        if (to.contains(entry.object.id))
          entry.object.id: '${entry.object.id}~${to.length}',
    };

    _moved = [
      for (final entry in _removed)
        if (clash.isEmpty)
          entry.object
        else
          entry.object.copyAs(
            id: clash[entry.object.id] ?? entry.object.id,
            parentId: entry.object.parentId == null
                ? null
                : (clash[entry.object.parentId] ?? entry.object.parentId),
          ),
    ];

    final root = _moved.first;
    root.parentId = parentId;
    for (final moving in _moved) {
      to.add(moving);
    }

    to.moveTo(root.id, parentId: parentId, index: index);
    placeInWorld(to, root, world);
  }

  @override
  void revert(SceneHost host) {
    final from = host.sceneFor(fromSceneId);
    final to = host.sceneFor(sceneId);
    if (from == null || to == null || _removed.isEmpty) return;

    to.remove(_moved.first.id);
    from.restore(_removed);
  }
}

/// Points an object at a data object, or stops pointing at one.
///
/// Attaching rather than copying: what changes here is which file the object
/// reads its settings from, and the settings themselves stay in the file where
/// everything else using them can see the same values.
class SetDataLinks extends EditorCommand {
  SetDataLinks({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.paths,
    required this.what,
  });

  @override
  final String sceneId;

  final String id;
  final String name;

  /// The whole list afterwards, rather than one path added or removed. An
  /// undo then puts back exactly what was there, including the order.
  final List<String> paths;

  /// What the step is called: "Add weight" or "Remove weight".
  final String what;

  List<String> _was = const [];

  @override
  String get label => '$what on $name';

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    _was = List<String>.from(object.data);
    object.data
      ..clear()
      ..addAll(paths);
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.data
      ..clear()
      ..addAll(_was);
    host.sceneFor(sceneId)?.invalidate();
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

/// Puts the scene into a different sort of weather.
///
/// The values come with the name, because a condition is a set of them rather
/// than a mode: once it has been applied, every one of them is free to be
/// moved, and the name is only a record of where they started.
/// Chooses which shape of cloud a sky has.
///
/// Separate from the condition because it is a separate decision: the same
/// weather makes very different skies, and somebody who has asked for cirrus
/// over a fair afternoon should keep it when they nudge the cover.
class SetCloudKind extends EditorCommand {
  SetCloudKind({
    required this.sceneId,
    required this.id,
    required this.from,
    required this.to,
    required this.fromHeight,
    required this.toHeight,
  });

  @override
  final String sceneId;

  final String id;
  final CloudKind? from;
  final CloudKind? to;

  /// Where the base sits, which moves with the shape.
  ///
  /// Cirrus is ice seven kilometres up and cumulus condense below one, so a
  /// shape that arrived without its height would arrive in the wrong place.
  /// The slider still moves it afterwards; this is only where it starts.
  final double fromHeight;
  final double toHeight;

  @override
  String get label =>
      to == null ? 'Follow the condition' : 'Set the cloud to ${to!.label.toLowerCase()}';

  @override
  void apply(SceneHost host) => _set(host, to, toHeight);

  @override
  void revert(SceneHost host) => _set(host, from, fromHeight);

  void _set(SceneHost host, CloudKind? kind, double height) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.cloudKind = kind;
    object.weather = object.weather.copyWith(cloudHeight: height);
  }
}

class SetWeatherCondition extends EditorCommand {
  SetWeatherCondition({
    required this.sceneId,
    required this.id,
    required this.from,
    required this.to,
    required this.fromState,
    required this.toState,
  });

  @override
  final String sceneId;

  final String id;
  final WeatherCondition from;
  final WeatherCondition to;
  final WeatherState fromState;
  final WeatherState toState;

  @override
  String get label => 'Set the weather to ${to.label.toLowerCase()}';

  @override
  void apply(SceneHost host) =>
      _change(host, condition: to, state: toState);

  @override
  void revert(SceneHost host) =>
      _change(host, condition: from, state: fromState);

  /// Sets the weather going rather than switching it.
  ///
  /// The change starts from what is on screen this instant, which may itself
  /// be halfway through an earlier one — otherwise changing your mind during a
  /// transition snaps back to where it set off from before starting again.
  void _change(
    SceneHost host, {
    required WeatherCondition condition,
    required WeatherState state,
  }) {
    final scene = host.sceneFor(sceneId);
    final object = scene?[id];
    if (scene == null || object == null) return;

    object.blendFrom = scene.weatherNow ?? object.weather;
    object.blendSince = scene.clock;
    object.condition = condition;
    object.weather = state;
  }
}

/// Adjusts one of the numbers behind the weather.
class SetWeatherValues extends EditorCommand {
  SetWeatherValues({
    required this.sceneId,
    required this.id,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final WeatherState from;

  /// Not final: a merged run of drags rewrites where it ends up.
  WeatherState to;

  @override
  String get label => 'Set the weather';

  @override
  Object? get mergeKey => (id, 'weather');

  @override
  void absorb(EditorCommand later) {
    if (later is SetWeatherValues) to = later.to;
  }

  @override
  void apply(SceneHost host) => _write(host, to);

  @override
  void revert(SceneHost host) => _write(host, from);

  void _write(SceneHost host, WeatherState state) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.weather = state;
    // A slider is somebody's hand on the weather. It arrives as they move it
    // rather than easing in behind them.
    object.blendFrom = null;
  }
}

/// Sets which way the wind blows, and how long a change of weather takes.
class SetWeatherWind extends EditorCommand {
  SetWeatherWind({
    required this.sceneId,
    required this.id,
    required this.from,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final ({double direction, double transition}) from;

  /// Not final: a merged run of drags rewrites where it ends up.
  ({double direction, double transition}) to;

  @override
  String get label => 'Set the wind';

  @override
  Object? get mergeKey => (id, 'wind');

  @override
  void absorb(EditorCommand later) {
    if (later is SetWeatherWind) to = later.to;
  }

  @override
  void apply(SceneHost host) => _write(host, to);

  @override
  void revert(SceneHost host) => _write(host, from);

  void _write(
    SceneHost host,
    ({double direction, double transition}) values,
  ) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.windDirection = values.direction;
    object.transitionSeconds = values.transition;
  }
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

/// Puts a prefab's contents back over an instance already in the scene.
///
/// What a revert does, and what applying changes to a prefab does to every
/// other instance of it. The whole subtree goes at once rather than field by
/// field: a prefab can gain and lose children, and a change that only ever
/// touched properties would leave the extra ones behind.
///
/// One command per instance, so undo puts an instance back exactly as it was
/// rather than approximately.
class ReplaceSubtree extends EditorCommand {
  ReplaceSubtree({
    required this.sceneId,
    required this.rootId,
    required this.objects,
    required this.what,
    this.label_ = 'Revert',
  });

  @override
  final String sceneId;

  /// The object being replaced, which keeps its id so the selection survives.
  final String rootId;

  /// The replacement, parents before children.
  final List<SceneObject> objects;

  final String what;
  final String label_;

  List<({SceneObject object, int index})> _removed = const [];

  @override
  String get label => '$label_ $what';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null || !scene.contains(rootId)) return;

    // Where it sat among its siblings, so a revert does not send it to the
    // bottom of the tree under somebody's cursor.
    final at = _removed.isEmpty ? null : _removed.first.index;
    _removed = scene.remove(rootId);

    // Kept contiguous rather than appended, so the subtree stays where it was
    // in the list and everything after it keeps its order.
    final index = at ?? _removed.first.index;
    for (var i = 0; i < objects.length; i++) {
      final into = index + i;
      scene.add(objects[i], at: into > scene.objects.length ? null : into);
    }
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null || _removed.isEmpty) return;
    scene.remove(rootId);
    scene.restore(_removed);
  }
}

/// Points an object and everything under it at a prefab.
///
/// What happens to the original when somebody drags it into the project: they
/// have made a prefab *of* this thing, and the thing they made it from should
/// be the first instance of it. Otherwise the object on screen quietly stops
/// being the one that gets the changes.
class LinkPrefab extends EditorCommand {
  LinkPrefab({
    required this.sceneId,
    required this.ids,
    required this.source,
    required this.what,
  });

  @override
  final String sceneId;

  final List<String> ids;

  /// The prefab's path, relative to the project.
  final String source;
  final String what;

  final Map<String, String?> _was = {};

  @override
  String get label => 'Make prefab $what';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    _was.clear();
    for (final id in ids) {
      final object = scene[id];
      if (object == null) continue;
      _was[id] = object.prefab;
      object.prefab = source;
    }
    scene.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    for (final entry in _was.entries) {
      scene[entry.key]?.prefab = entry.value;
    }
    scene.invalidate();
  }
}

/// Breaks an instance's link to the prefab it came from.
///
/// After this the objects are ordinary objects that happen to be shaped like
/// the prefab: nothing propagates to them and nothing propagates from them.
/// The way out for the one lamp post that has to be different.
class UnpackPrefab extends EditorCommand {
  UnpackPrefab({
    required this.sceneId,
    required this.ids,
    required this.what,
  });

  @override
  final String sceneId;

  /// The root and everything under it — the link is on every one of them.
  final List<String> ids;
  final String what;

  final Map<String, String> _was = {};

  @override
  String get label => 'Unpack $what';

  @override
  void apply(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    _was.clear();
    for (final id in ids) {
      final object = scene[id];
      final source = object?.prefab;
      if (object == null || source == null) continue;
      _was[id] = source;
      object.prefab = null;
    }
    scene.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final scene = host.sceneFor(sceneId);
    if (scene == null) return;
    for (final entry in _was.entries) {
      scene[entry.key]?.prefab = entry.value;
    }
    scene.invalidate();
  }
}

/// Changes which interface a canvas object shows.
///
/// A reference rather than a copy, like a mesh: the `.oui` is the document and
/// the scene says which one is on screen, so one interface can be on two
/// scenes and editing it changes both.
class SetInterface extends EditorCommand {
  SetInterface({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final String? to;

  String? _was;

  @override
  String get label => to == null ? 'Clear $name' : 'Set $name';

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    _was = object.interfaceAsset;
    object.interfaceAsset = to;
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.interfaceAsset = _was;
    host.sceneFor(sceneId)?.invalidate();
  }
}

/// Changes the numbers a shape is made from.
///
/// One command for the whole shape rather than one per field: the fields are
/// dragged, they interact — a cylinder's sides and its radius are the same
/// decision — and an undo stack with "width" and "sides" as separate steps is
/// one somebody has to walk back through twice.
class SetShape extends EditorCommand {
  SetShape({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  final Shape to;

  Shape? _was;

  @override
  String get label => 'Change $name';

  /// Dragging a slider produces one of these a frame; they collapse into one
  /// step, the way a dragged transform does.
  @override
  Object? get mergeKey => 'shape/$id';

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    _was ??= object.shape;
    object.shape = to;
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.shape = _was;
    host.sceneFor(sceneId)?.invalidate();
  }
}

/// Replaces an object's geometry.
///
/// What every mesh edit runs through. The whole mesh rather than the change:
/// an extrude adds vertices and faces and moves others, and describing that as
/// a diff is more code than copying a few thousand doubles — which is what a
/// mesh is, and is nothing next to a frame.
class SetGeometry extends EditorCommand {
  SetGeometry({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
    required this.what,
    this.gesture,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  Mesh to;

  /// What the step is called: "Extrude", "Inset".
  final String what;

  /// Set while a drag is running, so the hundred commands a gesture produces
  /// are one step to undo. Null for an edit that stands alone — a menu item,
  /// a tool button.
  final Object? gesture;

  @override
  Object? get mergeKey => gesture;

  @override
  void absorb(EditorCommand later) {
    if (later is! SetGeometry) return;
    // The mesh the drag has reached now, over the one it started from. The
    // `_was` this command is holding is from before the gesture began, which
    // is where undo has to land.
    to = later.to;
  }

  Mesh? _was;
  Shape? _wasShape;

  @override
  String get label => '$what $name';

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;

    _was ??= object.geometry;
    _wasShape ??= object.shape;
    object.geometry = to;
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;

    object
      ..geometry = _was
      ..shape = _wasShape;
    host.sceneFor(sceneId)?.invalidate();
  }
}


/// Replaces a shape's material slots.
///
/// The whole list rather than one slot, for the same reason geometry is the
/// whole mesh: a slot's position in the list is what a face points at, so an
/// edit to one is a fact about all of them.
class SetSurfaces extends EditorCommand {
  SetSurfaces({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
    required this.what,
    this.gesture,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  List<Surface> to;
  final String what;

  /// Set while a slider is being dragged, so a gesture is one step.
  final Object? gesture;

  @override
  Object? get mergeKey => gesture;

  List<Surface>? _was;

  @override
  String get label => '$what on $name';

  @override
  void absorb(EditorCommand later) {
    if (later is SetSurfaces) to = later.to;
  }

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    _was ??= [...object.surfaces];
    object.surfaces
      ..clear()
      ..addAll(to);
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    final was = _was;
    if (object == null || was == null) return;
    object.surfaces
      ..clear()
      ..addAll(was);
    host.sceneFor(sceneId)?.invalidate();
  }
}


/// Changes the outline a shape was drawn from.
class SetOutline extends EditorCommand {
  SetOutline({
    required this.sceneId,
    required this.id,
    required this.name,
    required this.to,
    this.gesture,
  });

  @override
  final String sceneId;

  final String id;
  final String name;
  PolyShape to;

  /// Set while a slider is moving, so the run is one step.
  final Object? gesture;

  @override
  Object? get mergeKey => gesture;

  PolyShape? _was;

  @override
  String get label => 'Reshape $name';

  @override
  void absorb(EditorCommand later) {
    if (later is SetOutline) to = later.to;
  }

  @override
  void apply(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    _was ??= object.outline;
    object.outline = to;
    host.sceneFor(sceneId)?.invalidate();
  }

  @override
  void revert(SceneHost host) {
    final object = host.sceneFor(sceneId)?[id];
    if (object == null) return;
    object.outline = _was;
    host.sceneFor(sceneId)?.invalidate();
  }
}
