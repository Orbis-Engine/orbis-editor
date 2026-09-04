import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'commands.dart';
import 'gizmo.dart';
import 'history.dart';
import 'scene.dart';
import 'workspace.dart';

/// Where the viewer is standing, in orbit terms.
///
/// Orbit rather than free flight, because an editor viewport is nearly always
/// used to look *at* something, and yaw/pitch/distance cannot be driven into a
/// state you have to reset your way out of.
class OrbitCamera {
  OrbitCamera({
    this.yaw = 0.6,
    this.pitch = 0.35,
    this.distance = 12,
    this.fieldOfView = 50,
    Vector3? target,
  }) : target = target ?? Vector3(0, 0.5, 0);

  final double yaw;
  final double pitch;
  final double distance;
  final double fieldOfView;

  /// What the camera turns around and looks at.
  final Vector3 target;

  /// Pitch is clamped just short of straight up and straight down: at exactly
  /// vertical the up vector and the view direction are parallel and the view
  /// matrix collapses, which shows up as the image flipping.
  static const _pitchLimit = math.pi / 2 - 0.02;

  OrbitCamera orbit(Offset delta) => OrbitCamera(
        yaw: yaw - delta.dx * 0.008,
        pitch: (pitch + delta.dy * 0.008).clamp(-_pitchLimit, _pitchLimit),
        distance: distance,
        fieldOfView: fieldOfView,
        target: target,
      );

  OrbitCamera zoom(double amount) => OrbitCamera(
        yaw: yaw,
        pitch: pitch,
        distance: (distance * math.exp(amount * 0.0016)).clamp(1.5, 200.0),
        fieldOfView: fieldOfView,
        target: target,
      );

  /// Slides the camera sideways, keeping its angle. What a middle-drag does.
  OrbitCamera pan(Offset delta) {
    // Scaled by distance so panning feels the same close up and far away, and
    // moved along the camera's own axes rather than the world's.
    final scale = distance * 0.0016;
    final right = Vector3(math.cos(yaw), 0, -math.sin(yaw));
    final up = Vector3(
      -math.sin(yaw) * math.sin(pitch),
      math.cos(pitch),
      -math.cos(yaw) * math.sin(pitch),
    );

    return OrbitCamera(
      yaw: yaw,
      pitch: pitch,
      distance: distance,
      fieldOfView: fieldOfView,
      target: target - right * (delta.dx * scale) + up * (delta.dy * scale),
    );
  }

  /// Points the camera at a box, far enough back to see all of it.
  ///
  /// Keeps the angle it was already at, because framing something should not
  /// also spin the view — somebody pressing F wants the thing on screen, not a
  /// different shot of it.
  OrbitCamera framing({required Vector3 centre, required double radius}) {
    // Fitted to the vertical field of view with room to spare, and floored so
    // framing a flat or tiny object does not put the camera inside it.
    final fitted = radius / math.tan(radians(fieldOfView) / 2) * 1.6;

    return OrbitCamera(
      yaw: yaw,
      pitch: pitch,
      distance: fitted.clamp(1.5, 200.0),
      fieldOfView: fieldOfView,
      target: centre.clone(),
    );
  }

  OrbisCamera toRenderCamera() {
    final horizontal = distance * math.cos(pitch);
    return OrbisCamera(
      position: Vector3(
        target.x + horizontal * math.sin(yaw),
        target.y + distance * math.sin(pitch),
        target.z + horizontal * math.cos(yaw),
      ),
      target: target.clone(),
      fieldOfView: fieldOfView,
    );
  }
}

/// The 3D view.
///
/// On macOS this is Filament compositing into a Flutter texture. Everywhere
/// else it is an honest placeholder — a viewport that pretends to work on a
/// platform where the renderer does not exist is worse than one that says so.
// Named SceneViewport rather than Viewport: Flutter already exports a
// Viewport, and a name that collides with the framework's is one somebody has
// to disambiguate at every call site.
class SceneViewport extends StatefulWidget {
  const SceneViewport({
    super.key,
    required this.workspace,
    required this.camera,
    required this.onCameraChanged,
    this.selected = const {},
    this.onDropAsset,
    this.projectRoot,
    this.onSceneNotes,
    this.onClock,
    this.primary,
    this.history,
    this.onPick,
  });

  /// Only the loaded scene is drawn. The others are names and paths until
  /// somebody opens them.
  final Workspace workspace;

