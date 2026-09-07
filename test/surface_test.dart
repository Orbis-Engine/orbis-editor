import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/surface.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  test('a material with nothing said about it is a plain grey one', () {
    const surface = Surface();
    expect(surface.metallic, 0);
    expect(surface.roughness, greaterThan(0));
    expect(surface.doubleSided, isFalse);
  });

  test('the colour is converted on the way to the file', () {
    const surface = Surface(colour: Color(0xFF808080));
    final glb = surface.toGlb();
    // Mid grey in sRGB is a good deal darker than a half in linear, which is
    // the whole reason the conversion is not skipped.
    expect(glb.colour[0], lessThan(0.3));
    expect(glb.colour[0], greaterThan(0.2));
    expect(glb.colour[3], 1.0, reason: 'opaque');
  });

  test('emissive is the colour, scaled', () {
    const dark = Surface(colour: Color(0xFFFFFFFF));
    expect(dark.toGlb().emissive, [0.0, 0.0, 0.0]);
    const lit = Surface(colour: Color(0xFFFFFFFF), emissive: 2);
    expect(lit.toGlb().emissive.first, closeTo(2, 1e-9));
  });

  test('it survives being written and read', () {
    const surface = Surface(
      name: 'Brass',
      colour: Color(0xFFB5873A),
      metallic: 1,
      roughness: 0.25,
      emissive: 0.5,
      doubleSided: true,
    );
    final back = Surface.fromJson(surface.toJson())!;
    expect(back.name, 'Brass');
    expect(back.colour.toARGB32(), surface.colour.toARGB32());
    expect(back.metallic, 1);
    expect(back.roughness, 0.25);
    expect(back.emissive, 0.5);
    expect(back.doubleSided, isTrue);
  });

  test('a defaulted material writes almost nothing', () {
    // Worth checking: a scene full of shapes would otherwise carry six
    // numbers a slot that all say what the default already says.
    expect(const Surface().toJson().keys, ['name', 'colour']);
  });

  test('rubbish reads back as nothing rather than as a default', () {
    expect(Surface.fromJson(null), isNull);
    expect(Surface.fromJson('brass'), isNull);
    expect(Surface.fromJson(const {}), isNotNull,
        reason: 'an empty map is a material nobody described');
  });

  test('slots go with the object through the scene file', () {
    final object = SceneObject(
      id: 'a',
      name: 'Steps',
      kind: ObjectKind.shape,
      shape: Shape.of(ShapeKind.stairs),
      surfaces: const [
        Surface(name: 'Stone'),
        Surface(name: 'Brass', metallic: 1),
      ],
    );
    final scene = EditorScene([object]);

    final back = SceneDocument.decode(SceneDocument.encode(scene, name: 'A'));
    final read = back.scene.objects.single;

    expect(read.surfaces, hasLength(2));
    expect(read.surfaces[1].name, 'Brass');
    expect(read.surfaces[1].metallic, 1);
  });

  test('a drawn outline goes with the object through the scene file', () {
    final object = SceneObject(
      id: 'a',
      name: 'Room',
      kind: ObjectKind.shape,
      outline: PolyShape(
        points: [
          Vector3(0, 0, 0),
          Vector3(0, 0, 2),
          Vector3(2, 0, 2),
        ],
        height: 1.5,
        flipped: true,
      ),
    );

    final back = SceneDocument.decode(
      SceneDocument.encode(EditorScene([object]), name: 'A'),
    );
    final read = back.scene.objects.single;

    expect(read.outline, isNotNull);
    expect(read.outline!.points, hasLength(3));
    expect(read.outline!.height, 1.5);
    expect(read.outline!.flipped, isTrue);
    // And it is still the shape, not just a note about how it was made.
    expect(read.currentMesh!.faceCount, 5);
  });

  test('an outline and a mesh can both be there, and the mesh wins', () {
    final object = SceneObject(
      id: 'a',
      name: 'Room',
      kind: ObjectKind.shape,
      outline: PolyShape(
        points: [
          Vector3(0, 0, 0),
          Vector3(0, 0, 2),
          Vector3(2, 0, 2),
        ],
        height: 1,
      ),
      geometry: Shape.of(ShapeKind.cube).build(),
    );

    // Because an outline cannot describe a face that has been extruded, and
    // the corners are kept only so undoing back to them is possible.
    expect(object.currentMesh!.faceCount, 6);
    expect(object.outline, isNotNull);
  });

  test('a copy of an object gets its own list of slots', () {
    final object = SceneObject(
      id: 'a',
      name: 'Steps',
      kind: ObjectKind.shape,
      surfaces: const [Surface(name: 'Stone')],
    );
    final copy = object.copy();
    copy.surfaces.add(const Surface(name: 'Added'));

    expect(object.surfaces, hasLength(1),
        reason: 'a shared list would grow both');
    expect(copy.surfaces, hasLength(2));
  });
}
