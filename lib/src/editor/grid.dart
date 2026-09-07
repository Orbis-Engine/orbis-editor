import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math_64.dart';

import 'snapping.dart';

/// Where the grid is and how big its squares are, for one frame.
class GridPlan {
  const GridPlan({
    required this.mesh,
    required this.texture,
    required this.centre,
    required this.extent,
    required this.step,
  });

  /// The quad. Absolute, like the texture: the renderer is handed paths, not
  /// project-relative references, and the grid does not go through the
  /// resolver an object's mesh does.
  final String mesh;

  /// The lines, absolute, because that is what a material takes.
  final String texture;

  /// Where it is centred, already snapped.
  final Vector3 centre;

  /// How far across the whole thing is.
  final double extent;

  /// How big one square is.
  final double step;

  /// How many squares across. Fixed, which is what makes the grid tell
  /// somebody the size of the snap rather than the size of the world.
  static const int across = 100;

  /// The key the renderer knows the grid by. Chosen far from anything an
  /// object gets, because the grid is not an object and never will be one.
  static const int renderKey = -777;
  static const int materialKey = -777;
}

/// The grid, as something in the scene rather than something drawn over it.
///
/// A grid painted in Flutter on top of the viewport is a grid that shows
/// through walls. This one is a surface in the world: unlit, blended, writing
/// no depth, and therefore hidden by whatever is in front of it — which is
/// what makes it read as a floor somebody is standing on rather than as an
/// overlay.
///
/// It follows the camera, snapped to its own squares, so it never runs out
/// and never appears to slide.
class GridStore {
  GridStore(this.projectRoot);

  final String projectRoot;

  String? _mesh;
  String? _texture;
  bool _building = false;

  /// The quad and the lines, made once.
  ///
  /// A unit square, scaled by the transform, so changing the snap size never
  /// rewrites a file — and one image of ten squares by ten, repeated ten
  /// times, which is where the heavier line every tenth comes from.
  Future<void> prepare() async {
    if (_building || _mesh != null) return;
    _building = true;
    try {
      final folder = Directory(p.join(projectRoot, '.orbis'));
      await folder.create(recursive: true);

      final quad = Mesh(
        positions: [
          Vector3(-0.5, 0, -0.5),
          Vector3(-0.5, 0, 0.5),
          Vector3(0.5, 0, 0.5),
          Vector3(0.5, 0, -0.5),
        ],
        // One face. The material culls nothing, so it is there when the
        // camera drops below it — a second face turned the other way would
        // only mean drawing the same pixels twice, and this is a
        // screen-filling blended surface where twice is expensive.
        faces: [Face([0, 1, 2, 3])],
      );
      final mesh = File(p.join(folder.path, 'grid.glb'));
      await mesh.writeAsBytes(quad.toGlb(name: 'grid'), flush: true);

      final lines = File(p.join(folder.path, 'grid.png'));
      await lines.writeAsBytes(await _draw(), flush: true);

      _mesh = mesh.path;
      _texture = lines.path;
    } on FileSystemException {
      // A project folder that will not take a file is a project where the
      // grid does not show. Everything else still works, which beats
      // refusing to open the scene.
      _mesh = null;
      _texture = null;
    } finally {
      _building = false;
    }
  }

  /// Where the grid should be this frame, or null when it is off or not built.
  GridPlan? planFor(Snapping snapping, Vector3 lookingAt) {
    final mesh = _mesh;
    final texture = _texture;
    if (!snapping.on || snapping.step <= 0 || mesh == null || texture == null) {
      return null;
    }

    final extent = snapping.step * GridPlan.across;
    // Snapped to its own squares, so it slides under the camera in whole
    // cells and never appears to move.
    Vector3 snapped(Vector3 at) => Vector3(
          (at.x / snapping.step).roundToDouble() * snapping.step,
          0,
          (at.z / snapping.step).roundToDouble() * snapping.step,
        );

    return GridPlan(
      mesh: mesh,
      texture: texture,
      centre: snapped(lookingAt),
      extent: extent,
      step: snapping.step,
    );
  }

  /// Ten squares by ten, with the edges of the tile heavier than the lines
  /// inside it — which is where the every-tenth line comes from once the
  /// image is repeated ten times across the quad.
  static Future<Uint8List> _draw() async {
    const size = 512;
    const cells = 10;
    const cell = size ~/ cells;
    final pixels = Uint8List(size * size * 4);

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final at = (y * size + x) * 4;

        // Distance to the nearest line, in pixels, on each axis.
        final acrossCell = x % cell;
        final downCell = y % cell;
        final onThin = acrossCell == 0 || downCell == 0;
        final onThick = (x < 2 || x >= size - 1) || (y < 2 || y >= size - 1);

        var alpha = 0;
        if (onThick) {
          alpha = 150;
        } else if (onThin) {
          alpha = 60;
        }

        pixels[at] = 255;
        pixels[at + 1] = 255;
        pixels[at + 2] = 255;
        pixels[at + 3] = alpha;
      }
    }

    final image = await _decode(pixels, size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  static Future<ui.Image> _decode(Uint8List pixels, int size) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}

/// The grid as the renderer takes it.
extension GridAsScene on GridPlan {
  /// Where the quad stands: flat, centred, and scaled to the whole extent.
  ///
  /// Exactly on nought. It used to sit a hair below to lose the depth test
  /// against anything built on the ground plane, which worked at that height
  /// and nowhere else — a surface dragged *through* the plane still met it.
  /// The material's depth bias does that job properly and at every height.
  Matrix4 get transform => Matrix4.identity()
    ..setTranslation(Vector3(centre.x, 0, centre.z))
    ..multiply(Matrix4.diagonal3(Vector3(extent, 1, extent)));

  OrbisObject get object => OrbisObject(
        key: GridPlan.renderKey,
        transform: transform,
        colour: Vector3(1, 1, 1),
        mesh: mesh,
        material: GridPlan.materialKey,
        // It is a drawing aid, not a thing in the world: it casts nothing and
        // catches nothing.
        castShadows: false,
        receiveShadows: false,
      );

  OrbisMaterial get material => OrbisMaterial(
        key: GridPlan.materialKey,
        shading: OrbisShading.unlit,
        blend: OrbisBlend.fade,
        culling: OrbisCulling.none,
        // Writing depth would make the grid hide what is behind it, and it is
        // a hint about where the floor is rather than a floor.
        depthWrite: false,
        // And behind anything sharing its plane. A floor built on the ground
        // plane, or a surface dragged through it, is at the same depth as the
        // grid for a moment — and two things at the same depth flicker pixel
        // by pixel as the camera moves. The grid is a hint about where the
        // ground is; it should lose every time.
        depthBias: 0.002,
        baseColour: Vector4(0.62, 0.68, 0.78, 0.75),
        // Ten across the image and ten images across the quad: a hundred
        // squares, each one snap step.
        tiling: Vector2(10, 10),
        baseColourMap: OrbisTexture(texture),
      );
}
