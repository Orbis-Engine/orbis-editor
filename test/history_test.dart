import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/workspace.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// One scene in a workspace, which is what a history now edits through.
({Workspace workspace, EditorScene scene, History history}) open() {
  final scene = EditorScene.starter();
  final workspace = Workspace('/project')
    ..add(SceneEntry(id: 'a', name: 'A', scene: scene));
  return (
    workspace: workspace,
    scene: scene,
    history: History(workspace),
  );
}

SetTransform move(EditorScene scene, String id, Vector3 to) => SetTransform(
      sceneId: 'a',
      id: id,
      field: TransformField.position,
      name: scene[id]!.name,
      from: scene[id]!.position,
      to: to,
    );

void main() {
  group('undo', () {
    test('puts a value back where it started', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history..run(move(scene, 'cube', Vector3(5, 0, 0)));

      expect(scene['cube']!.position.x, 5);
      history.undo();
      expect(scene['cube']!.position.x, 0);
      history.redo();
      expect(scene['cube']!.position.x, 5);
    });

    test('a drag is one step, not one per frame', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history;

      // What a slider sends: a command per pointer move.
      for (var i = 1; i <= 40; i++) {
        history.run(move(scene, 'cube', Vector3(i.toDouble(), 0, 0)));
      }

      expect(history.labels, ['Move Cube']);
      history.undo();
      // Back to before the drag began, not to the frame before it ended.
      expect(scene['cube']!.position.x, 0);
    });

    test('a whole drag of the sway slider is one undo step', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history;

      // What a drag actually sends: a command per frame the slider moved.
      for (var i = 1; i <= 20; i++) {
        history.run(SetSway(
          sceneId: 'a',
          id: 'cube',
          name: 'Cube',
          from: scene['cube']!.sway,
          to: i / 20,
        ));
      }

      expect(history.labels, ['Set Cube sway']);
      expect(scene['cube']!.sway, closeTo(1, 1e-9));

      history.undo();
      // Back to rigid, which is where the drag began — not to the frame
      // before it ended.
      expect(scene['cube']!.sway, 0);
    });

    test('sealing ends the run, so two drags are two steps', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history
        ..run(move(scene, 'cube', Vector3(1, 0, 0)))
        ..seal()
        ..run(move(scene, 'cube', Vector3(2, 0, 0)));

      expect(history.labels.length, 2);
      history.undo();
      expect(scene['cube']!.position.x, 1);
    });

    test('a different field starts its own step', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history
        ..run(move(scene, 'cube', Vector3(1, 0, 0)))
        ..run(SetTransform(
          sceneId: 'a',
          id: 'cube',
          field: TransformField.scale,
          name: 'Cube',
          from: scene['cube']!.scale,
          to: Vector3(2, 2, 2),
        ));

      expect(history.labels, ['Move Cube', 'Scale Cube']);
    });

    test('doing something new discards the redo stack', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history..run(move(scene, 'cube', Vector3(5, 0, 0)));

      history.undo();
      expect(history.canRedo, isTrue);

      history.run(SetColour(
        sceneId: 'a',
        id: 'cube',
        name: 'Cube',
        from: Colors.red,
        to: Colors.blue,
      ));
      expect(history.canRedo, isFalse);
    });

    test('names the step, so the menu can say what it undoes', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history..run(move(scene, 'cube', Vector3(5, 0, 0)));

      expect(history.undoLabel, 'Move Cube');
      history.undo();
      expect(history.undoLabel, isNull);
      expect(history.redoLabel, 'Move Cube');
    });

    test('a refused edit leaves the stack alone', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history..run(move(scene, 'cube', Vector3(5, 0, 0)));
      history.undo();

      // Refused: a thing cannot contain its own parent.
      expect(
        () => history.run(MoveObject(
          sceneId: 'a',
          id: 'props',
          name: 'Props',
          from: null,
          to: 'cube',
          fromIndex: 0,
          toIndex: 0,
        )),
        throwsA(isA<SceneError>()),
      );

      // The redo that was there before the failed edit is still there.
      expect(history.canRedo, isTrue);
      expect(history.labels, isEmpty);
    });

    test('forgets the oldest steps rather than growing without limit', () {
      final rig = open();
      final scene = rig.scene;
      final history = rig.history;

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
      final rig = open();
      final scene = rig.scene;
      final history = rig.history
        ..run(DeleteObjects(sceneId: 'a', ids: ['props'], what: 'Props'));

      expect(scene.contains('props'), isFalse);
      expect(scene.contains('cube'), isFalse, reason: 'a child was left behind');
      expect(scene.contains('crate'), isFalse);

      history.undo();
      expect(scene.contains('cube'), isTrue);
      expect(scene['cube']!.parentId, 'props');
    });

    test('puts things back in the order they were in', () {
      final rig = open();
      final scene = rig.scene;
      final before = [for (final o in scene.objects) o.id];

      rig.history
        ..run(DeleteObjects(sceneId: 'a', ids: ['props'], what: 'Props'))
        ..undo();

      expect([for (final o in scene.objects) o.id], before);
    });
  });

  group('reparenting', () {
    test('does not move the object on screen', () {
      final rig = open();
      final scene = rig.scene;
      // Props is at the origin, so give it a transform worth inheriting.
      scene['props']!.position.setValues(3, 1, -2);
      scene['props']!.rotation.setValues(0, 40, 0);
      scene.invalidate();

      final before = scene.worldOf('crate').clone();

      rig.history.run(MoveObject(
        sceneId: 'a',
        id: 'crate',
        name: 'Crate',
        from: 'props',
        to: null,
        fromIndex: scene.indexOf('crate'),
        toIndex: scene.roots.length,
      ));

      final after = scene.worldOf('crate');
      for (var i = 0; i < 16; i++) {
        expect(after.storage[i], closeTo(before.storage[i], 1e-9));
      }
    });

    test('undo returns both the parent and the local transform', () {
      final rig = open();
      final scene = rig.scene;
      scene['props']!.position.setValues(3, 1, -2);
      scene.invalidate();

      final localBefore = scene['crate']!.position.clone();
      final wasAt = scene.indexOf('crate');

      rig.history
        ..run(MoveObject(
          sceneId: 'a',
          id: 'crate',
          name: 'Crate',
          from: 'props',
          to: null,
          fromIndex: wasAt,
          toIndex: scene.roots.length,
        ))
        ..undo();

      expect(scene['crate']!.parentId, 'props');
      expect((scene['crate']!.position - localBefore).length, lessThan(1e-9));
    });

    test('refuses to put a thing inside its own child', () {
      final rig = open();
      final scene = rig.scene;
      expect(
        () => rig.history.run(MoveObject(
          sceneId: 'a',
          id: 'props',
          name: 'Props',
          from: null,
          to: 'cube',
          fromIndex: 0,
          toIndex: 0,
        )),
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

  group('reordering', () {
    List<String> namesUnder(EditorScene scene, String? parent) =>
        [for (final o in scene.siblingsOf(parent)) o.name];

    test('moves a thing among its siblings without changing its parent', () {
      final rig = open();
      final scene = rig.scene;
      expect(namesUnder(scene, 'props'), ['Cube', 'Crate']);

      rig.history.run(MoveObject(
        sceneId: 'a',
        id: 'crate',
        name: 'Crate',
        from: 'props',
        to: 'props',
        fromIndex: 1,
        toIndex: 0,
      ));

      expect(namesUnder(scene, 'props'), ['Crate', 'Cube']);
      expect(scene['crate']!.parentId, 'props');
    });

    test('a reorder does not move the object in the world', () {
      final rig = open();
      final scene = rig.scene;
      final before = scene.worldOf('crate').clone();

      rig.history.run(MoveObject(
        sceneId: 'a',
        id: 'crate',
        name: 'Crate',
        from: 'props',
        to: 'props',
        fromIndex: 1,
        toIndex: 0,
      ));

      // Only reparenting rewrites the transform; a reorder must not, or every
      // drag in the tree would nudge things by a rounding error.
      final after = scene.worldOf('crate');
      for (var i = 0; i < 16; i++) {
        expect(after.storage[i], before.storage[i]);
      }
    });

    test('undo puts it back in the order it was in', () {
      final rig = open();
      final scene = rig.scene;

      rig.history
        ..run(MoveObject(
          sceneId: 'a',
          id: 'crate',
          name: 'Crate',
          from: 'props',
          to: 'props',
          fromIndex: 1,
          toIndex: 0,
        ))
        ..undo();

      expect(namesUnder(scene, 'props'), ['Cube', 'Crate']);
    });

    test('a subtree keeps its children when it moves', () {
      final rig = open();
      final scene = rig.scene;

      rig.history.run(MoveObject(
        sceneId: 'a',
        id: 'props',
        name: 'Props',
        from: null,
        to: null,
        fromIndex: scene.indexOf('props'),
        toIndex: 0,
      ));

      expect(scene.siblingsOf(null).first.name, 'Props');
      expect(scene.childrenOf('props').length, 2,
          reason: 'the children should have come along');
    });

    test('moving to the end lands after a sibling and its children', () {
      final rig = open();
      final scene = rig.scene;

      // Sun to the very end, past Props and everything nested in it.
      rig.history.run(MoveObject(
        sceneId: 'a',
        id: 'sun',
        name: 'Sun',
        from: null,
        to: null,
        fromIndex: 0,
        toIndex: scene.roots.length,
      ));

      expect(namesUnder(scene, null).last, 'Sun');
      // And Props still owns its children rather than having Sun inserted
      // among them.
      expect(scene.childrenOf('props').length, 2);
    });
  });

  group('more than one scene', () {
    ({Workspace workspace, History history}) listed() {
      final workspace = Workspace('/project')
        ..add(SceneEntry(id: 'a', name: 'A', scene: EditorScene.starter()))
        ..add(SceneEntry(id: 'b', name: 'B', path: '/project/scenes/b.oscene'));
      return (workspace: workspace, history: History(workspace));
    }

    test('only one holds a document at a time', () {
      final rig = listed();
      expect(rig.workspace['a']!.isLoaded, isTrue);
      expect(rig.workspace['b']!.isLoaded, isFalse);
      expect(rig.workspace.loaded!.id, 'a');
    });

    test('loading one empties the other', () {
      final rig = listed();
      rig.workspace.load(rig.workspace['b']!, EditorScene.starter());

      // Nothing is left of the first but its name and its path, so there is
      // never a question about which scene an edit or a draw belongs to.
      expect(rig.workspace['a']!.isLoaded, isFalse);
      expect(rig.workspace['b']!.isLoaded, isTrue);
      expect(rig.workspace.loaded!.id, 'b');
    });

    test('a command for an unloaded scene does nothing rather than throw', () {
      final rig = listed();
      // What happens if a step outlives the scene it belongs to.
      rig.history.run(SetColour(
        sceneId: 'b', id: 'cube', name: 'Cube',
        from: Colors.red, to: Colors.blue,
      ));
      expect(rig.history.canUndo, isTrue);
      rig.history.undo();
    });

    test('unloading forgets its steps, so undo cannot reach into it', () {
      final rig = listed();
      final a = rig.workspace['a']!;

      rig.history.run(SetColour(
        sceneId: 'a', id: 'cube', name: 'Cube',
        from: a.scene!['cube']!.colour, to: Colors.red,
      ));
      expect(rig.history.canUndo, isTrue);

      // Undoing into a scene that is not loaded would be a step that appears
      // to do nothing.
      rig.history.forget('a');
      rig.workspace.unload(a);
      expect(rig.history.canUndo, isFalse);
    });

    test('an unloaded scene is never reported as having changes', () {
      final rig = listed();
      final b = rig.workspace['b']!;
      // It holds nothing to change, so there is nothing to warn about.
      expect(b.isLoaded, isFalse);
      expect(rig.history.stampFor('b'), b.savedStamp);
    });

    test('objects are only found in the loaded scene', () {
      final rig = listed();
      expect(rig.workspace.sceneHolding('cube')?.id, 'a');

      rig.workspace.unload(rig.workspace['a']!);
      expect(rig.workspace.sceneHolding('cube'), isNull);
    });

    test('a name nothing else is using', () {
      final rig = listed();
      expect(rig.workspace.availableName('A'), 'A 2');
      expect(rig.workspace.availableName('C'), 'C');
    });
  });

  group('scene settings', () {
    test('the sky is part of the scene and undoes with everything else', () {
      final rig = open();
      final scene = rig.scene;
      final was = scene.skyColour;

      rig.history.run(SetSceneSky(
        sceneId: 'a',
        fromColour: was,
        toColour: Colors.teal,
        fromAmbient: scene.ambient,
        toAmbient: 50000,
      ));

      expect(scene.skyColour, Colors.teal);
      expect(scene.ambient, 50000);

      rig.history.undo();
      expect(scene.skyColour, was);
    });

    test('dragging the ambient slider is one step', () {
      final rig = open();
      final scene = rig.scene;

      for (var i = 1; i <= 20; i++) {
        rig.history.run(SetSceneSky(
          sceneId: 'a',
          fromColour: scene.skyColour,
          toColour: scene.skyColour,
          fromAmbient: 28000,
          toAmbient: 28000 + i * 100,
        ));
      }

      expect(rig.history.labels, ['Change the sky']);
      rig.history.undo();
      expect(scene.ambient, 28000);
    });

    test('renaming the scene is undoable like anything else', () {
      final rig = open();
      rig.history.run(RenameScene(sceneId: 'a', from: 'Scene', to: 'Level 1'));
      expect(rig.scene.name, 'Level 1');
      rig.history.undo();
      expect(rig.scene.name, 'Scene');
    });
  });
}
