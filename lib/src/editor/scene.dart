import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// What kind of thing an object is, which decides what components it has and
/// therefore what the inspector shows.
enum ObjectKind { scene, mesh, light, camera }

/// One object in the edited scene.
///
/// Mutable and plain: the editor's document lives here, and a value type would
/// mean rebuilding the list on every drag of a slider.
class SceneObject {
  SceneObject({
    required this.name,
    required this.kind,
    Vector3? position,
    Vector3? rotation,
    Vector3? scale,
    this.colour = const Color(0xFFD9634F),
    this.power = 1000,
    this.castShadows = true,
  })  : position = position ?? Vector3.zero(),
        rotation = rotation ?? Vector3.zero(),
        scale = scale ?? Vector3(1, 1, 1);

  final String name;
  final ObjectKind kind;

  final Vector3 position;

  /// Euler angles in degrees, XYZ order — the units the inspector shows, kept
  /// as the source of truth so a value typed in comes back out unchanged
  /// instead of round-tripping through a quaternion and drifting.
  final Vector3 rotation;

  final Vector3 scale;

  Color colour;

  /// Light power in watts. Ignored by anything that is not a light.
  double power;

  bool castShadows;

  IconData get icon => switch (kind) {
        ObjectKind.scene => Icons.public,
        ObjectKind.mesh => Icons.view_in_ar_outlined,
        ObjectKind.light => Icons.wb_sunny_outlined,
        ObjectKind.camera => Icons.videocam_outlined,
      };

  /// The object's local-to-world matrix.
  Matrix4 get transform => Matrix4.compose(
        position,
        Quaternion.euler(
          radians(rotation.z),
          radians(rotation.y),
          radians(rotation.x),
        ),
        scale,
      );

  /// Where this object points: -Z, the way every 3D tool defines forward.
  Vector3 get forward =>
      transform.getRotation().transposed().transform(Vector3(0, 0, -1))
        ..normalize();
}

/// The scene being edited.
class EditorScene {
  EditorScene(this.objects);

  /// A default scene, so a new project opens on something rather than nothing.
  ///
  /// The ground is a flattened box rather than a plane because the renderer
  /// draws boxes and nothing else yet; when meshes load it becomes a mesh.
  factory EditorScene.starter() => EditorScene([
        SceneObject(name: 'Scene', kind: ObjectKind.scene),
        SceneObject(
          name: 'Sun',
          kind: ObjectKind.light,
          rotation: Vector3(-55, 35, 0),
          colour: const Color(0xFFFFF3E0),
          power: 1400,
        ),
        SceneObject(
          name: 'Ground',
          kind: ObjectKind.mesh,
          position: Vector3(0, -1.05, 0),
          scale: Vector3(8, 0.05, 8),
          colour: const Color(0xFF3B424C),
        ),
        SceneObject(
          name: 'Cube',
          kind: ObjectKind.mesh,
          rotation: Vector3(0, 25, 0),
          colour: const Color(0xFFD9634F),
        ),
        SceneObject(
          name: 'Camera',
          kind: ObjectKind.camera,
          position: Vector3(6, 4, 8),
          rotation: Vector3(-20, 35, 0),
        ),
      ]);

  final List<SceneObject> objects;

  SceneObject byName(String name) =>
      objects.firstWhere((object) => object.name == name);

  /// Everything the renderer draws, viewed from [camera].
  ///
  /// The viewport's camera is passed in rather than taken from the scene's
  /// Camera object: the scene view and the game camera are separate things,
  /// and moving one should not move the other.
  OrbisScene toRenderScene(OrbisCamera camera) {
    final light = objects.firstWhere(
      (object) => object.kind == ObjectKind.light,
      orElse: () => SceneObject(name: 'Sun', kind: ObjectKind.light),
    );

    return OrbisScene(
      objects: [
        for (final object in objects)
          if (object.kind == ObjectKind.mesh)
            OrbisObject(
              transform: object.transform,
              colour: linearFromColour(object.colour),
            ),
      ],
      sun: OrbisSun(
        direction: light.forward,
        colour: linearFromColour(light.colour),
        // Watts to lux through the same 683 lm/W the light package uses, so a
        // number set here means what it means in Blender.
        illuminance: light.power * 683 / 12.566370614359172,
      ),
      camera: camera,
    );
  }

  /// sRGB to linear, because the shading maths is linear and a colour handed
  /// over unconverted is washed out in a way that reads as a lighting bug.
  static Vector3 linearFromColour(Color colour) => Vector3(
        _linear(colour.r),
        _linear(colour.g),
        _linear(colour.b),
      );

  static double _linear(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}
