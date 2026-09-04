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
  const OrbitCamera({
    this.yaw = 0.6,
    this.pitch = 0.35,
    this.distance = 12,
    this.fieldOfView = 50,
  });

  final double yaw;
  final double pitch;
  final double distance;
  final double fieldOfView;

  static const _target = (x: 0.0, y: 0.5, z: 0.0);

  /// Pitch is clamped just short of straight up and straight down: at exactly
  /// vertical the up vector and the view direction are parallel and the view
  /// matrix collapses, which shows up as the image flipping.
  static const _pitchLimit = math.pi / 2 - 0.02;

  OrbitCamera orbit(Offset delta) => OrbitCamera(
        yaw: yaw - delta.dx * 0.008,
        pitch: (pitch + delta.dy * 0.008).clamp(-_pitchLimit, _pitchLimit),
        distance: distance,
        fieldOfView: fieldOfView,
      );

  OrbitCamera zoom(double amount) => OrbitCamera(
        yaw: yaw,
        pitch: pitch,
        distance: (distance * math.exp(amount * 0.0016)).clamp(1.5, 200.0),
        fieldOfView: fieldOfView,
      );

  OrbisCamera toRenderCamera() {
    final horizontal = distance * math.cos(pitch);
    return OrbisCamera(
      position: Vector3(
        _target.x + horizontal * math.sin(yaw),
        _target.y + distance * math.sin(pitch),
        _target.z + horizontal * math.cos(yaw),
      ),
      target: Vector3(_target.x, _target.y, _target.z),
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
  const SceneViewport({super.key, required this.scene});

  final EditorScene scene;

  @override
  State<SceneViewport> createState() => _SceneViewportState();
}

class _SceneViewportState extends State<SceneViewport> {
  OrbitCamera _camera = const OrbitCamera();
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
      child: Stack(
        children: [
          Positioned.fill(
            child: _rendererAvailable ? _buildSurface() : const _Placeholder(),
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
              child: _ViewportChip('Drag to orbit · scroll to zoom'),
            ),
        ],
      ),
    );
  }

  Widget _buildSurface() {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        setState(() => _camera = _camera.zoom(event.scrollDelta.dy));
      },
      child: GestureDetector(
        // Opaque so drags land here rather than falling through to whatever
        // scrolls behind the viewport.
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _dragAnchor = details.localPosition,
        onPanUpdate: (details) {
          final anchor = _dragAnchor;
          if (anchor == null) return;
          setState(() {
            _camera = _camera.orbit(details.localPosition - anchor);
            _dragAnchor = details.localPosition;
          });
        },
        onPanEnd: (_) => _dragAnchor = null,
        child: OrbisView(
          scene: widget.scene.toRenderScene(_camera.toRenderCamera()),
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
