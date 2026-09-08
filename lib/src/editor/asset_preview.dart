import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_mesh/orbis_mesh.dart' show boundsOfGlb, boundsOfGltf;
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'assets.dart';

/// What the selected asset actually looks like.
///
/// A project is a list of file names until something shows what is in them.
/// `barrel_02.gltf` and `barrel_03.gltf` are the same word to a reader and two
/// different barrels to whoever made them, and the only way to tell is to open
/// each one in turn into a scene — which is not looking at a project, it is
/// searching one.
///
/// So a model is drawn, by the renderer, from the file on disk. Not a picture
/// of a model somebody exported alongside it and which stops being true the
/// first time the model changes: the thing itself, framed by the size the file
/// declares, turning slowly so that its shape reads rather than one silhouette
/// of it.
///
/// Beside the outliner rather than in the inspector, on the same reasoning the
/// asset browser was put along the bottom: the inspector answers what is in
/// this scene, and picking a file out of the project is a different question
/// that should not take the panel away from the object being edited.
class AssetPreview extends StatefulWidget {
  const AssetPreview({super.key, required this.asset});

  /// What is selected, or null when nothing is.
  final Asset? asset;

  /// Whether this asset is one this panel can draw rather than describe.
  static bool draws(Asset asset) =>
      !asset.isFolder &&
      (asset.kind == AssetKind.mesh || _Picture.decodable(asset));

  @override
  State<AssetPreview> createState() => _AssetPreviewState();
}

