import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/selection_outline.dart';
import 'package:orbis_editor/src/editor/viewport.dart';

/// The selection, as the renderer is told to outline it.
void main() {
  final crate = SceneObject(id: 'crate', name: 'Crate', kind: ObjectKind.mesh);
  final barrel = SceneObject(
    id: 'barrel',
    name: 'Barrel',
    kind: ObjectKind.mesh,
  );
  final sun = SceneObject(id: 'sun', name: 'Sun', kind: ObjectKind.light);
  final eye = SceneObject(id: 'eye', name: 'Eye', kind: ObjectKind.camera);
  final group = SceneObject(id: 'group', name: 'Group', kind: ObjectKind.group);
  final scene = EditorScene([crate, barrel, sun, eye, group]);

  test('nothing selected outlines nothing, and so costs the renderer '
      'nothing', () {
    final outline = selectionOutline(scene: scene, selected: {});
    expect(outline.isEmpty, isTrue);
  });

  test('outlines each selected mesh by the key the renderer draws it by', () {
    final outline = selectionOutline(
      scene: scene,
      selected: {'crate', 'barrel'},
      primary: 'barrel',
    );
    expect(outline.keys, {crate.renderKey, barrel.renderKey});
    expect(outline.primary, barrel.renderKey);
    // The active one first on the wire, which is how the renderer knows to
    // draw it brighter.
    expect(outline.packedKeys.first, barrel.renderKey);
  });

  test('leaves out what has no silhouette to follow', () {
    // A light, a camera and a group are drawn by nothing, so there is no
    // shape for an outline to go round. The handles show where they are.
    final outline = selectionOutline(
      scene: scene,
      selected: {'sun', 'eye', 'group'},
      primary: 'sun',
    );
    expect(outline.isEmpty, isTrue);
  });

  test('keeps the meshes of a mixed selection', () {
    final outline = selectionOutline(
      scene: scene,
      selected: {'sun', 'crate'},
      primary: 'sun',
    );
    expect(outline.keys, {crate.renderKey});
    // The active object is the light, which has nothing to outline; the crate
    // is still selected, and is drawn in the ordinary selection colour.
    expect(outline.primary, isNull);
  });

  test('finds objects in the shared set as well as the open scene', () {
    final lamp = SceneObject(id: 'lamp', name: 'Lamp', kind: ObjectKind.mesh);
    final outline = selectionOutline(
      scene: scene,
      shared: EditorScene([lamp]),
      selected: {'lamp'},
      primary: 'lamp',
    );
    expect(outline.primary, lamp.renderKey);
  });

  test('ignores an id that is no longer in either scene', () {
    final outline = selectionOutline(
      scene: scene,
      selected: {'gone'},
      primary: 'gone',
    );
    expect(outline.isEmpty, isTrue);
  });

  test('names keys the rendered scene actually contains', () {
    // The outline is only any use if its keys are the objects' keys in the
    // scene the viewport sends — otherwise it outlines nothing, silently.
    final rendered = scene.toRenderScene(OrbitCamera().toRenderCamera());
    final outline = selectionOutline(
      scene: scene,
      selected: {'crate', 'barrel'},
    );
    final sent = {for (final object in rendered.objects) object.key};
    expect(sent.containsAll(outline.keys), isTrue);
  });
}