  /// Owned by the shell rather than here, so pressing F anywhere can frame the
  /// selection and so the view could later be saved with the scene.
  final OrbitCamera camera;

  final ValueChanged<OrbitCamera> onCameraChanged;

  /// The objects to outline. All of them, so a multiple selection is visible
  /// in the viewport rather than only in the tree.
  final Set<String> selected;

  /// Called when a file is dragged in from the project browser.
  final ValueChanged<String>? onDropAsset;

  /// Where mesh references are resolved from.
  final String? projectRoot;

  /// Called with anything the scene asked for that the renderer could not
  /// give: a mesh that would not load, a light it has no room to shade.
  final ValueChanged<Map<String, String>>? onSceneNotes;

  /// The one of the selection the handles sit on, and whose transform a drag
  /// writes first. The others follow it.
  final String? primary;

  /// Where a drag's changes go. Without it the viewport can still show and
  /// select, but nothing in it can be moved.
  final History? history;

  /// Called when something in the scene is clicked, or nothing is.
  ///
  /// `add` is set when a modifier was held, which the shell reads as adding to
  /// or taking away from what is already selected rather than replacing it.
  final void Function(String? id, {required bool add})? onPick;

  /// Called a few times a second while a scene is animating, so the panels
  /// that are not the viewport can keep up.
  ///
  /// A few, not sixty: the tree and the inspector show the hour and the name
  /// of whatever is in the sky, and those change slowly enough to read. The
  /// viewport draws every frame; the rest of the editor does not have to.
  final VoidCallback? onClock;

  @override
  State<SceneViewport> createState() => _SceneViewportState();
}

