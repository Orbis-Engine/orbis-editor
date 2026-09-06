import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'scene.dart';
import 'ui_canvas.dart';
import 'workspace.dart';

/// The scene as the game shows it.
///
/// Through the scene's own camera rather than the one somebody is flying, and
/// with none of the editor over the top: no grid, no handles, no outlines, no
/// chips in the corners. That is the whole point — a viewport tells you where
/// things are and this tells you what a player would see, and a view that
/// answered both questions would answer neither.
///
/// The interface is drawn and takes the pointer, unlike the preview over the
/// scene view. Pressing a button here is meant to press it.
class GameView extends StatelessWidget {
  const GameView({
    super.key,
    required this.workspace,
    this.projectRoot,
    this.geometryOf,
    this.interface,
    this.through,
    this.plain = false,
  });

  final Workspace workspace;
  final String? projectRoot;

  /// Where an object's built geometry was written, if anywhere.
  final String? Function(SceneObject)? geometryOf;

  /// The interface the scene puts on screen, already read.
  final UiDocument? interface;

  /// A particular camera to look through, rather than the scene's first.
  ///
  /// What the preview in the corner of a viewport passes: the one that is
  /// selected, which is the one somebody is asking about.
  final SceneObject? through;

  /// Whether to leave off everything but the picture.
  ///
  /// The preview is 240 pixels wide and a sentence explaining that the scene
  /// has no camera does not fit in it — and would be saying so about a camera
  /// that is selected and therefore obviously there.
  final bool plain;

  static bool get _rendererAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// The first camera object in the scene, or null.
  ///
  /// The first rather than a chosen one: a scene with two cameras has not said
  /// which is the player's, and picking the one nearest the top of the tree is
  /// at least a rule somebody can see the effect of.
  SceneObject? _cameraObject(EditorScene scene) {
    if (through != null) return through;
    for (final object in scene.objects) {
      if (object.kind != ObjectKind.camera) continue;
      if (!object.visible || !scene.isShown(object.id)) continue;
      return object;
    }
    return null;
  }

  /// Where the game's camera is standing and what it is looking at.
  OrbisCamera? _camera(EditorScene scene) {
    final object = _cameraObject(scene);
    if (object == null) return null;

    final world = scene.worldOf(object.id);
    final position = world.getTranslation();
    // An unrotated camera looks down -Z, which is the convention the light
    // direction and glTF both use.
    //
    // transform rather than the multiplication operator: vector_math's
    // operator* on a matrix takes dynamic and decides what to do by looking at
    // the argument, and it reads an integer as a scale factor. The named
    // method says what is meant and cannot be read as something else.
    final forward =
        world.getRotation().transform(Vector3(0.0, 0.0, -1.0));

    return OrbisCamera(
      position: position,
      target: position + forward.normalized() * 10,
      fieldOfView: 50,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scene = workspace.loaded?.scene;
    final camera = scene == null ? null : _camera(scene);

    if (scene == null) {
      return plain
          ? const ColoredBox(color: OrbisColors.ground)
          : const _Nothing(saying: 'No scene loaded.');
    }
    if (camera == null) {
      return plain
          ? const ColoredBox(color: OrbisColors.ground)
          : const _Nothing(
              saying: 'This scene has no camera.\n'
                  'Add one, and this is what it sees.',
            );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: !_rendererAvailable
              ? const _Nothing(saying: 'The renderer runs on macOS so far.')
              : OrbisView(
                  scene: scene.toRenderScene(
                    camera,
                    projectRoot: projectRoot,
                    shared: workspace.shared,
                    geometryOf: geometryOf,
                  ),
                ),
        ),
        // Drawn and live. The preview over the scene view ignores the pointer
        // because it is in the way of the handles; here there are no handles
        // and pressing a button is meant to press it.
        if (interface != null)
          Positioned.fill(
            child: UiCanvasView(document: interface!, designing: false),
          ),
      ],
    );
  }
}

/// What the game view says when there is nothing to show.
class _Nothing extends StatelessWidget {
  const _Nothing({required this.saying});

  final String saying;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: OrbisColors.ground,
      child: Center(
        child: Text(
          saying,
          textAlign: TextAlign.center,
          style: OrbisText.caption,
        ),
      ),
    );
  }
}
