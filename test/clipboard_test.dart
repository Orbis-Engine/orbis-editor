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
      final clipboard = SceneClipboard()..take(scene, 'props');

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.length, 3, reason: 'Props and its two children');
      expect(pasted.map((o) => o.name), containsAll(['Props', 'Cube', 'Crate']));
    });

    test('what it holds is detached from the scene it came from', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, 'cube');

      // The scene is thrown away, as it is when one is unloaded.
      scene.remove('cube');

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.single.name, 'Cube');
    });

    test('the copy does not change when the original does', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, 'cube');

      scene['cube']!.position.setValues(9, 9, 9);

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.single.position, Vector3.zero());
    });

    test('names what is on it, so a menu can say what paste would do', () {
      final scene = EditorScene.starter();
      expect((SceneClipboard()..take(scene, 'cube')).description, 'Cube');
    });

    test('an empty clipboard is empty rather than a subtree of nothing', () {
      expect(SceneClipboard().isEmpty, isTrue);
      expect(SceneClipboard().description, '');
    });
  });

  group('pasting', () {
    test('gives everything a new id', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, 'props');

      final pasted = clipboard.contents(nextId: counter()).objects;
      expect(pasted.map((o) => o.id), everyElement(startsWith('new')));
      expect(pasted.map((o) => o.id).toSet().length, 3);
    });

    test('twice gives two things, not one thing pasted over itself', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, 'cube');
      final ids = counter();

      final first = clipboard.contents(nextId: ids).objects.single.id;
      final second = clipboard.contents(nextId: ids).objects.single.id;
      expect(first, isNot(second));
    });

    test('children point at the pasted parent, not the original', () {
      final scene = EditorScene.starter();
      final clipboard = SceneClipboard()..take(scene, 'props');

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
      final clipboard = SceneClipboard()..take(scene, 'cube');

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
      final clipboard = SceneClipboard()..take(r.scene, 'props');
      final content = clipboard.contents(nextId: counter());

      r.history.run(PasteObjects(
        sceneId: 'a',
        objects: content.objects,
        roots: content.roots,
        what: 'Props',
      ));

      expect(r.scene.childrenOf(content.roots.single).length, 2);
    });

    test('undo takes the whole paste, children included', () {
      final r = rig();
      final before = r.scene.length;

      final clipboard = SceneClipboard()..take(r.scene, 'props');
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
      final clipboard = SceneClipboard()..take(r.scene, 'cube');
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
      final clipboard = SceneClipboard()..take(r.scene, 'cube');
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
      final clipboard = SceneClipboard()..take(r.scene, 'crate');
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

    final clipboard = SceneClipboard()..take(from, 'props');
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
}