class _AssetPreviewState extends State<AssetPreview>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick)..start();
  Duration _elapsed = Duration.zero;

  /// Where the preview camera is looking from, in the same terms as the
  /// gallery's: an orbit somebody can take hold of.
  double _yaw = 0.7;
  double _pitch = 0.3;
  double _zoom = 1;
  Offset? _dragging;

  /// Off while somebody is looking at one side of something.
  bool _turning = true;

  /// The size the file declares, or null when it does not.
  ({Vector3 min, Vector3 max})? _bounds;
  String? _measured;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    if (!_turning) return;
    // Only while a model is on screen. A ticker running behind a picture or an
    // empty panel is sixty rebuilds a second of a widget that cannot change.
    final asset = widget.asset;
    if (asset == null || asset.kind != AssetKind.mesh) return;
    setState(() => _elapsed = elapsed);
  }

  /// How big the file says it is, read once per file.
  ///
  /// Only the two glTF containers declare it. An `.obj` or an `.fbx` says
  /// nothing about its own extent without being decoded, so those open at a
  /// distance that suits a human-sized object and are moved by hand — which
  /// is honest, and better than framing them confidently and wrongly.
  ({Vector3 min, Vector3 max})? _boundsOf(Asset asset) {
    if (_measured == asset.path) return _bounds;
    _measured = asset.path;
    _bounds = null;
    try {
      final file = File(asset.path);
      if (file.existsSync()) {
        _bounds = switch (p.extension(asset.path).toLowerCase()) {
          '.glb' => boundsOfGlb(file.readAsBytesSync()),
          '.gltf' => boundsOfGltf(file.readAsStringSync()),
          _ => null,
        };
      }
    } on FileSystemException {
      _bounds = null;
    }
    return _bounds;
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;

    return Container(
      width: 236,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(left: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title(asset: asset, turning: _turning, onTurn: _setTurning),
          Expanded(child: _stage(asset)),
          if (asset != null) _Facts(asset: asset, bounds: _bounds),
        ],
      ),
    );
  }

  void _setTurning(bool value) => setState(() => _turning = value);

  Widget _stage(Asset? asset) {
    if (asset == null) {
      return const _Empty('Select a file to see what is in it');
    }
    if (asset.isFolder) {
      return const _Empty('A folder has nothing to show');
    }
    if (_Picture.decodable(asset)) return _Picture(asset: asset);
    if (asset.kind != AssetKind.mesh) {
      return _Empty.forKind(asset.kind);
    }
    return _model(asset);
  }

  Widget _model(Asset asset) {
    final box = _boundsOf(asset);

    // The middle of the model and how far back to sit from it. A file that
    // does not declare its size is opened at arm's length rather than framed,
    // because a confident guess at the wrong scale puts the model inside the
    // camera or in the far distance, and both look like the renderer failing.
    final centre = box == null
        ? Vector3.zero()
        : (box.min + box.max) * 0.5;
    final radius = box == null
        ? 1.0
        : math.max(0.05, (box.max - box.min).length * 0.5);

    final seconds = _elapsed.inMilliseconds / 1000;
    final yaw = _yaw + (_turning ? seconds * 0.5 : 0);
    final away = radius * 2.6 * _zoom;
    final flat = away * math.cos(_pitch);

    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        setState(() {
          _zoom = (_zoom * (1 + event.scrollDelta.dy * 0.0016)).clamp(0.3, 6.0);
        });
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Taking hold of it stops the turntable, because somebody dragging is
        // trying to look at one particular side and a model that keeps turning
        // under the pointer is one they cannot.
        onPanStart: (details) {
          _dragging = details.localPosition;
          if (_turning) _setTurning(false);
        },
        onPanUpdate: (details) {
          final from = _dragging;
          if (from == null) return;
          final delta = details.localPosition - from;
          setState(() {
            _yaw -= delta.dx * 0.008;
            _pitch = (_pitch + delta.dy * 0.008).clamp(-1.4, 1.4);
          });
          _dragging = details.localPosition;
        },
        onPanEnd: (_) => _dragging = null,
        child: OrbisView(
          scene: OrbisScene(
            camera: OrbisCamera(
              position: Vector3(
                centre.x + flat * math.sin(yaw),
                centre.y + away * math.sin(_pitch),
                centre.z + flat * math.cos(yaw),
              ),
              target: centre,
              fieldOfView: 45,
            ),
            objects: [
              OrbisObject(
                key: 1,
                mesh: asset.path,
                transform: Matrix4.identity(),
                colour: Vector3(1, 1, 1),
              ),
            ],
            // A key light, a fill from the other side and a rim behind, which
            // is the arrangement a product photograph uses and for the same
            // reason: one light leaves half of a shape unreadable, and this
            // panel exists to make a shape readable.
            lights: [
              OrbisLight(
                key: 1,
                kind: OrbisLightKind.directional,
                direction: Vector3(-0.4, -0.8, -0.45)..normalize(),
                intensity: 80000,
              ),
              OrbisLight(
                key: 2,
                kind: OrbisLightKind.directional,
                direction: Vector3(0.6, -0.35, 0.5)..normalize(),
                colour: Vector3(0.72, 0.79, 1),
                intensity: 26000,
                castShadows: false,
              ),
              OrbisLight(
                key: 3,
                kind: OrbisLightKind.directional,
                direction: Vector3(0.15, -0.2, -0.9)..normalize(),
                intensity: 18000,
                castShadows: false,
              ),
            ],
            sky: OrbisSky(
              colour: Vector3(0.055, 0.065, 0.086),
              ambient: 14000,
              drawn: false,
            ),
          ),
        ),
      ),
    );
  }
}

/// The panel's own heading, and the one control it has.
class _Title extends StatelessWidget {
  const _Title({
    required this.asset,
    required this.turning,
    required this.onTurn,
  });

  final Asset? asset;
  final bool turning;
  final ValueChanged<bool> onTurn;

  @override
  Widget build(BuildContext context) {
    final showsTurn = asset != null && asset!.kind == AssetKind.mesh;

    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              asset?.name ?? 'Preview',
              overflow: TextOverflow.ellipsis,
              style: OrbisText.label.copyWith(color: OrbisColors.inkMid),
            ),
          ),
          if (showsTurn)
            IconButton(
              iconSize: 15,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              tooltip: turning ? 'Stop turning' : 'Turn',
              onPressed: () => onTurn(!turning),
              icon: Icon(
                turning ? Icons.pause : Icons.play_arrow,
                color: OrbisColors.inkDim,
              ),
            ),
        ],
      ),
    );
  }
}

