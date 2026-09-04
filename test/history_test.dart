import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

SetTransform move(EditorScene scene, String id, Vector3 to) => SetTransform(
      id: id,
      field: TransformField.position,
      name: scene[id]!.name,
      from: scene[id]!.position,
      to: to,
    );

void main() {
  group('undo', () {
    test('puts a value back where it started', () {
      final scene = EditorScene.starter();
      final history = History(scene)..run(move(scene, 'cube', Vector3(5, 0, 0)));

      expect(scene['cube']!.position.x, 5);
      history.undo();
      expect(scene['cube']!.position.x, 0);
      history.redo();
      expect(scene['cube']!.position.x, 5);
    });

    test('a drag is one step, not one per frame', () {
      final scene = EditorScene.starter();
      final history = History(scene);

      // What a slider sends: a command per pointer move.
      for (var i = 1; i <= 40; i++) {
        history.run(move(scene, 'cube', Vector3(i.toDouble(), 0, 0)));
      }

      expect(history.labels, ['Move Cube']);
      history.undo();
      // Back to before the drag began, not to the frame before it ended.
      expect(scene['cube']!.position.x, 0);
    });

    test('sealing ends the run, so two drags are two steps', () {
      final scene = EditorScene.starter();
      final history = History(scene)
        ..run(move(scene, 'cube', Vector3(1, 0, 0)))
        ..seal()
        ..run(move(scene, 'cube', Vector3(2, 0, 0)));

      expect(history.labels.length, 2);
      history.undo();
      expect(scene['cube']!.position.x, 1);
    });

    test('a different field starts its own step', () {
      final scene = EditorScene.starter();
      final history = History(scene)
        ..run(move(scene, 'cube', Vector3(1, 0, 0)))
        ..run(SetTransform(
          id: 'cube',
          field: TransformField.scale,
          name: 'Cube',
          from: scene['cube']!.scale,
          to: Vector3(2, 2, 2),
        ));

      expect(history.labels, ['Move Cube', 'Scale Cube']);
    });

    test('doing something new discards the redo stack', () {
      final scene = EditorScene.starter();
      final history = History(scene)..run(move(scene, 'cube', Vector3(5, 0, 0)));

      history.undo();
      expect(history.canRedo, isTrue);

      history.run(SetColour(
        id: 'cube', name: 'Cube', from: Colors.red, to: Colors.blue,
      ));
      expect(history.canRedo, isFalse);
    });

    test('names the step, so the menu can say what it undoes', () {
      final scene = EditorScene.starter();
      final history = History(scene)..run(move(scene, 'cube', Vector3(5, 0, 0)));

      expect(history.undoLabel, 'Move Cube');
      history.undo();
      expect(history.undoLabel, isNull);
      expect(history.redoLabel, 'Move Cube');
    });

    test('a refused edit leaves the stack alone', () {
      final scene = EditorScene.starter();
      final history = History(scene)..run(move(scene, 'cube', Vector3(5, 0, 0)));
      history.undo();

      // Refused: a thing cannot contain its own parent.
      expect(
        () => history.run(Reparent(
          id: 'props', name: 'Props', from: null, to: 'cube',
        )),
        throwsA(isA<SceneError>()),
      );

      // The redo that was there before the failed edit is still there.
      expect(history.canRedo, isTrue);
      expect(history.labels, isEmpty);
    });

    test('forgets the oldest steps rather than growing without limit', () {
      final scene = EditorScene.starter();
      final history = History(scene);

      for (var i = 0; i < History.limit + 20; i++) {
        history
          ..run(move(scene, 'cube', Vector3(i.toDouble(), 0, 0)))
          ..seal();
      }

      expect(history.labels.length, History.limit);
    });
  });

  group('deleting', () {
    test('takes the children with it and brings them back', () {
      final scene = EditorScene.starter();
      final history = History(scene)
        ..run(DeleteObject(id: 'props', name: 'Props'));

      expect(scene.contains('props'), isFalse);
      expect(scene.contains('cube'), isFalse, reason: 'a child was left behind');
      expect(scene.contains('crate'), isFalse);

      history.undo();
      expect(scene.contains('cube'), isTrue);
      expect(scene['cube']!.parentId, 'props');
    });

    test('puts things back in the order they were in', () {
      final scene = EditorScene.starter();
      final before = [for (final o in scene.objects) o.id];

      History(scene)
        ..run(DeleteObject(id: 'props', name: 'Props'))
        ..undo();

      expect([for (final o in scene.objects) o.id], before);
    });
  });

  group('reparenting', () {
    test('does not move the object on screen', () {
      final scene = EditorScene.starter();
      // Props is at the origin, so give it a transform worth inheriting.
      scene['props']!.position.setValues(3, 1, -2);
      scene['props']!.rotation.setValues(0, 40, 0);
      scene.invalidate();

      final before = scene.worldOf('crate').clone();

      History(scene).run(
        Reparent(id: 'crate', name: 'Crate', from: 'props', to: null),
      );

      final after = scene.worldOf('crate');
      for (var i = 0; i < 16; i++) {
        expect(after.storage[i], closeTo(before.storage[i], 1e-9));
      }
    });

    test('undo returns both the parent and the local transform', () {
      final scene = EditorScene.starter();
      scene['props']!.position.setValues(3, 1, -2);
      scene.invalidate();

      final localBefore = scene['crate']!.position.clone();

      History(scene)
        ..run(Reparent(id: 'crate', name: 'Crate', from: 'props', to: null))
        ..undo();

      expect(scene['crate']!.parentId, 'props');
      expect((scene['crate']!.position - localBefore).length, lessThan(1e-9));
    });

    test('refuses to put a thing inside its own child', () {
      final scene = EditorScene.starter();
      expect(
        () => History(scene).run(
          Reparent(id: 'props', name: 'Props', from: null, to: 'cube'),
        ),
        throwsA(isA<SceneError>()),
      );
      // And the tree is untouched, rather than half-moved.
      expect(scene['props']!.parentId, isNull);
      expect(scene['cube']!.parentId, 'props');
    });
  });

  group('the hierarchy', () {
    test('a child inherits its parent transform', () {
      final scene = EditorScene.starter();
      scene['props']!.position.setValues(10, 0, 0);
      scene.invalidate();

      expect(scene.worldOf('cube').getTranslation().x, 10);
    });

    test('world matrices are recomputed after an edit, not cached stale', () {
      final scene = EditorScene.starter();
      expect(scene.worldOf('cube').getTranslation().x, 0);

      scene['props']!.position.setValues(4, 0, 0);
      scene.invalidate();

      expect(scene.worldOf('cube').getTranslation().x, 4);
    });

    test('depth is what the outliner indents by', () {
      final scene = EditorScene.starter();
      expect(scene.depthOf('props'), 0);
      expect(scene.depthOf('cube'), 1);
    });
  });
}
