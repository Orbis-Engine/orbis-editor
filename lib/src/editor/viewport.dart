import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'scene.dart';

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
    required this.scene,
    required this.camera,
    required this.onCameraChanged,
    this.selected,
    this.onDropAsset,
  });

  final EditorScene scene;

  /// Owned by the shell rather than here, so pressing F anywhere can frame the
  /// selection and so the view could later be saved with the scene.
  final OrbitCamera camera;

  final ValueChanged<OrbitCamera> onCameraChanged;

  /// The object to outline, if any.
  final String? selected;

  /// Called when a file is dragged in from the project browser.
  final ValueChanged<String>? onDropAsset;

  @override
  State<SceneViewport> createState() => _SceneViewportState();
}

class _SceneViewportState extends State<SceneViewport> {
  Offset? _dragAnchor;

  bool get _rendererAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

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
        builder: (context, candidate, _) => Stack(
        children: [
          Positioned.fill(
            child: _rendererAvailable ? _buildSurface() : const _Placeholder(),
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
                  scene: widget.scene,
                  selected: widget.selected,
                  camera: widget.camera,
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
              _ViewportChip('${widget.scene.objects.length} objects'),
            ]),
          ),
          if (_rendererAvailable)
            const Positioned(
              right: Space.md,
              bottom: Space.md,
              child: _ViewportChip(
                'Drag to orbit · scroll to zoom · F to frame',
              ),
            ),
        ],
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
      child: GestureDetector(
        // Opaque so drags land here rather than falling through to whatever
        // scrolls behind the viewport.
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _dragAnchor = details.localPosition,
        onPanUpdate: (details) {
          final anchor = _dragAnchor;
          if (anchor == null) return;
          widget.onCameraChanged(
            widget.camera.orbit(details.localPosition - anchor),
          );
          _dragAnchor = details.localPosition;
        },
        onPanEnd: (_) => _dragAnchor = null,
        child: OrbisView(
          scene: widget.scene.toRenderScene(widget.camera.toRenderCamera()),
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
    required this.scene,
    required this.selected,
    required this.camera,
  });

  final EditorScene scene;
  final String? selected;
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
    final id = selected;
    if (id == null || size.isEmpty) return;

    final object = scene[id];
    if (object == null || !object.isDrawable) return;

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
    final clip = projection.multiplied(viewMatrix)
      ..multiply(scene.worldOf(id));

    final points = <Offset>[];
    for (final corner in _corners) {
      final projected = clip.transform(Vector4(
        corner.x,
        corner.y,
        corner.z,
        1,
      ));
      // Behind the camera: the perspective divide flips the point to the
      // opposite side of the screen, which would draw a box across the whole
      // viewport. Nothing is drawn instead.
      if (projected.w <= 1e-6) return;
      points.add(Offset(
        (projected.x / projected.w * 0.5 + 0.5) * size.width,
        (1 - (projected.y / projected.w * 0.5 + 0.5)) * size.height,
      ));
    }

    final path = Path();
    for (final edge in _edges) {
      path
        ..moveTo(points[edge[0]].dx, points[edge[0]].dy)
        ..lineTo(points[edge[1]].dx, points[edge[1]].dy);
    }

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