/// An image, shown as an image.
///
/// The renderer is not involved. A texture is already a picture, and putting
/// it on a sphere to photograph it would hide the thing somebody is checking —
/// whether this is the right colour map, whether it has an alpha channel,
/// whether it is the atlas or one tile out of it.
class _Picture extends StatelessWidget {
  const _Picture({required this.asset});

  final Asset asset;

  /// What Flutter's own decoders handle. A `.ktx2` is compressed for a GPU
  /// and a `.hdr` carries more range than a screen has; neither is something
  /// `Image.file` can open.
  static const _formats = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

  static bool decodable(Asset asset) =>
      !asset.isFolder &&
      asset.kind == AssetKind.texture &&
      _formats.contains(p.extension(asset.path).toLowerCase());

  @override
  Widget build(BuildContext context) {
    return Container(
      // The chequer behind it, so that transparency reads as transparency
      // rather than as whatever colour the panel happens to be.
      color: OrbisColors.ground,
      padding: const EdgeInsets.all(Space.sm),
      child: Center(
        child: CustomPaint(
          painter: _Chequer(),
          child: Image.file(
            File(asset.path),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) =>
                const _Empty('This file could not be read as an image'),
          ),
        ),
      ),
    );
  }
}

/// The squares behind a transparent image.
class _Chequer extends CustomPainter {
  static const _square = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFF20262F);
    final dark = Paint()..color = const Color(0xFF171C24);
    for (var y = 0.0; y < size.height; y += _square) {
      for (var x = 0.0; x < size.width; x += _square) {
        final even = ((x / _square).floor() + (y / _square).floor()).isEven;
        canvas.drawRect(
          Rect.fromLTWH(x, y, _square, _square),
          even ? light : dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Chequer oldDelegate) => false;
}

/// What is known about a file that is not what it looks like.
class _Facts extends StatelessWidget {
  const _Facts({required this.asset, required this.bounds});

  final Asset asset;
  final ({Vector3 min, Vector3 max})? bounds;

  @override
  Widget build(BuildContext context) {
    final box = bounds;
    final size = box == null ? null : box.max - box.min;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Fact('Kind', asset.kind.label),
          if (asset.size.isNotEmpty) _Fact('Size', asset.size),
          if (size != null)
            _Fact(
              'Extent',
              '${size.x.toStringAsFixed(2)} × '
                  '${size.y.toStringAsFixed(2)} × '
                  '${size.z.toStringAsFixed(2)}',
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: OrbisText.label.copyWith(
                fontSize: 11,
                color: OrbisColors.inkDim,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: OrbisText.body.copyWith(
                fontSize: 11,
                color: OrbisColors.inkMid,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Why there is nothing to look at, said rather than left blank.
class _Empty extends StatelessWidget {
  const _Empty(this.saying, {this.icon});

  final String saying;
  final IconData? icon;

  /// For the kinds that are files rather than pictures. Naming the kind is
  /// more use than a shrug: it confirms the editor knows what the file is,
  /// which is the question somebody actually has when nothing is drawn.
  factory _Empty.forKind(AssetKind kind) =>
      _Empty('${kind.label} — nothing to draw', icon: kind.icon);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, space) {
        // This panel is inside a dock that can be dragged down to a couple of
        // rows, and a column of icon-above-two-lines that does not fit is not
        // a smaller message — it is an overflow stripe where the message was.
        // The icon is the part worth losing, and the words are the part that
        // was carrying the meaning anyway.
        final room = space.maxHeight >= 84;

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null && room) ...[
                  Icon(icon, size: 26, color: OrbisColors.inkDim),
                  const SizedBox(height: Space.sm),
                ],
                Flexible(
                  child: Text(
                    saying,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: OrbisText.body.copyWith(
                      fontSize: 11,
                      color: OrbisColors.inkDim,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
