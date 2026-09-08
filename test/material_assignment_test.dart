import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  OrbisCamera camera() =>
      OrbisCamera(position: Vector3(0, 2, 6), target: Vector3.zero());

  group('a texture on an object', () {
    test('becomes a material the object is drawn with', () {
      final scene = EditorScene.starter();
      final cube = scene['cube']!..materialAsset = 'assets/colormap.png';
      scene.invalidate();

      final drawn = scene.toRenderScene(camera(), projectRoot: '/proj');

      final material = drawn.materials.singleWhere(
        (m) => m.baseColourMap?.path == '/proj/assets/colormap.png',
        orElse: () => throw StateError('no material for the texture'),
      );
      final object = drawn.objects.singleWhere((o) => o.key == cube.renderKey);
      expect(object.material, material.key,
          reason: 'the object should point at the material built from it');
    });

    test('two objects sharing a texture share one material', () {
      final scene = EditorScene.starter();
      scene['cube']!.materialAsset = 'assets/colormap.png';
      scene['crate']!.materialAsset = 'assets/colormap.png';
      scene.invalidate();

      final drawn = scene.toRenderScene(camera(), projectRoot: '/proj');

      final fromTextures =
          drawn.materials.where((m) => m.baseColourMap != null).toList();
      expect(fromTextures, hasLength(1),
          reason: 'one colour map is one material, however many use it');
    });

    test('an object with no texture keeps its own materials', () {
      final scene = EditorScene.starter();
      scene.invalidate();

      final drawn = scene.toRenderScene(camera(), projectRoot: '/proj');

      for (final object in drawn.objects) {
        expect(object.material, isNull);
      }
      expect(drawn.materials.where((m) => m.baseColourMap != null), isEmpty);
    });
  });
}
