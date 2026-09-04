import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/assets.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_assets');
    Directory(p.join(root.path, 'assets', 'meshes')).createSync(recursive: true);
    Directory(p.join(root.path, 'scenes')).createSync(recursive: true);
    File(p.join(root.path, 'scenes', 'main.orbisscene')).writeAsStringSync('{}');
    File(p.join(root.path, 'assets', 'meshes', 'crate.glb'))
        .writeAsBytesSync(List.filled(2048, 0));
    File(p.join(root.path, 'assets', 'rock.png')).writeAsBytesSync([1, 2, 3]);
    File(p.join(root.path, '.hidden')).writeAsStringSync('x');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('reading a folder', () {
    test('puts folders first and then sorts by name', () {
      final entries = AssetTree(root.path).read(root.path);
      expect([for (final e in entries) e.name], ['assets', 'scenes']);
    });

    test('leaves dotfiles out, since they are the tool\'s business', () {
      final entries = AssetTree(root.path).read(root.path);
      expect([for (final e in entries) e.name], isNot(contains('.hidden')));
    });

    test('labels a file by its extension', () {
      final entries =
          AssetTree(root.path).read(p.join(root.path, 'assets', 'meshes'));
      expect(entries.single.kind, AssetKind.mesh);
    });

    test('an unknown extension is a file, not a crash', () {
      File(p.join(root.path, 'notes.zzz')).writeAsStringSync('x');
      final entries = AssetTree(root.path).read(root.path);
      final found = entries.firstWhere((e) => e.name == 'notes.zzz');
      expect(found.kind, AssetKind.other);
    });

    test('a folder that has gone reads as empty rather than throwing', () {
      // What happens when somebody deletes a folder in Finder while the
      // browser is open on it.
      final tree = AssetTree(root.path);
      expect(tree.read(p.join(root.path, 'nowhere')), isEmpty);
    });

    test('reports a size somebody can read', () {
      final entries =
          AssetTree(root.path).read(p.join(root.path, 'assets', 'meshes'));
      expect(entries.single.size, '2 KB');
    });

    test('a folder has no size, because the number would be a lie', () {
      final entries = AssetTree(root.path).read(root.path);
      expect(entries.first.bytes, isNull);
      expect(entries.first.size, '');
    });
  });

  group('the folder tree', () {
    test('finds nested folders with their depth', () {
      final folders = AssetTree(root.path).folders();
      final byName = {
        for (final f in folders) p.basename(f.path): f.depth,
      };
      expect(byName, {'assets': 0, 'meshes': 1, 'scenes': 0});
    });

    test('stops at the depth it is given, rather than walking forever', () {
      var deep = root.path;
      for (var i = 0; i < 6; i++) {
        deep = p.join(deep, 'd$i');
      }
      Directory(deep).createSync(recursive: true);

      final folders = AssetTree(root.path).folders(maximumDepth: 2);
      expect(folders.every((f) => f.depth <= 2), isTrue);
    });
  });

  group('the breadcrumb', () {
    test('is relative to the project', () {
      final tree = AssetTree(root.path);
      expect(tree.relative(p.join(root.path, 'assets', 'meshes')),
          p.join('assets', 'meshes'));
    });

    test('is empty at the root, rather than a dot', () {
      expect(AssetTree(root.path).relative(root.path), '');
    });

    test('shows the whole path for somewhere outside the project', () {
      // Rather than a string of ".." segments, which would be both ugly and a
      // sign that something has gone wrong.
      final tree = AssetTree(p.join(root.path, 'scenes'));
      final outside = p.join(root.path, 'assets');
      expect(tree.relative(outside), outside);
    });
  });

  group('watching', () {
    test('says when a file appears', () async {
      final tree = AssetTree(root.path);
      addTearDown(tree.dispose);

      final seen = tree.changes.first.timeout(const Duration(seconds: 5));
      // A beat for the watch to be in place before anything changes.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      File(p.join(root.path, 'new.png')).writeAsBytesSync([1]);

      await expectLater(seen, completes);
    });

    test('coalesces a burst into one', () async {
      final tree = AssetTree(root.path);
      addTearDown(tree.dispose);

      var fired = 0;
      final subscription = tree.changes.listen((_) => fired++);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // What copying a folder of assets in looks like.
      for (var i = 0; i < 30; i++) {
        File(p.join(root.path, 'burst$i.png')).writeAsBytesSync([1]);
      }

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(fired, lessThanOrEqualTo(2),
          reason: 'thirty files should not mean thirty rebuilds');
      expect(fired, greaterThan(0));
    });

    test('disposing stops it, so a closed browser is not still listening',
        () async {
      final tree = AssetTree(root.path)..changes.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      tree.dispose();

      // Nothing to assert beyond it not throwing or leaking a timer that the
      // test binding would then complain about.
      File(p.join(root.path, 'after.png')).writeAsBytesSync([1]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });
}