class _SceneViewportState extends State<SceneViewport>
    with SingleTickerProviderStateMixin {
  Offset? _dragAnchor;

  /// What a drag on a handle does. Kept here rather than in the shell because
  /// it is a property of how somebody is working in this view, not of the
  /// document — it is not saved and it is not undone.
  GizmoMode _mode = GizmoMode.move;

  /// The size of the surface, as laid out. Needed to turn a pointer position
  /// into a ray, and only known once the viewport has been given a box.
  Size? _surface;

  GizmoAxis? _hovered;
  GizmoAxis? _dragging;

  /// Where on the handle the drag began, in world space, and what every
  /// object being dragged looked like before it started.
  Vector3? _grabbed;
  final Map<String, Vector3> _before = {};
  final Map<String, Matrix3> _beforeWorld = {};

  /// The gizmo as it stands, or null when there is nothing to put it on.
  Gizmo? get _gizmo {
    final scene = widget.workspace.loaded?.scene;
    final id = widget.primary;
    final size = _surface;
    if (scene == null || id == null || size == null || size.isEmpty) {
      return null;
    }
    final object = scene[id];
    if (object == null || object.kind == ObjectKind.scene) return null;

    return Gizmo(
      mode: _mode,
      pivot: scene.worldOf(id).getTranslation(),
      projection: ViewportProjection(camera: widget.camera, size: size),
    );
  }

  /// Everything a drag moves: the whole selection, or just the one the handles
  /// are on when the selection is empty for some reason.
  List<String> get _targets {
    final scene = widget.workspace.loaded?.scene;
    if (scene == null) return const [];
    final ids = widget.selected.isEmpty
        ? [if (widget.primary != null) widget.primary!]
        : widget.selected.toList();
    return [
      for (final id in ids)
        if (scene[id] != null && scene[id]!.kind != ObjectKind.scene) id,
    ];
  }

  void _hover(Offset local) {
    final axis = _gizmo?.axisAt(local);
    if (axis == _hovered) return;
    setState(() => _hovered = axis);
  }

  /// Picks whatever is under the pointer, or nothing.
  void _pick(Offset local) {
    final scene = widget.workspace.loaded?.scene;
    final size = _surface;
    if (scene == null || size == null || size.isEmpty) return;

    final ray = ViewportProjection(camera: widget.camera, size: size)
        .rayThrough(local);
    final hit = scene.objectAlong(ray.origin, ray.direction);

    final modifiers = {
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    };
    final held = HardwareKeyboard.instance.logicalKeysPressed
        .any(modifiers.contains);

    widget.onPick?.call(hit, add: held);
  }

  /// Takes hold of a handle, remembering where everything was.
  bool _grab(Offset local) {
    final gizmo = _gizmo;
    final scene = widget.workspace.loaded?.scene;
    final axis = gizmo?.axisAt(local);
    if (gizmo == null || scene == null || axis == null) return false;
    if (widget.history == null) return false;

    final grabbed = _mode == GizmoMode.move
        ? gizmo.pointOnAxis(local, axis)
        : gizmo.pointOnRing(local, axis);
    // The pointer is on the handle but the plane behind it is edge-on to the
    // camera, so there is no sensible place to have grabbed. Better to orbit
    // than to teleport whatever is selected.
    if (grabbed == null) return false;

    _before.clear();
    _beforeWorld.clear();
    for (final id in _targets) {
      final object = scene[id]!;
      _before[id] = _mode == GizmoMode.move
          ? object.position.clone()
          : object.rotation.clone();
      _beforeWorld[id] = scene.worldOf(id).getRotation();
    }

    setState(() {
      _dragging = axis;
      _grabbed = grabbed;
    });
    return true;
  }

  /// Applies the drag as it stands: one command, however many objects.
  void _dragTo(Offset local) {
    final gizmo = _gizmo;
    final scene = widget.workspace.loaded?.scene;
    final axis = _dragging;
    final grabbed = _grabbed;
    final history = widget.history;
    final sceneId = widget.workspace.loaded?.id;
    if (gizmo == null ||
        scene == null ||
        axis == null ||
        grabbed == null ||
        history == null ||
        sceneId == null) {
      return;
    }

    final changes = <String, ({Vector3 from, Vector3 to})>{};

    if (_mode == GizmoMode.move) {
      final now = gizmo.pointOnAxis(local, axis);
      if (now == null) return;
      final shift = now - grabbed;

      for (final entry in _before.entries) {
        final object = scene[entry.key];
        if (object == null) continue;
        // A world-space shift means something different inside a parent that
        // is itself turned or scaled, so it is taken into that parent's frame
        // before it is added to a local position.
        final parentId = object.parentId;
        final local = parentId == null || !scene.contains(parentId)
            ? shift
            : Matrix4.inverted(scene.worldOf(parentId)).rotated3(shift.clone());
        changes[entry.key] = (from: entry.value, to: entry.value + local);
      }
    } else {
      final now = gizmo.pointOnRing(local, axis);
      if (now == null) return;
      final angle = gizmo.angleBetween(grabbed, now, axis);
      final turn =
          Quaternion.axisAngle(axis.direction, angle).asRotationMatrix();

      for (final entry in _before.entries) {
        final object = scene[entry.key];
        final was = _beforeWorld[entry.key];
        if (object == null || was == null) continue;

        // Turned about the world axis, then read back into the parent's frame.
        // Each object turns where it stands rather than orbiting the handle,
        // so a selection of several keeps its shape.
        final turned = turn * was;
        final parentId = object.parentId;
        final localRotation = parentId == null || !scene.contains(parentId)
            ? turned
            : (Matrix3.copy(scene.worldOf(parentId).getRotation())..invert()) *
                turned;

        changes[entry.key] = (
          from: entry.value,
          to: eulerDegreesOf(Matrix4.identity()..setRotation(localRotation)),
        );
      }
    }

    if (changes.isEmpty) return;
    history.run(TransformMany(
      sceneId: sceneId,
      field: _mode == GizmoMode.move
          ? TransformField.position
          : TransformField.rotation,
      what: changes.length == 1
          ? scene[changes.keys.first]!.name
          : '${changes.length} objects',
      changes: changes,
    ));
  }

  void _release() {
    if (_dragging == null) return;
    // Sealed here rather than on a timer, so the whole gesture is one step
    // however long somebody took over it.
    widget.history?.seal();
    setState(() {
      _dragging = null;
      _grabbed = null;
    });
  }

  /// Drives anything in the scene that moves on its own — a day running, mist
  /// drifting.
  ///
  /// It lives here rather than in the shell so that a running clock repaints
  /// the viewport and nothing else. A ticker at the top would rebuild the
  /// outliner, the inspector and the browser sixty times a second to animate
  /// a sky none of them draw.
  late final Ticker _clock = createTicker(_tick);

  /// Where the clock had got to when it was last stopped, so pausing and
  /// starting again does not jump the sky back to the beginning.
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(SceneViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A scene loaded, unloaded, or had its cycle switched on or off.
    _syncClock();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  /// Runs the clock only while something is actually moving.
  ///
  /// A ticker that never stops is a viewport that republishes sixty times a
  /// second to draw a scene that has not changed, and on a laptop that is a
  /// fan spinning up to animate nothing.
  void _syncClock() {
    final scene = widget.workspace.loaded?.scene;
    final wanted = scene != null && scene.isAnimated;
    if (wanted == _clock.isActive) return;
    if (wanted) {
      _clock.start();
    } else {
      _clock.stop();
    }
  }

  void _tick(Duration elapsed) {
    final scene = widget.workspace.loaded?.scene;
    if (scene == null) return;
    _elapsed = elapsed;
    setState(() => scene.clock = _elapsed.inMicroseconds / 1e6);

    if (elapsed - _lastTold >= _tellInterval) {
      _lastTold = elapsed;
      widget.onClock?.call();
    }
  }

  Duration _lastTold = Duration.zero;
  static const Duration _tellInterval = Duration(milliseconds: 250);

  bool get _rendererAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// What is on screen.
  String get _summary {
    final scene = widget.workspace.loaded?.scene;
    if (scene == null) return 'No scene';
    return '${scene.objects.where((o) => o.isDrawable).length} drawn';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(Space.sm),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF14181F),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (_) => widget.onDropAsset != null,
        onAcceptWithDetails: (details) => widget.onDropAsset?.call(details.data),
        builder: (context, candidate, _) => LayoutBuilder(
          builder: (context, constraints) {
            // The size the handles are projected into. Recorded rather than
            // asked for at gesture time, because a pointer arrives before the
            // next layout does.
            _surface = constraints.biggest;

            return Stack(
          children: [
            Positioned.fill(
              child:
                  _rendererAvailable ? _buildSurface() : const _Placeholder(),
            ),
            if (candidate.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: OrbisColors.emberWash,
                      border: Border.all(color: OrbisColors.ember, width: 2),
                      borderRadius: BorderRadius.circular(Radii.panel),
                    ),
                  ),
                ),
              ),
            // Drawn in Flutter over the texture rather than as a render pass:
            // an outline pass in Filament is a real piece of work, and a box
            // projected with the same camera is honest about where the object
            // is without pretending to be more than it is.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SelectionPainter(
                    workspace: widget.workspace,
                    selected: widget.selected,
                    camera: widget.camera,
                  ),
                ),
              ),
            ),
            // Over the outline, because a handle you cannot see is a handle
            // you cannot grab — and under nothing, because it has to be the
            // thing the pointer finds first.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: GizmoPainter(
                    gizmo: _gizmo,
                    hovered: _hovered,
                    dragging: _dragging,
                  ),
                ),
              ),
            ),
            Positioned(
              left: Space.md,
              top: Space.md,
              child: Row(children: [
                const _ViewportChip('Perspective'),
                const SizedBox(width: Space.xs),
                const _ViewportChip('Shaded'),
                const SizedBox(width: Space.xs),
                _ViewportChip(_summary),
              ]),
            ),
            if (_rendererAvailable)
              Positioned(
                left: Space.md,
                bottom: Space.md,
                child: Row(
                  children: [
                    for (final mode in GizmoMode.values) ...[
                      _ToolButton(
                        mode: mode,
                        selected: _mode == mode,
                        onPressed: () => setState(() => _mode = mode),
                      ),
                      const SizedBox(width: Space.xs),
                    ],
                  ],
                ),
              ),
            if (_rendererAvailable)
              const Positioned(
                right: Space.md,
                bottom: Space.md,
                child: _ViewportChip(
                  'Click to select · drag a handle to move · '
                  'drag elsewhere to orbit',
                ),
              ),
          ],
        );
          },
        ),
      ),
    );
  }

  Widget _buildSurface() {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        widget.onCameraChanged(widget.camera.zoom(event.scrollDelta.dy));
      },
      child: MouseRegion(
        onHover: (event) => _hover(event.localPosition),
        onExit: (_) => setState(() => _hovered = null),
        child: GestureDetector(
        // Opaque so drags land here rather than falling through to whatever
        // scrolls behind the viewport.
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _pick(details.localPosition),
        onPanStart: (details) {
          // A handle first: a drag that starts on one is a transform, and
          // anywhere else is the view turning. Nothing to hold down and no
          // mode to be in — the handles are the mode.
          if (_grab(details.localPosition)) return;
          _dragAnchor = details.localPosition;
        },
        onPanUpdate: (details) {
          if (_dragging != null) {
            _dragTo(details.localPosition);
            return;
          }
          final anchor = _dragAnchor;
          if (anchor == null) return;
          widget.onCameraChanged(
            widget.camera.orbit(details.localPosition - anchor),
          );
          _dragAnchor = details.localPosition;
        },
        onPanEnd: (_) {
          _release();
          _dragAnchor = null;
        },
        onPanCancel: () {
          _release();
          _dragAnchor = null;
        },
        child: OrbisView(
          // One scene at a time, so the viewport shows one document and there
          // is never a question about which one an object belongs to.
          scene: (widget.workspace.loaded?.scene ?? EditorScene([]))
              .toRenderScene(
            widget.camera.toRenderCamera(),
            projectRoot: widget.projectRoot,
          ),
          onSceneNotes: widget.onSceneNotes,
        ),
        ),
      ),
    );
  }
}

