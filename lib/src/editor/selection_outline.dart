import 'package:orbis_filament/orbis_filament.dart';

import 'scene.dart';

/// The line the renderer draws round what is selected, worked out from the
/// editor's selection.
///
/// Drawn by the renderer rather than painted over the picture because only the
/// renderer knows what is in front of what. A box projected over the texture
/// cannot tell a selected crate behind a wall from one in front of it; the
/// renderer's outline follows the silhouette, and draws the part the wall
/// hides fainter and dashed, so the crate is findable without looking as if it
/// were in the room.
///
/// Only objects the renderer draws can have one: meshes and shapes. A light, a
/// camera or a group has no silhouette, and the handles already say where it
/// is. The [primary] is the object the inspector is showing and the handles
/// sit on, and gets the brighter colour — the same convention most 3D tools
/// use, so it means something before anybody has read about it.
///
/// Objects in the project's shared set are drawn alongside every scene, so
/// they are looked up there as well as in the scene that is open.
OrbisOutline selectionOutline({
  required EditorScene? scene,
  EditorScene? shared,
  required Set<String> selected,
  String? primary,
}) {
  SceneObject? find(String id) => scene?[id] ?? shared?[id];

  int? keyOf(String? id) {
    if (id == null) return null;
    final object = find(id);
    if (object == null || !object.isDrawable) return null;
    return object.renderKey;
  }

  final keys = <int>{
    for (final id in selected) ?keyOf(id),
  };
  final active = keyOf(primary);
  if (keys.isEmpty && active == null) return OrbisOutline.none;
  return OrbisOutline(keys: keys, primary: active);
}
