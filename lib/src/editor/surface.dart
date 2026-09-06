import 'dart:ui';

import 'package:orbis_mesh/orbis_mesh.dart';

import 'scene.dart' show EditorScene;

/// One material a shape can wear, as the editor holds it.
///
/// A slot on the object rather than a file of its own. A material made while
/// blocking out a level belongs to the thing it is on — somebody painting the
/// treads of a staircase grey is not making an asset, and asking them to name
/// and save one first is the step that stops them doing it.
///
/// Deliberately what a `.glb` can carry and no more, because that is how it
/// reaches the renderer: a face painted here becomes a primitive with a glTF
/// material beside it, and travels through exactly the path a model exported
/// from anywhere else does.
class Surface {
  const Surface({
    this.name = 'Material',
    this.colour = const Color(0xFFB9BEC6),
    this.metallic = 0.0,
    this.roughness = 0.5,
    this.emissive = 0.0,
    this.doubleSided = false,
  });

  final String name;

  /// sRGB, as somebody picked it. Converted on the way out, because the
  /// shading maths is linear and a colour handed over unconverted is washed
  /// out in a way that reads as a lighting bug.
  final Color colour;

  /// How metal it is. Physically nought or one and nothing between; the
  /// values in between are for the edge of a scratch, where one pixel covers
  /// both.
  final double metallic;

  /// How scattered its reflections are, from a mirror at nought to fully
  /// diffuse at one.
  final double roughness;

  /// How much light it gives off, in its own colour.
  final double emissive;

  /// Whether it is lit from behind as well as in front, for anything one
  /// triangle thick.
  final bool doubleSided;

  Surface copyWith({
    String? name,
    Color? colour,
    double? metallic,
    double? roughness,
    double? emissive,
    bool? doubleSided,
  }) =>
      Surface(
        name: name ?? this.name,
        colour: colour ?? this.colour,
        metallic: metallic ?? this.metallic,
        roughness: roughness ?? this.roughness,
        emissive: emissive ?? this.emissive,
        doubleSided: doubleSided ?? this.doubleSided,
      );

  /// This material as the file carries it.
  GlbMaterial toGlb() {
    final linear = EditorScene.linearFromColour(colour);
    return GlbMaterial(
      name: name,
      colour: [linear.x, linear.y, linear.z, colour.a],
      metallic: metallic,
      roughness: roughness,
      emissive: [
        linear.x * emissive,
        linear.y * emissive,
        linear.z * emissive,
      ],
      doubleSided: doubleSided,
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'colour': colour.toARGB32(),
        if (metallic != 0) 'metallic': metallic,
        if (roughness != 0.5) 'roughness': roughness,
        if (emissive != 0) 'emissive': emissive,
        if (doubleSided) 'twoSided': true,
      };

  static Surface? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    double number(String key, double fallback) =>
        map[key] is num ? (map[key]! as num).toDouble() : fallback;

    return Surface(
      name: map['name'] is String ? map['name']! as String : 'Material',
      colour: map['colour'] is int
          ? Color(map['colour']! as int)
          : const Color(0xFFB9BEC6),
      metallic: number('metallic', 0),
      roughness: number('roughness', 0.5),
      emissive: number('emissive', 0),
      doubleSided: map['twoSided'] == true,
    );
  }
}