/// One of the two things a drag on a handle can do.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.mode,
    required this.selected,
    required this.onPressed,
  });

  final GizmoMode mode;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: mode.label,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: selected ? OrbisColors.ember : OrbisColors.raised,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(
              color: selected ? OrbisColors.ember : OrbisColors.lineSoft,
            ),
          ),
          child: Icon(
            mode.icon,
            size: 15,
            color: selected ? Colors.white : OrbisColors.inkDim,
          ),
        ),
      ),
    );
  }
}

/// The grid shown where Filament cannot run.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.view_in_ar_outlined,
                  size: 34, color: OrbisColors.inkDim),
              const SizedBox(height: Space.md),
              Text('Viewport', style: OrbisText.label),
              const SizedBox(height: Space.xs),
              Text('The renderer runs on macOS so far.',
                  style: OrbisText.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _ViewportChip extends StatelessWidget {
  const _ViewportChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
      decoration: BoxDecoration(
        color: OrbisColors.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Text(label, style: OrbisText.caption.copyWith(fontSize: 11)),
    );
  }
}

/// A faint ground grid, so an empty viewport reads as a space rather than a
/// panel that failed to load.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = OrbisColors.line.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    const spacing = 32.0;

    for (var x = spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}

/// Draws a box round the selected object.
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.workspace,
    required this.selected,
    required this.camera,
  });

  final Workspace workspace;
  final Set<String> selected;
  final OrbitCamera camera;

  /// The unit cube the renderer draws for every object, in its own space.
  static final _corners = [
    for (final x in [-1.0, 1.0])
      for (final y in [-1.0, 1.0])
        for (final z in [-1.0, 1.0]) Vector3(x, y, z),
  ];

  /// Pairs of corner indices making the twelve edges.
  static const _edges = [
    [0, 1], [1, 3], [3, 2], [2, 0],
    [4, 5], [5, 7], [7, 6], [6, 4],
    [0, 4], [1, 5], [2, 6], [3, 7],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (selected.isEmpty || size.isEmpty) return;

    final scene = workspace.loaded?.scene;
    if (scene == null) return;

    final view = camera.toRenderCamera();
    final viewMatrix = makeViewMatrix(
      view.position,
      view.target,
      Vector3(0, 1, 0),
    );
    final projection = makePerspectiveMatrix(
      radians(view.fieldOfView),
      size.width / size.height,
      0.1,
      1000,
    );
    final viewProjection = projection.multiplied(viewMatrix);
    final path = Path();

    for (final id in selected) {
      final object = scene[id];
      if (object == null || !object.isDrawable) continue;

      final clip = viewProjection.multiplied(scene.worldOf(id));
      final points = <Offset>[];
      var visible = true;

      for (final corner in _corners) {
        final projected =
            clip.transform(Vector4(corner.x, corner.y, corner.z, 1));
        // Behind the camera: the perspective divide flips the point to the
        // opposite side of the screen, which would draw a box across the whole
        // viewport. That one is skipped rather than drawn wrong.
        if (projected.w <= 1e-6) {
          visible = false;
          break;
        }
        points.add(Offset(
          (projected.x / projected.w * 0.5 + 0.5) * size.width,
          (1 - (projected.y / projected.w * 0.5 + 0.5)) * size.height,
        ));
      }
      if (!visible) continue;

      for (final edge in _edges) {
        path
          ..moveTo(points[edge[0]].dx, points[edge[0]].dy)
          ..lineTo(points[edge[1]].dx, points[edge[1]].dy);
      }
    }

    if (path.getBounds().isEmpty) return;

    canvas
      // A dark pass under the bright one, so the outline reads against a pale
      // surface as well as a dark one.
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0x66000000),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = OrbisColors.ember,
      );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter old) => true;
}
