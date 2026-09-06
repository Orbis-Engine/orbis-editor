import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/assets.dart';
import 'package:orbis_editor/src/editor/data_object.dart';
import 'package:orbis_editor/src/editor/script_build.dart';
import 'package:orbis_native/orbis_native.dart';
import 'package:path/path.dart' as p;

/// These compile real C++ against the real engine headers.
///
/// Slower than the rest of the suite and worth it: the point of the contract
/// is that what the editor writes builds, and the only way to know that is to
/// build it.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('orbis_cpp'));
  tearDown(() => root.deleteSync(recursive: true));

  DataObject ball() => DataObject(
        name: 'Ball settings',
        note: 'How the ball behaves',
        fields: [
          DataField(key: 'speed', type: DataType.number, value: 12.5,
              note: 'Metres a second'),
          DataField(key: 'bouncy', type: DataType.toggle, value: true),
          DataField(key: 'label', type: DataType.text, value: 'Ball'),
          DataField(key: 'tint', type: DataType.colour, value: '#D9634F'),
          DataField(key: 'spawn', type: DataType.vector, value: [0, 1, 2]),
        ],
      );

  /// Compiles a source file the way the editor does, and says what happened.
  BuildResult build(String name, String source) {
    File(p.join(root.path, '$name.cpp')).writeAsStringSync(source);
    return ScriptBuilder(root.path).build(p.join(root.path, '$name.cpp'));
  }

  test('there is a toolchain and there are headers', () {
    final builder = ScriptBuilder(root.path);
    expect(builder.problem, isNull,
        reason: 'without these the tests below would pass by not compiling');
  });

  group('what the editor writes', () {
    test('the C++ pair it writes compiles as it is', () {
      // Made the way the browser makes it, both halves at once, then built
      // without touching either. That is the claim: what the editor writes
      // builds.
      final made = AssetTree(root.path)
          .create(root.path, NewAsset.native, 'movement');
      expect(made.problem, isNull);

      final built = ScriptBuilder(root.path).build(made.path!);
      expect(built.ok, isTrue, reason: built.output);
    });

    test('the header it writes is what the source includes', () {
      AssetTree(root.path).create(root.path, NewAsset.native, 'movement');

      // Deleting the header breaks the build, which is how we know the
      // source is really reading it rather than carrying its own copy.
      File(p.join(root.path, 'movement.h')).deleteSync();
      final built =
          ScriptBuilder(root.path).build(p.join(root.path, 'movement.cpp'));

      expect(built.ok, isFalse);
      expect(built.output, contains('movement.h'));
    });

    test('a header on its own compiles when something includes it', () {
      AssetTree(root.path).create(root.path, NewAsset.header, 'shared');

      final built = build('user', '''
#include "shared.h"
ORBIS_SCRIPT { (void)sizeof(Drift); }
extern "C" void orbis_step(double d) { (void)d; }
extern "C" void orbis_stop(void) {}
''');
      expect(built.ok, isTrue, reason: built.output);
    });
  });

  group('the bindings a data object generates', () {
    test('the C++ header compiles and reads every kind of field', () {
      File(p.join(root.path, 'ball.h')).writeAsStringSync(ball().toCpp('ball'));

      final built = build('reader', '''
#include "ball.h"

ORBIS_SCRIPT {
  double speed = BallSettings::speed(1.0);
  bool bouncy = BallSettings::bouncy(false);
  const char *label = BallSettings::label();
  const char *tint = BallSettings::tint();
  double y = BallSettings::spawn(1);
  (void)speed; (void)bouncy; (void)label; (void)tint; (void)y;
}

extern "C" void orbis_step(double d) { (void)d; }
extern "C" void orbis_stop(void) {}
''');
      expect(built.ok, isTrue, reason: built.output);
    });

    test('it reads through an address rather than calling in', () {
      // The difference between a value that is safe to read once and one that
      // is safe to read inside a loop over everything.
      final header = ball().toCpp('ball');
      expect(header, contains('::orbis::number_at'));
      expect(header, contains('static const double *at'));
    });

    test('a field renamed here breaks the build there', () {
      // The whole reason to generate the header rather than write it.
      final renamed = ball();
      renamed.fields.first.key = 'velocity';
      File(p.join(root.path, 'ball.h'))
          .writeAsStringSync(renamed.toCpp('ball'));

      final built = build('stale', '''
#include "ball.h"
ORBIS_SCRIPT { (void)BallSettings::speed(1.0); }
extern "C" void orbis_step(double d) { (void)d; }
extern "C" void orbis_stop(void) {}
''');

      expect(built.ok, isFalse);
      expect(built.output, contains('speed'));
    });

    test('it names the asset it came from, so nothing types the path twice',
        () {
      expect(ball().toCpp('ball'), contains('"ball.odata"'));
    });

    test('the notes come across, since that is where they help', () {
      expect(ball().toCpp('ball'), contains('/// Metres a second'));
    });

    test('it says it was generated, so nobody edits it', () {
      expect(ball().toCpp('ball'), contains('Do not edit'));
    });
  });

  group('building from the editor', () {
    test('a script that does not compile says why', () {
      final built = build('broken', '#include "orbis_script.h"\nnonsense here');

      expect(built.ok, isFalse);
      expect(built.output, isNotEmpty);
    });

    test('what is built goes somewhere disposable inside the project', () {
      final made =
          AssetTree(root.path).create(root.path, NewAsset.native, 'system');
      ScriptBuilder(root.path).build(made.path!);

      expect(
        Directory(p.join(root.path, '.orbis', 'build')).existsSync(),
        isTrue,
      );
    });

    test('two builds of one file do not fight over a path', () {
      final made =
          AssetTree(root.path).create(root.path, NewAsset.native, 'system');
      ScriptBuilder(root.path).build(made.path!);
      ScriptBuilder(root.path).build(made.path!);

      // A library already loaded cannot be closed, so a rebuild has to be a
      // different file or it would go on running the old code.
      final built = Directory(p.join(root.path, '.orbis', 'build'))
          .listSync()
          .where((e) => e.path.endsWith(Toolchain.librarySuffix));
      expect(built.length, greaterThan(1));
    });

    test('only a source file is offered a build', () {
      Asset asset(String name) => Asset(
            name: name,
            path: p.join(root.path, name),
            kind: AssetKind.of(name),
          );

      expect(asset('system.cpp').canBuild, isTrue);
      expect(asset('system.h').canBuild, isFalse);
      expect(asset('behaviour.ts').canBuild, isFalse);
      expect(asset('rock.png').canBuild, isFalse);
    });
  });
}
