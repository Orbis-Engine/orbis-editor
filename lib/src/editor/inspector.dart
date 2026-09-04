import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_light/orbis_light.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'commands.dart';
import 'history.dart';
import 'scene.dart';
import 'sky.dart';
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
    this.selectionCount = 0,
  });

  /// The scene being looked at, which need not be the loaded one — a scene can
  /// be inspected before it is opened.
  final SceneEntry? entry;

  /// The object selected, or null when the scene itself is.
  final SceneObject? object;

  final History history;

  final ValueChanged<SceneEntry> onLoad;

  /// How many objects are selected. The fields below edit one of them, and
  /// saying which beats leaving somebody to guess why their changes only
  /// landed on one thing.
  final int selectionCount;

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
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (selectionCount > 1)
                            _MultipleNotice(
                              count: selectionCount,
                              name: selected.name,
                            ),
                          Expanded(
                            child: _Fields(
                              key: ValueKey(selected.id),
                              sceneId: entry.id,
                              scene: entry.scene!,
                              object: selected,
                              history: history,
                            ),
                          ),
                        ],
                      )),
          ),
        ],
      ),
    );
  }
}

/// Says that the fields below belong to one of several selected things.
class _MultipleNotice extends StatelessWidget {
  const _MultipleNotice({required this.count, required this.name});

