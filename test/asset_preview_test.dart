import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/asset_browser.dart';
import 'package:orbis_editor/src/editor/asset_preview.dart';
import 'package:orbis_editor/src/editor/assets.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:path/path.dart' as p;

/// A real two-by-two PNG, for the same reason the browser's own test uses
/// one: `Image.file` on a byte of nonsense falls through to the error builder,
/// and a test that passes because the picture failed to load is a test of
/// nothing.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNg0DgBQhUaPUAEABo6BDmBaztmAAAAAElFTkSuQmCC',
);

/// A glTF that declares how big it is and nothing else.
///
/// Enough of a document for the bounds to be read, which is all the preview
/// asks of the file — the geometry is the renderer's business, and the
/// renderer is not running in a widget test.
String _gltf(double half) => jsonEncode({
  'asset': {'version': '2.0'},
  'meshes': [
    {
      'primitives': [
        {
          'attributes': {'POSITION': 0},
        },
      ],
    },
  ],
  'accessors': [
    {
      'type': 'VEC3',
      'min': [-half, -half, -half],
      'max': [half, half, half],
    },
  ],
});

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_preview');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: orbisTheme(),
        home: Scaffold(body: AssetBrowser(tree: AssetTree(root.path))),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String name) async {
    await tester.tap(find.text(name).first);
    // Past the double-tap window. A tile answers to both a tap and a double
    // tap, so the single tap is held in the gesture arena until the timer for
    // the second one expires — pumping one frame selects nothing, and reads
    // as the preview being broken rather than as the tap not having happened.
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// How far the preview camera has put itself from what it is looking at.
  double distance(WidgetTester tester) {
    final view = tester.widget<OrbisView>(find.byType(OrbisView));
    final camera = view.scene!.camera;
    return (camera.position - camera.target).length;
  }

  group('the asset preview', () {
    testWidgets('draws a model by pointing the renderer at the file', (
      tester,
    ) async {
      final path = p.join(root.path, 'barrel.gltf');
      File(path).writeAsStringSync(_gltf(0.5));

      await show(tester);
      await select(tester, 'barrel.gltf');

      // The file itself, not a picture of it made earlier. That is the whole
      // difference between a preview and a thumbnail somebody has to remember
      // to regenerate.
      final view = tester.widget<OrbisView>(find.byType(OrbisView));
      expect(view.scene!.objects.single.mesh, path);
    });

    testWidgets('frames a model by the size it declares', (tester) async {
      // The thing that makes a preview usable rather than decorative. A fixed
      // camera puts a door frame inside the lens and a doorknob in the far
      // distance, and both read as the renderer being broken.
      File(p.join(root.path, 'small.gltf')).writeAsStringSync(_gltf(0.25));
      File(p.join(root.path, 'large.gltf')).writeAsStringSync(_gltf(2.5));

      await show(tester);

      await select(tester, 'small.gltf');
      final near = distance(tester);

      await select(tester, 'large.gltf');
      final far = distance(tester);

      expect(
        far / near,
        closeTo(10, 0.01),
        reason: 'a model ten times the size should be viewed from ten times '
            'as far away, or it is not being framed at all',
      );
    });

    testWidgets('a model that will not say how big it is still opens', (
      tester,
    ) async {
      // An .obj declares nothing about its extent without being decoded. It
      // gets a sensible distance and a camera somebody can move, which is
      // honest — a confident guess at the wrong scale is worse.
      File(p.join(root.path, 'crate.obj')).writeAsStringSync('v 0 0 0\n');

      await show(tester);
      await select(tester, 'crate.obj');

      expect(distance(tester), greaterThan(0));
      expect(find.byType(OrbisView), findsOneWidget);
    });

    testWidgets('shows a texture as itself, at the file it came from', (
      tester,
    ) async {
      final path = p.join(root.path, 'colormap.png');
      File(path).writeAsBytesSync(_png);

      await show(tester);
      await select(tester, 'colormap.png');

      // Two now: the tile's thumbnail and the preview's larger copy. The one
      // that matters here is the unscaled one, because the preview exists to
      // be looked at rather than glanced at.
      final images = tester.widgetList<Image>(find.byType(Image));
      final full = images.where((image) => image.image is FileImage);
      expect(full, hasLength(1));
      expect((full.single.image as FileImage).file.path, path);
      expect(
        full.single.errorBuilder,
        isNotNull,
        reason: 'a file that will not decode should say so rather than break',
      );
    });

    testWidgets('says what a file it cannot draw is', (tester) async {
      File(p.join(root.path, 'player.ts')).writeAsStringSync('export {}');

      await show(tester);
      await select(tester, 'player.ts');

      expect(find.byType(OrbisView), findsNothing);
      // Naming the kind confirms the editor knows what the file is, which is
      // the question somebody has when nothing is drawn.
      expect(find.textContaining(AssetKind.script.label), findsWidgets);
    });

    testWidgets('can be shut, for a narrow window', (tester) async {
      File(p.join(root.path, 'barrel.gltf')).writeAsStringSync(_gltf(0.5));

      await show(tester);
      await select(tester, 'barrel.gltf');
      expect(find.byType(AssetPreview), findsOneWidget);

      await tester.tap(find.byTooltip('Hide the preview'));
      await tester.pumpAndSettle();

      expect(find.byType(AssetPreview), findsNothing);
      expect(find.byType(OrbisView), findsNothing);
    });

    testWidgets('survives the dock being dragged short', (tester) async {
      // Found by an unrelated test rendering this panel 57 points tall: the
      // placeholder was an icon above two lines of text in a Column, and a
      // Column that does not fit is not a smaller message, it is a stripe
      // where the message was. The dock this lives in can be dragged down to
      // a couple of rows, so that is a size it has to work at.
      File(p.join(root.path, 'player.ts')).writeAsStringSync('export {}');

      await tester.binding.setSurfaceSize(const Size(900, 132));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: orbisTheme(),
          home: Scaffold(body: AssetBrowser(tree: AssetTree(root.path))),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await select(tester, 'player.ts');
      expect(
        tester.takeException(),
        isNull,
        reason: 'a panel too short for its own placeholder should show less '
            'of it, not overflow',
      );
    });

    test('it knows what it can draw and what it can only describe', () {
      Asset named(String name) => Asset(
        name: name,
        path: '/project/$name',
        kind: AssetKind.of('/project/$name'),
      );

      expect(AssetPreview.draws(named('barrel.glb')), isTrue);
      expect(AssetPreview.draws(named('barrel.gltf')), isTrue);
      expect(AssetPreview.draws(named('colormap.png')), isTrue);
      // A GPU format Flutter has no decoder for, and a script.
      expect(AssetPreview.draws(named('rock.ktx2')), isFalse);
      expect(AssetPreview.draws(named('player.ts')), isFalse);
    });
  });
}
