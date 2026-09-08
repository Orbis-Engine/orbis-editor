import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/asset_browser.dart';
import 'package:orbis_editor/src/editor/assets.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:path/path.dart' as p;

/// A real two-by-two PNG. Written rather than faked, because `Image.file` on
/// a byte of nonsense falls through to the error builder and shows the very
/// icon this is meant to prove is gone — a test that passes because the
/// picture failed to load is a test of nothing.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNg0DgBQhUaPUAEABo6BDmBaztmAAAAAElFTkSuQmCC',
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_assets');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: Scaffold(body: AssetBrowser(tree: AssetTree(root.path))),
    ));
    await tester.pumpAndSettle();
  }

  group('the asset browser', () {
    testWidgets('points a texture tile at the file itself', (tester) async {
      final path = p.join(root.path, 'colormap.png');
      File(path).writeAsBytesSync(_png);

      await show(tester);

      // What the tile is *for* the file, not what the decoder made of it.
      // Whether an image decodes is Flutter's business and arrives on a real
      // clock the widget tester does not run; asserting the picture appeared
      // would either be flaky or — worse — quietly pass because the fallback
      // had not been delivered either. What is this code's business is that
      // a png is routed to an Image and pointed at the right file.
      final image = tester.widget<Image>(find.byType(Image));

      // Wrapped, because the tile asks for a decode width. That wrapper is
      // the point rather than an implementation detail: a folder of 4K maps
      // decoded at their authored size is a gigabyte of pixels drawn at
      // forty-four points.
      final resized = image.image as ResizeImage;
      expect(resized.width, isNotNull);
      expect((resized.imageProvider as FileImage).file.path, path);
      expect(image.errorBuilder, isNotNull,
          reason: 'a file that will not decode should fall back to the icon');
    });

    testWidgets('keeps the icon for a texture it cannot decode',
        (tester) async {
      // A GPU format. Flutter has no decoder for it, and a broken-image box
      // would say less than a glyph that at least names the kind.
      File(p.join(root.path, 'rock.ktx2')).writeAsBytesSync([0xAB, 0x4B, 0x54]);

      await show(tester);

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(AssetKind.texture.icon), findsOneWidget);
    });

    testWidgets('keeps the icon for things that are not pictures',
        (tester) async {
      File(p.join(root.path, 'player.dart')).writeAsStringSync('void main() {}');

      await show(tester);

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(AssetKind.script.icon), findsOneWidget);
    });
  });
}
