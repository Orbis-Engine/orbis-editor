import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/prefab.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// A lamp post: a group with a post and a lamp under it.
EditorScene lampScene() => EditorScene([
      SceneObject(
        id: 'lamp',
        name: 'Lamp post',
        kind: ObjectKind.group,
        position: Vector3(40, 0, 12),
      ),
      SceneObject(
        id: 'post',
        name: 'Post',
        kind: ObjectKind.mesh,
        parentId: 'lamp',
        scale: Vector3(0.2, 4, 0.2),
      ),
      SceneObject(
        id: 'bulb',
        name: 'Bulb',
        kind: ObjectKind.light,
        parentId: 'lamp',
        position: Vector3(0, 4, 0),
        colour: const Color(0xFFFFCC88),
      ),
    ]);

/// Ids that do not collide with the ones already in a scene.
String Function() counter() {
  var next = 0;
  return () => 'new${next++}';
}

/// A host for running commands against one scene.
class _Host implements SceneHost {
  _Host(this.scene);

  final EditorScene scene;

  @override
  EditorScene? sceneFor(String id) => scene;
}

void main() {
  group('saving one', () {
    test('takes the object and everything under it', () {
      final prefab = Prefab.fromScene(lampScene(), 'lamp');

      expect(prefab.name, 'Lamp post');
      expect(prefab.rootId, 'lamp');
      expect([for (final o in prefab.objects) o.name],
          containsAll(['Lamp post', 'Post', 'Bulb']));
    });

    test('drops the root\'s position, because a prefab is not a place', () {
      final prefab = Prefab.fromScene(lampScene(), 'lamp');
      final root = prefab.objects.firstWhere((o) => o.id == 'lamp');

      expect(root.position, Vector3.zero());
      // What is under it keeps its own, which is the shape of the thing.
      final bulb = prefab.objects.firstWhere((o) => o.name == 'Bulb');
      expect(bulb.position.y, 4);
    });

    test('does not carry a link to some other prefab', () {
      final scene = lampScene();
      scene['lamp']!.prefab = 'prefabs/old.oprefab';

      final prefab = Prefab.fromScene(scene, 'lamp');
      expect(prefab.objects.every((o) => o.prefab == null), isTrue);
    });

    test('says so rather than throwing on an object that is not there', () {
      expect(() => Prefab.fromScene(lampScene(), 'nope'),
          throwsA(isA<SceneError>()));
    });
  });

  group('the file', () {
    test('survives a round trip', () {
      final prefab = Prefab.fromScene(lampScene(), 'lamp');
      final back = Prefab.read(prefab.toText())!;

      expect(back.name, prefab.name);
      expect(back.rootId, prefab.rootId);
      expect(back.objects.length, prefab.objects.length);
      expect(back.objects.firstWhere((o) => o.name == 'Bulb').colour,
          const Color(0xFFFFCC88));
    });

    test('is not read from something that is not one', () {
      expect(Prefab.read('not json at all'), isNull);
      expect(Prefab.read('{"kind":"orbis.objects"}'), isNull);
      expect(Prefab.read('{"kind":"orbis.prefab","objects":[]}'), isNull);
    });

    test('a missing root falls back to the one with no parent', () {
      final text = Prefab.fromScene(lampScene(), 'lamp')
          .toText()
          .replaceAll('"root": "lamp"', '"root": "gone"');

      expect(Prefab.read(text)!.rootId, 'lamp');
    });
  });

  group('instancing', () {
    test('gives every instance ids of its own', () {
      final prefab = Prefab.fromScene(lampScene(), 'lamp');
      final next = counter();

      final one = prefab.instantiate(nextId: next, source: 'p.oprefab');
      final two = prefab.instantiate(nextId: next, source: 'p.oprefab');

      final ids = {for (final o in one.objects) o.id};
      expect(ids.intersection({for (final o in two.objects) o.id}), isEmpty);
      expect(ids.length, 3);
    });

    test('links every object in it, not only the root', () {
      final made = Prefab.fromScene(lampScene(), 'lamp')
          .instantiate(nextId: counter(), source: 'prefabs/lamp.oprefab');

      expect(made.objects.every((o) => o.prefab == 'prefabs/lamp.oprefab'),
          isTrue);
    });

    test('keeps the shape, with children pointing at the new root', () {
      final made = Prefab.fromScene(lampScene(), 'lamp')
          .instantiate(nextId: counter(), source: 'p.oprefab');

      final children =
          made.objects.where((o) => o.parentId == made.rootId).toList();
      expect(children.length, 2);
    });

    test('lands where it was dropped, under the parent it was given', () {
      final made = Prefab.fromScene(lampScene(), 'lamp').instantiate(
        nextId: counter(),
        source: 'p.oprefab',
        parentId: 'street',
        at: Vector3(1, 2, 3),
        name: 'Lamp post 2',
      );

      final root = made.objects.firstWhere((o) => o.id == made.rootId);
      expect(root.parentId, 'street');
      expect(root.position, Vector3(1, 2, 3));
      expect(root.name, 'Lamp post 2');
    });
  });

  group('reverting an instance', () {
    /// A scene holding one instance of a prefab, already edited.
    (EditorScene, Prefab, String) placed() {
      final prefab = Prefab.fromScene(lampScene(), 'lamp');
      final scene = EditorScene([
        SceneObject(id: 'street', name: 'Street', kind: ObjectKind.group),
      ]);
      final made = prefab.instantiate(
        nextId: counter(),
        source: 'p.oprefab',
        parentId: 'street',
        at: Vector3(5, 0, 5),
        name: 'Lamp A',
      );
      for (final object in made.objects) {
        scene.add(object);
      }
      return (scene, prefab, made.rootId);
    }

    test('takes the prefab back but keeps where it stands and its name', () {
      final (scene, prefab, id) = placed();
      scene[id]!.name = 'Lamp A';
      scene.childrenOf(id).first.scale.setValues(9, 9, 9);

      final made =
          prefab.resyncing(scene, id, nextId: counter(), source: 'p.oprefab');
      final root = made.objects.firstWhere((o) => o.id == id);

      expect(root.position, Vector3(5, 0, 5));
      expect(root.name, 'Lamp A');
      expect(root.parentId, 'street');
      final post = made.objects.firstWhere((o) => o.name == 'Post');
      expect(post.scale, Vector3(0.2, 4, 0.2));
    });

    test('reuses the ids that are already there, so nothing is deselected', () {
      final (scene, prefab, id) = placed();
      final was = {for (final o in scene.descendantsOf(id)) o.id};

      final made =
          prefab.resyncing(scene, id, nextId: counter(), source: 'p.oprefab');

      expect(made.rootId, id);
      expect({for (final o in made.objects) o.id}.containsAll(was), isTrue);
    });

    test('a child the prefab has gained comes with a new id', () {
      final (scene, _, id) = placed();

      // The prefab grows a third child after the instance was made.
      final bigger = lampScene()
        ..add(SceneObject(
          id: 'sign',
          name: 'Sign',
          kind: ObjectKind.mesh,
          parentId: 'lamp',
        ));
      final grown = Prefab.fromScene(bigger, 'lamp');

      final made =
          grown.resyncing(scene, id, nextId: counter(), source: 'p.oprefab');
      expect(made.objects.length, 4);
      expect(made.objects.any((o) => o.name == 'Sign'), isTrue);
    });
  });

  group('the commands', () {
    test('replacing a subtree is undoable to exactly what was there', () {
      final scene = lampScene();
      final host = _Host(scene);
      final history = History(host);

      final prefab = Prefab.fromScene(scene, 'lamp');
      scene['post']!.scale.setValues(9, 9, 9);

      final made =
          prefab.resyncing(scene, 'lamp', nextId: counter(), source: 'p');
      history.run(ReplaceSubtree(
        sceneId: 's',
        rootId: 'lamp',
        objects: made.objects,
        what: 'Lamp post',
      ));
      expect(scene.childrenOf('lamp').first.scale, Vector3(0.2, 4, 0.2));

      history.undo();
      expect(scene['post']!.scale, Vector3(9, 9, 9));
      expect(scene.objects.length, 3);
    });

    test('replacing keeps the object where it sat among its siblings', () {
      final scene = lampScene()
        ..add(SceneObject(id: 'kerb', name: 'Kerb', kind: ObjectKind.mesh));
      final host = _Host(scene);
      final prefab = Prefab.fromScene(scene, 'lamp');

      final made =
          prefab.resyncing(scene, 'lamp', nextId: counter(), source: 'p');
      ReplaceSubtree(
        sceneId: 's',
        rootId: 'lamp',
        objects: made.objects,
        what: 'Lamp post',
      ).apply(host);

      expect(scene.objects.first.id, 'lamp');
      expect(scene.objects.last.id, 'kerb');
    });

    test('linking and unpacking are both undoable', () {
      final scene = lampScene();
      final host = _Host(scene);
      final history = History(host);
      final ids = ['lamp', 'post', 'bulb'];

      history.run(
          LinkPrefab(sceneId: 's', ids: ids, source: 'p', what: 'Lamp post'));
      expect(scene.objects.every((o) => o.prefab == 'p'), isTrue);

      history.run(UnpackPrefab(sceneId: 's', ids: ids, what: 'Lamp post'));
      expect(scene.objects.every((o) => o.prefab == null), isTrue);

      history.undo();
      expect(scene.objects.every((o) => o.prefab == 'p'), isTrue);
      history.undo();
      expect(scene.objects.every((o) => o.prefab == null), isTrue);
    });
  });
}
