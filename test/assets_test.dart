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

  group('deleting', () {
    test('removes a file', () {
      final tree = AssetTree(root.path);
      final target = p.join(root.path, 'assets', 'rock.png');

      expect(tree.delete(target), isNull);
      expect(File(target).existsSync(), isFalse);
    });

    test('removes a folder and what is in it', () {
      final tree = AssetTree(root.path);
      expect(tree.delete(p.join(root.path, 'assets')), isNull);
      expect(Directory(p.join(root.path, 'assets')).existsSync(), isFalse);
    });

    test('says so when there is nothing there, rather than pretending', () {
      // Silently succeeding is how somebody comes to believe a file is gone
      // when it is not.
      expect(AssetTree(root.path).delete(p.join(root.path, 'ghost')),
          isNotNull);
    });
  });

  group('renaming', () {
    test('moves it within its folder', () {
      final tree = AssetTree(root.path);
      final from = p.join(root.path, 'assets', 'rock.png');

      expect(tree.rename(from, 'stone.png'), isNull);
      expect(File(p.join(root.path, 'assets', 'stone.png')).existsSync(),
          isTrue);
      expect(File(from).existsSync(), isFalse);
    });

    test('refuses to overwrite something already there', () {
      final tree = AssetTree(root.path);
      File(p.join(root.path, 'assets', 'stone.png')).writeAsBytesSync([9]);

      final problem =
          tree.rename(p.join(root.path, 'assets', 'rock.png'), 'stone.png');

      expect(problem, isNotNull);
      // And the other file is untouched, rather than half-replaced.
      expect(File(p.join(root.path, 'assets', 'stone.png')).readAsBytesSync(),
          [9]);
    });

    test('refuses a name with a path in it', () {
      final tree = AssetTree(root.path);
      final problem = tree.rename(
        p.join(root.path, 'assets', 'rock.png'),
        '../escaped.png',
      );
      expect(problem, isNotNull);
      expect(File(p.join(root.path, '..', 'escaped.png')).existsSync(),
          isFalse);
    });

    test('refuses an empty name', () {
      expect(
        AssetTree(root.path).rename(p.join(root.path, 'assets', 'rock.png'), '  '),
        isNotNull,
      );
    });

    test('renaming to the same name is not an error', () {
      expect(
        AssetTree(root.path)
            .rename(p.join(root.path, 'assets', 'rock.png'), 'rock.png'),
        isNull,
      );
    });

    test('a folder renames too', () {
      final tree = AssetTree(root.path);
      expect(tree.rename(p.join(root.path, 'scenes'), 'levels'), isNull);
      expect(Directory(p.join(root.path, 'levels')).existsSync(), isTrue);
    });
  });

  group('a free name', () {
    test('is the one asked for when nothing is using it', () {
      expect(
        p.basename(AssetTree(root.path).available(root.path, 'new.oscene')),
        'new.oscene',
      );
    });

    test('is numbered when it is taken, keeping the extension', () {
      File(p.join(root.path, 'new.oscene')).writeAsStringSync('x');
      expect(
        p.basename(AssetTree(root.path).available(root.path, 'new.oscene')),
        'new 2.oscene',
      );
    });
  });

  group('making things', () {
    test('a folder appears where it was asked for', () {
      final tree = AssetTree(root.path);
      final made = tree.create(root.path, NewAsset.folder, 'props');

      expect(made.problem, isNull);
      expect(Directory(p.join(root.path, 'props')).existsSync(), isTrue);
    });

    test('a script gets its extension and something to run', () {
      final tree = AssetTree(root.path);
      final made = tree.create(root.path, NewAsset.script, 'walker');

      expect(made.path, endsWith('walker.ts'));
      expect(File(made.path!).readAsStringSync(), contains('onFrame'));
    });

    test('every kind writes a starter that is not empty', () {
      final tree = AssetTree(root.path);
      for (final what in NewAsset.values) {
        if (what.isFolder) continue;
        final made = tree.create(root.path, what, what.name);
        expect(made.problem, isNull, reason: what.name);
        expect(File(made.path!).readAsStringSync().trim(), isNotEmpty,
            reason: what.name);
      }
    });

    test('the second one of a name gets a name of its own', () {
      final tree = AssetTree(root.path);
      tree.create(root.path, NewAsset.folder, 'props');
      final second = tree.create(root.path, NewAsset.folder, 'props');

      expect(second.problem, isNull);
      expect(p.basename(second.path!), isNot('props'));
      expect(Directory(second.path!).existsSync(), isTrue);
    });

    test('a name that is a path is refused rather than followed', () {
      final tree = AssetTree(root.path);
      final made = tree.create(root.path, NewAsset.folder, '../escaped');

      expect(made.problem, isNotNull);
      expect(Directory(p.join(root.parent.path, 'escaped')).existsSync(),
          isFalse);
    });

    test('an empty name is refused', () {
      final tree = AssetTree(root.path);
      expect(tree.create(root.path, NewAsset.folder, '   ').problem, isNotNull);
    });

    test('nothing is made outside the project', () {
      final tree = AssetTree(root.path);
      final outside = root.parent.path;
      expect(tree.create(outside, NewAsset.folder, 'nope').problem, isNotNull);
    });

    test('what a script is called it is kinded as', () {
      final tree = AssetTree(root.path);
      final made = tree.create(root.path, NewAsset.interface, 'panel');

      expect(tree.describe(made.path!).kind, AssetKind.script);
    });

    test('a written file comes back described', () {
      final tree = AssetTree(root.path);
      final made = tree.write(root.path, 'crate.oprefab', '{"version":1}');

      expect(made.problem, isNull);
      final asset = tree.describe(made.path!);
      expect(asset.kind, AssetKind.prefab);
      expect(asset.bytes, 13);
    });
  });
}