  final int count;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      color: OrbisColors.emberWash,
      child: Row(
        children: [
          const Icon(Icons.layers_outlined, size: 13, color: OrbisColors.ember),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              '$count selected · editing $name',
              overflow: TextOverflow.ellipsis,
              style: OrbisText.caption.copyWith(color: OrbisColors.ember),
            ),
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

  /// The fog as it stands, which is every fog command's starting point.
  ({
    Color colour,
    double density,
    double height,
    double falloff,
    double mist,
    double mistSpeed,
  }) _fogOf(EditorScene scene) => (
        colour: scene.fogColour,
        density: scene.fogDensity,
        height: scene.fogHeight,
        falloff: scene.fogFalloff,
        mist: scene.mist,
        mistSpeed: scene.mistSpeed,
      );

  /// The time as it stands, likewise.
  ({double hour, bool cycle, double speed}) _timeOf(EditorScene scene) => (
        hour: scene.timeOfDay,
        cycle: scene.dayCycle,
        speed: scene.hoursPerSecond,
      );

  /// One fog edit, keeping every value nobody touched.
  void _setFog(
    EditorScene scene, {
    Color? colour,
    double? density,
    double? height,
    double? falloff,
    double? mist,
    double? mistSpeed,
    bool seal = false,
  }) {
    history.run(SetSceneFog(
      sceneId: entry.id,
      from: _fogOf(scene),
      to: (
        colour: colour ?? scene.fogColour,
        density: density ?? scene.fogDensity,
        height: height ?? scene.fogHeight,
        falloff: falloff ?? scene.fogFalloff,
        mist: mist ?? scene.mist,
        mistSpeed: mistSpeed ?? scene.mistSpeed,
      ),
    ));
    if (seal) history.seal();
  }

  /// An hour as a clock reads it.
  static String _clock(double hour) {
    final total = ((hour % 24) * 60).round();
    final hours = (total ~/ 60) % 24;
    final minutes = total % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}';
  }

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
          title: 'Sky',
          icon: Icons.schedule,
          child: Column(
            children: [
              ChoiceRow(
                label: 'Day cycle',
                options: const ['Off', 'On'],
                selected: scene.dayCycle ? 'On' : 'Off',
                onSelect: (value) {
                  final wanted = value == 'On';
                  if (wanted == scene.dayCycle) return;
                  history
                    ..run(SetSceneTime(
                      sceneId: entry.id,
                      from: _timeOf(scene),
                      to: (
                        hour: scene.timeOfDay,
                        cycle: wanted,
                        speed: scene.hoursPerSecond,
                      ),
                    ))
                    ..seal();
                },
              ),
              SliderRow(
                label: 'Time',
                value: scene.timeOfDay,
                min: 0,
                max: 24,
                decimals: 2,
                onChanged: (value) => history.run(SetSceneTime(
                  sceneId: entry.id,
                  from: _timeOf(scene),
                  to: (
                    hour: value,
                    cycle: scene.dayCycle,
                    speed: scene.hoursPerSecond,
                  ),
                )),
                onSettled: history.seal,
              ),
              TextRow(
                label: scene.dayCycle ? 'Now' : 'Set to',
                value: '${_clock(scene.currentTimeOfDay)}'
                    '  ${scene.activeBody.label}',
              ),
              if (scene.dayCycle)
                SliderRow(
                  label: 'Speed',
                  value: scene.hoursPerSecond,
                  min: 0.05,
                  max: 6,
                  decimals: 2,
                  unit: ' h/s',
                  onChanged: (value) => history.run(SetSceneTime(
                    sceneId: entry.id,
                    from: _timeOf(scene),
                    to: (
                      hour: scene.timeOfDay,
                      cycle: true,
                      speed: value,
                    ),
                  )),
                  onSettled: history.seal,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Space.md, Space.xs, Space.md, 0),
                child: Text(
                  scene.dayCycle
                      ? 'The time runs from where it is set, and the light '
                          'above the scene is whichever body is up. The scene '
                          'keeps the hour it was saved at.'
                      : 'The scene sits at this hour. The light above it is '
                          'whichever body it is set to be.',
                  style: OrbisText.caption,
                ),
              ),
            ],
          ),
        ),
        _ComponentSection(
          title: 'Environment',
          icon: Icons.wb_twilight,
          child: Column(
            children: [
              // Under a running day these are answers rather than questions:
              // a slider that cannot move is worse than a value that says
              // where it came from.
              if (scene.dayCycle) ...[
                TextRow(label: 'Sky', value: 'From the time of day'),
                TextRow(
                  label: 'Ambient',
                  value: '${scene.skyState.ambient.round()} lx',
                ),
              ] else ...[
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
            ],
          ),
        ),
        _ComponentSection(
          title: 'Fog',
          icon: Icons.foggy,
          child: Column(
            children: [
              ColourRow(
                label: 'Colour',
                value: scene.fogColour,
                onChanged: (value) =>
                    _setFog(scene, colour: value, seal: true),
              ),
              SliderRow(
                label: 'Density',
                value: scene.fogDensity,
                min: 0,
                max: 0.4,
                decimals: 3,
                onChanged: (value) => _setFog(scene, density: value),
                onSettled: history.seal,
              ),
              // Only worth showing once there is fog for them to shape. Four
              // controls over clear air are four things that do nothing.
              if (scene.fogDensity > 0) ...[
                SliderRow(
                  label: 'Height',
                  value: scene.fogHeight,
                  min: -20,
                  max: 20,
                  decimals: 1,
                  unit: ' m',
                  onChanged: (value) => _setFog(scene, height: value),
                  onSettled: history.seal,
                ),
                SliderRow(
                  label: 'Falloff',
                  value: scene.fogFalloff,
                  min: 0,
                  max: 2,
                  decimals: 2,
                  onChanged: (value) => _setFog(scene, falloff: value),
                  onSettled: history.seal,
                ),
                SliderRow(
                  label: 'Mist',
                  value: scene.mist,
                  min: 0,
                  max: 1,
                  decimals: 2,
                  onChanged: (value) => _setFog(scene, mist: value),
                  onSettled: history.seal,
                ),
                if (scene.mist > 0)
                  SliderRow(
                    label: 'Drift',
                    value: scene.mistSpeed,
                    min: 0.01,
                    max: 0.6,
                    decimals: 2,
                    onChanged: (value) => _setFog(scene, mistSpeed: value),
                    onSettled: history.seal,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Space.md, Space.xs, Space.md, 0),
                  child: Text(
                    scene.mist > 0
                        ? 'Mist is the whole layer breathing and drifting. Air '
                            'with holes in it that move separately needs noise '
                            'in the fog\'s own pass, which this is not.'
                        : 'Falloff is how fast the air clears with altitude. '
                            'Zero fills the world evenly.',
                    style: OrbisText.caption,
                  ),
                ),
              ],
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
              TextRow(
                label: 'Lights',
                value: '${scene.objects.where(
                      (o) => o.kind == ObjectKind.light,
                    ).length}',
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
          name: scene.displayNameOf(object),
          icon: scene.displayIconOf(object),
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
        if (object.kind != ObjectKind.scene) _visibility(scene),
        if (object.kind != ObjectKind.scene) _transform(),
        if (object.kind == ObjectKind.light) _light(),
        if (object.kind == ObjectKind.mesh) _mesh(),
      ],
    );
  }

  Widget _visibility(EditorScene scene) {
    // Hidden by something further up is a different state from hidden here,
    // and an object that says "shown" while nothing appears is worse than no
    // control at all.
    final hiddenAbove = object.visible && !scene.isShown(object.id);

    return _ComponentSection(
      title: 'Object',
      icon: Icons.visibility_outlined,
      child: Column(
        children: [
          ChoiceRow(
            label: 'Visible',
            options: const ['Hidden', 'Shown'],
            selected: object.visible ? 'Shown' : 'Hidden',
            onSelect: (value) {
              final wanted = value == 'Shown';
              if (wanted == object.visible) return;
              history
                ..run(SetVisible(
                  sceneId: sceneId,
                  id: object.id,
                  name: object.name,
                  to: wanted,
                ))
                ..seal();
            },
          ),
          if (hiddenAbove)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, 0),
              child: Text(
                'Hidden anyway, because something it is inside is hidden.',
                style: OrbisText.caption,
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

  /// What each light type is called in the inspector, in the order they are
  /// offered: the two an artist reaches for first, then the two that need
  /// more said about them.
  static const Map<LightType, String> _lightNames = {
    LightType.point: 'Point',
    LightType.sun: 'Sun',
    LightType.spot: 'Spot',
    LightType.area: 'Area',
  };

  Widget _light() {
    final type = object.lightType;
    final isSun = type == LightType.sun;
    final isSpot = type == LightType.spot;
    final isArea = type == LightType.area;

    // The one light everything is lit from above by. A renderer draws one, so
    // being that light is a property of the scene rather than of the object:
    // the first directional light is it.
    final isCelestial = identical(object, scene.celestial);

    return _ComponentSection(
      title: 'Light',
      icon: Icons.wb_sunny_outlined,
      child: Column(
        children: [
          if (isCelestial && isSun) ...[
            ChoiceRow(
              label: 'Body',
              options: [
                for (final body in CelestialBody.values) body.label,
              ],
              selected: scene.activeBody.label,
              // Nothing to choose while the day is running: it is above the
              // horizon or it is not, and a control that fights the clock is
              // a control that loses.
              onSelect: scene.dayCycle
                  ? null
                  : (value) {
                      final wanted = CelestialBody.values
                          .firstWhere((b) => b.label == value);
                      if (wanted == object.body) return;
                      history
                        ..run(SetCelestialBody(
                          sceneId: sceneId,
                          id: object.id,
                          name: object.name,
                          from: object.body,
                          to: wanted,
                        ))
                        ..seal();
                    },
            ),
            if (scene.dayCycle)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, 0),
                child: Text(
                  'The day cycle is deciding: whichever body is above the '
                  'horizon lights the scene, and its colour, strength and '
                  'direction come from the hour.',
                  style: OrbisText.caption,
                ),
              ),
          ],
          ChoiceRow(
            label: 'Type',
            options: _lightNames.values.toList(),
            selected: _lightNames[type]!,
            onSelect: (value) {
              final wanted = _lightNames.entries
                  .firstWhere((entry) => entry.value == value)
                  .key;
              if (wanted == type) return;
              history
                ..run(SetLightType(
                  sceneId: sceneId,
                  id: object.id,
                  name: object.name,
                  from: type,
                  to: wanted,
                  fromPower: object.power,
                  // The number means something different on the other side of
                  // this change, so it is restated rather than carried: a sun
                  // is watts per square metre and the rest are watts, and a
                  // thousand of the second is a hundred suns.
                  toPower: _powerFor(wanted, from: type, power: object.power),
                ))
                ..seal();
            },
          ),
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
            max: isSun ? 400 : 5000,
            decimals: isSun ? 1 : 0,
            unit: isSun ? ' W/m²' : ' W',
            onChanged: (value) => history.run(SetPower(
              sceneId: sceneId,
              id: object.id,
              name: object.name,
              from: object.power,
              to: value,
            )),
            onSettled: history.seal,
          ),
          if (isSpot) ...[
            SliderRow(
              label: 'Cone',
              value: object.spotSize,
              min: 1,
              max: 180,
              unit: '°',
              onChanged: (value) => _shape(size: value),
              onSettled: history.seal,
            ),
            SliderRow(
              label: 'Blend',
              value: object.spotBlend,
              min: 0,
              max: 1,
              decimals: 2,
              onChanged: (value) => _shape(blend: value),
              onSettled: history.seal,
            ),
          ],
          if (isSun)
            SliderRow(
              label: 'Sun size',
              value: object.sunAngle,
              min: 0,
              max: 12,
              decimals: 2,
              unit: '°',
              onChanged: (value) => _shape(sun: value),
              onSettled: history.seal,
            )
          else
            SliderRow(
              label: isArea ? 'Size' : 'Radius',
              value: object.sourceRadius,
              min: 0,
              max: isArea ? 4 : 1,
              decimals: 2,
              unit: ' m',
              onChanged: (value) => _shape(radius: value),
              onSettled: history.seal,
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
          Padding(
            padding:
                const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, 0),
            child: Text(
              switch (type) {
                LightType.sun =>
                  'Sun size is the width of the source in the sky. It is what '
                      'makes a shadow crisp at your feet and soft at its end.',
                LightType.area =>
                  'An area light is drawn as a point of the same power at the '
                      'centre of the shape. The falloff is right; the soft '
                      'shadow its surface would cast is not.',
                _ => 'Radius is how big the source is, not how bright. Power '
                    'stays the same and spreads over a wider surface, which '
                    'is what widens the penumbra.',
              },
              style: OrbisText.caption,
            ),
          ),
        ],
      ),
    );
  }

  /// Runs one shape edit, keeping the values that were not touched.
  void _shape({double? size, double? blend, double? radius, double? sun}) {
    history.run(SetLightShape(
      sceneId: sceneId,
      id: object.id,
      name: object.name,
      from: (
        size: object.spotSize,
        blend: object.spotBlend,
        radius: object.sourceRadius,
        sun: object.sunAngle,
      ),
      to: (
        size: size ?? object.spotSize,
        blend: blend ?? object.spotBlend,
        radius: radius ?? object.sourceRadius,
        sun: sun ?? object.sunAngle,
      ),
    ));
  }

  /// The same light, restated in the units of the type it is becoming.
  ///
  /// Watts and watts per square metre are not interchangeable, and the ratio
  /// between them here is the one the renderer already used: a point light's
  /// lumens spread over a sphere. Converting keeps the scene looking as it
  /// did, which is what somebody switching a type is expecting.
  static double _powerFor(
    LightType wanted, {
    required LightType from,
    required double power,
  }) {
    const sphere = 4 * math.pi;
    if (wanted == from) return power;
    if (wanted == LightType.sun) return power / sphere;
    if (from == LightType.sun) return power * sphere;
    return power;
  }

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
            ChoiceRow(
              label: 'Receive shadows',
              options: const ['Off', 'On'],
              selected: object.receiveShadows ? 'On' : 'Off',
              onSelect: (value) {
                final wanted = value == 'On';
                if (wanted == object.receiveShadows) return;
                history
                  ..run(SetReceiveShadows(
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
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, 0),
              child: Text(
                'A ground plane that casts shadows casts them onto itself, '
                'which is most of what makes a scene look dirty.',
                style: OrbisText.caption,
              ),
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
