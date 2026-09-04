import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/clipboard.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/history.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/workspace.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// Ids that are unique but readable, so a failure says what it means.
String Function() counter() {
  var next = 0;
  return () => 'new${next++}';
}

void main() {
  group('copying', () {
    test('takes the whole subtree, not just the thing clicked', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['props']);

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.length, 3, reason: 'Props and its two children');
      expect(pasted.map((o) => o.name), containsAll(['Props', 'Cube', 'Crate']));
    });

    test('what it holds is detached from the scene it came from', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['cube']);

      // The scene is thrown away, as it is when one is unloaded.
      scene.remove('cube');

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.single.name, 'Cube');
    });

    test('the copy does not change when the original does', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['cube']);

      scene['cube']!.position.setValues(9, 9, 9);

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.single.position, Vector3.zero());
    });

    test('names what is on it, so a menu can say what paste would do', () {
      final scene = EditorScene.starter();
      expect((SceneClipboard()..take(scene, ['cube'])).description, 'Cube');
    });

    test('an empty clipboard is empty rather than a subtree of nothing', () {
      expect(SceneClipboard().isEmpty, isTrue);
      expect(SceneClipboard().description, '');
    });
  });

  group('pasting', () {
    test('gives everything a new id', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['props']);

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.map((o) => o.id), everyElement(startsWith('new')));
      expect(pasted.map((o) => o.id).toSet().length, 3);
    });

    test('twice gives two things, not one thing pasted over itself', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['cube']);
      final ids = counter();

      final first = clipboard.contents(nextId: ids).objects.single.id;
      final second = clipboard.contents(nextId: ids).objects.single.id;
      expect(first, isNot(second));
    });

    test('children point at the pasted parent, not the original', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['props']);

      final content = clipboard.contents(nextId: counter());
      final root = content.roots.single;
      final children = content.objects.where((o) => o.id != root);

      for (final child in children) {
        expect(child.parentId, root,
            reason: 'a pasted child must not point back at the copy source');
      }
    });

    test('the top of what was copied takes the parent it is pasted into', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['cube']);

      final content =
          clipboard.contents(nextId: counter(), parentId: 'somewhere');
      expect(content.objects.single.parentId, 'somewhere');
    });
  });

  group('paste into a scene', () {
    ({Workspace workspace, History history, EditorScene scene}) rig() {
      final scene = EditorScene.starter();
      final workspace = Workspace('/project')
        ..add(SceneEntry(id: 'a', name: 'A', scene: scene));
      return (
        workspace: workspace,
        history: History(workspace),
        scene: scene,
      );
    }

    test('adds the subtree with its shape intact', () {
      final r = rig();
      final clipboard = SceneClipboard()..take(r.scene, ['props']);
      final content = clipboard.contents(nextId: counter());

      r.history.run(PasteObjects(
        sceneId: 'a',
        objects: content.objects,
        roots: content.roots,
        worlds: content.worlds,
        what: 'Props',
      ));

      expect(r.scene.childrenOf(content.roots.single).length, 2);
    });

    test('undo takes the whole paste, children included', () {
      final r = rig();
      final before = r.scene.length;

      final clipboard = SceneClipboard()..take(r.scene, ['props']);
      final content = clipboard.contents(nextId: counter());

      r.history
        ..run(PasteObjects(
          sceneId: 'a',
          objects: content.objects,
          roots: content.roots,
          what: 'Props',
        ))
        ..undo();

      expect(r.scene.length, before);
    });

    test('redo puts it back with the same ids', () {
      final r = rig();
      final clipboard = SceneClipboard()..take(r.scene, ['cube']);
      final content = clipboard.contents(nextId: counter());

      r.history
        ..run(PasteObjects(
          sceneId: 'a',
          objects: content.objects,
          roots: content.roots,
          what: 'Cube',
        ))
        ..undo()
        ..redo();

      // Same ids, so a selection or a later step still refers to the right
      // object after an undo and redo.
      expect(r.scene.contains(content.roots.single), isTrue);
    });

    test('a paste into a scene that is gone does nothing rather than throw',
        () {
      final r = rig();
      final clipboard = SceneClipboard()..take(r.scene, ['cube']);
      final content = clipboard.contents(nextId: counter());

      r.workspace.unload(r.workspace['a']!);
      r.history.run(PasteObjects(
        sceneId: 'a',
        objects: content.objects,
        roots: content.roots,
        what: 'Cube',
      ));
    });

    test('the step is named for what was pasted', () {
      final r = rig();
      final clipboard = SceneClipboard()..take(r.scene, ['crate']);
      final content = clipboard.contents(nextId: counter());

      r.history.run(PasteObjects(
        sceneId: 'a',
        objects: content.objects,
        roots: content.roots,
        what: clipboard.description,
      ));

      expect(r.history.undoLabel, 'Paste Crate');
    });
  });

  test('a copy from one scene lands in another', () {
    // The reason the clipboard holds detached copies at all.
    final from = EditorScene.starter();
    final to = EditorScene([]);

    final workspace = Workspace('/project')
      ..add(SceneEntry(id: 'b', name: 'B', scene: to));
    final history = History(workspace);

    final clipboard = SceneClipboard()..take(from, ['props']);
    final content = clipboard.contents(nextId: counter());

    history.run(PasteObjects(
      sceneId: 'b',
      objects: content.objects,
      roots: content.roots,
      what: 'Props',
    ));

    expect(to.length, 3);
    expect(to.roots.single.name, 'Props');
    expect(to.childrenOf(content.roots.single).map((o) => o.name),
        containsAll(['Cube', 'Crate']));
  });

  group('several at once', () {
    test('copies each subtree', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['sun', 'ground']);

      final content = clipboard.contents(nextId: counter());
      expect(content.roots.length, 2);
      expect(content.objects.length, 2);
    });

    test('leaves out anything already inside something else copied', () {
      // Copying a parent and its child together would paste the child twice:
      // once as itself and once inside its parent.
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['props', 'cube']);

      final content = clipboard.contents(nextId: counter());
      expect(content.roots.length, 1, reason: 'Cube is inside Props');
      expect(content.objects.length, 3);
    });

    test('names how many rather than listing them', () {
      final scene = EditorScene.starter();
      expect(
        (SceneClipboard()..take(scene, ['sun', 'ground'])).description,
        '2 objects',
      );
    });

    test('an id that is not in the scene is ignored', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, ['cube', 'ghost']);
      expect(clipboard.contents(nextId: counter()).roots.length, 1);
    });
  });

  group('through text', () {
    test('what is written can be read back', () {
      final scene = EditorScene.starter();
      final from = SceneClipboard()..take(scene, ['props']);

      final to = SceneClipboard();
      expect(to.takeText(from.toText()), isTrue);
      expect(to.description, 'Props');
      expect(to.contents(nextId: counter()).objects.length, 3);
    });

    test('the shape survives, not just the names', () {
      final scene = EditorScene.starter();
      scene['crate']!.position.setValues(1.5, -2, 0.25);
      scene.invalidate();

      final to = SceneClipboard()
        ..takeText((SceneClipboard()..take(scene, ['props'])).toText());

      final objects = to.contents(nextId: counter()).objects;
      final crate = objects.firstWhere((o) => o.name == 'Crate');
      expect(crate.position.x, closeTo(1.5, 1e-9));
      expect(crate.position.y, closeTo(-2, 1e-9));
    });

    test('anything else on the clipboard is left alone, not an error', () {
      final loaded = SceneClipboard()
        ..take(EditorScene.starter(), ['cube']);

      // A path, a paragraph, JSON meaning something else.
      for (final text in [
        null,
        '',
        '/Users/somebody/notes.txt',
        '{"kind": "something else"}',
        '{"kind": "orbis.objects"',
      ]) {
        expect(loaded.takeText(text), isFalse, reason: 'for "$text"');
      }
      // And what was already on it is untouched.
      expect(loaded.description, 'Cube');
    });

    test('is readable rather than an opaque blob', () {
      final text =
          (SceneClipboard()..take(EditorScene.starter(), ['cube'])).toText();
      expect(text, contains('"Cube"'));
      expect(text, contains('orbis.objects'));
    });
  });

  group('where a paste lands', () {
    test('a root remembers where it was in the world', () {
      final scene = EditorScene.starter();
      scene['props']!.position.setValues(10, 0, 0);
      scene.invalidate();

      final clipboard = SceneClipboard()..take(scene, ['crate']);
      final content = clipboard.contents(nextId: counter());

      // The crate sits inside Props, which is ten metres out.
      final world = content.worlds[content.roots.single]!;
      expect(world.getTranslation().x, closeTo(12.2, 1e-6));
    });

    test('pasting into a different parent chain keeps it where it was', () {
      final from = EditorScene.starter();
      from['props']!.position.setValues(10, 0, 0);
      from.invalidate();
      final wasAt = from.worldOf('crate').getTranslation();

      final to = EditorScene([]);
      final workspace = Workspace('/project')
        ..add(SceneEntry(id: 'b', name: 'B', scene: to));
      final history = History(workspace);

      final clipboard = SceneClipboard()..take(from, ['crate']);
      final content = clipboard.contents(nextId: counter());

      history.run(PasteObjects(
        sceneId: 'b',
        objects: content.objects,
        roots: content.roots,
        worlds: content.worlds,
        what: 'Crate',
      ));

      // The other scene has no Props to inherit from, so the local transform
      // has to absorb what the parent used to contribute.
      final landed = to.worldOf(content.roots.single).getTranslation();
      expect((landed - wasAt).length, lessThan(1e-6));
    });

    test('duplicating in place does not move it', () {
      final scene = EditorScene.starter();
      scene['props']!.position.setValues(3, 1, -2);
      scene.invalidate();
      final wasAt = scene.worldOf('crate').getTranslation();

      final workspace = Workspace('/project')
        ..add(SceneEntry(id: 'a', name: 'A', scene: scene));
      final history = History(workspace);

      final clipboard = SceneClipboard()..take(scene, ['crate']);
      final content =
          clipboard.contents(nextId: counter(), parentId: 'props');

      history.run(PasteObjects(
        sceneId: 'a',
        objects: content.objects,
        roots: content.roots,
        worlds: content.worlds,
        what: 'Crate',
      ));

      final copy = scene.worldOf(content.roots.single).getTranslation();
      expect((copy - wasAt).length, lessThan(1e-6));
    });
  });
}
