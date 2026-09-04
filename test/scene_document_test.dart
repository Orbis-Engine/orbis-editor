import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  group('a scene survives a trip to disk and back', () {
    test('every object comes back the same', () {
      final before = EditorScene.starter();
      before['cube']!
        ..position.setValues(1.5, -2.25, 0.125)
        ..rotation.setValues(-40, 15.5, 90)
        ..scale.setValues(2, 0.5, 3)
        ..meshAsset = 'assets/meshes/crate.glb'
        ..castShadows = false;
      before.invalidate();

      final after = SceneDocument.decode(SceneDocument.encode(before)).scene;

      expect(after.length, before.length);
      for (final original in before.objects) {
        final copy = after[original.id]!;
        expect(copy.name, original.name);
        expect(copy.kind, original.kind);
        expect(copy.parentId, original.parentId);
        expect(copy.colour.toARGB32(), original.colour.toARGB32());
        expect(copy.castShadows, original.castShadows);
        expect(copy.meshAsset, original.meshAsset);
        for (final pair in [
          (copy.position, original.position),
          (copy.rotation, original.rotation),
          (copy.scale, original.scale),
        ]) {
          expect((pair.$1 - pair.$2).length, lessThan(1e-9),
              reason: '${original.name} moved');
        }
      }
    });

    test('the hierarchy comes back, not just the objects', () {
      final after =
          SceneDocument.decode(SceneDocument.encode(EditorScene.starter()))
              .scene;
      expect(after['cube']!.parentId, 'props');
      expect(after.childrenOf('props').length, 2);
    });

    test('writing the same scene twice gives the same bytes', () {
      // A file that reorders itself between saves turns every commit into a
      // diff nobody can review.
      final scene = EditorScene.starter();
      expect(SceneDocument.encode(scene), SceneDocument.encode(scene));
    });

    test('an empty scene is a valid file, not an error', () {
      final load = SceneDocument.decode(SceneDocument.encode(EditorScene([])));
      expect(load.scene.length, 0);
      expect(load.hasProblems, isFalse);
    });
  });

  group('a file that is wrong in some way', () {
    test('is refused outright when it is not JSON', () {
      expect(
        () => SceneDocument.decode('this is not a scene'),
        throwsA(isA<SceneFormatException>()),
      );
    });

    test('is refused when it comes from a newer editor', () {
      // Rather than half-read: a newer file may mean something different by
      // the same keys, and guessing loses somebody's work.
      expect(
        () => SceneDocument.decode('{"formatVersion": 99, "objects": []}'),
        throwsA(isA<SceneFormatException>()),
      );
    });

    test('is refused when it does not say what version it is', () {
      expect(
        () => SceneDocument.decode('{"objects": []}'),
        throwsA(isA<SceneFormatException>()),
      );
    });

    test('keeps the objects it can read and reports the ones it cannot', () {
      final load = SceneDocument.decode('''
{
  "formatVersion": 1,
  "objects": [
    {"id": "a", "name": "Good", "kind": "mesh"},
    {"id": "b", "name": "Odd", "kind": "hologram"},
    {"name": "Nameless", "kind": "mesh"}
  ]
}
''');

      expect(load.scene.length, 1, reason: 'the good one should survive');
      expect(load.problems.length, 2);
      expect(load.problems.join(), contains('hologram'));
    });

    test('an object whose parent is missing becomes a root, not a ghost', () {
      final load = SceneDocument.decode('''
{
  "formatVersion": 1,
  "objects": [{"id": "a", "name": "Orphan", "kind": "mesh", "parent": "gone"}]
}
''');

      expect(load.scene['a']!.parentId, isNull);
      expect(load.scene.roots.length, 1);
      expect(load.problems.single, contains('Orphan'));
    });

    test('a parent loop is cut rather than left to hang the outliner', () {
      final load = SceneDocument.decode('''
{
  "formatVersion": 1,
  "objects": [
    {"id": "a", "name": "A", "kind": "group", "parent": "b"},
    {"id": "b", "name": "B", "kind": "group", "parent": "a"}
  ]
}
''');

      expect(load.hasProblems, isTrue);
      // Whichever was cut, walking up from either now terminates.
      expect(load.scene.depthOf('a'), lessThan(3));
      expect(load.scene.roots, isNotEmpty);
    });

    test('missing numbers fall back rather than becoming NaN', () {
      final load = SceneDocument.decode('''
{
  "formatVersion": 1,
  "objects": [{"id": "a", "name": "A", "kind": "mesh", "scale": [1]}]
}
''');

      // A short scale array would otherwise read as zero and make the object
      // vanish into a matrix that cannot be inverted.
      expect(load.scene['a']!.scale, Vector3(1, 1, 1));
    });

    test('a colour that is not a colour falls back to something visible', () {
      final load = SceneDocument.decode('''
{
  "formatVersion": 1,
  "objects": [{"id": "a", "name": "A", "kind": "mesh", "colour": "not a hex"}]
}
''');
      expect(load.scene['a']!.colour.a, 1.0);
    });
  });

  test('colours are written as hex somebody can read in a diff', () {
    final scene = EditorScene([
      SceneObject(
        id: 'a',
        name: 'A',
        kind: ObjectKind.mesh,
        colour: const Color(0xFFD9634F),
      ),
    ]);
    expect(SceneDocument.encode(scene), contains('"#D9634F"'));
  });

  group('what a new project starts with', () {
    // The seam where a format drifts without anyone noticing: the launcher
    // writes the file and the editor reads it, and nothing else joins them up.
    for (final template in ProjectTemplate.values) {
      test('the ${template.label} template opens in the editor', () {
        final written = SceneDocument.encode(sceneFor(template));
        final load = SceneDocument.decode(written);

        expect(load.hasProblems, isFalse,
            reason: load.problems.join('; '));
        expect(load.scene.length, sceneFor(template).length);
      });
    }

    test('the empty template really is empty', () {
      expect(sceneFor(ProjectTemplate.empty).length, 0);
    });

    test('a lit scene has something to light and something to light it', () {
      final scene = sceneFor(ProjectTemplate.scene);
      expect(scene.objects.any((o) => o.kind == ObjectKind.light), isTrue);
      expect(scene.objects.any((o) => o.isDrawable), isTrue);
    });
  });
}
