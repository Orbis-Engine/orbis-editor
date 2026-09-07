import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/commands.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/scene_document.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

// ignore_for_file: avoid_print
// What a frame of a drag costs, and how much of that is the editor rebuilding
// itself rather than the drag doing anything.
//
// A benchmark, not an assertion: the numbers depend on the machine and on the
// build being a debug one, which is several times slower than a profile
// build. What it is for is that "dragging feels laggy" has somewhere to start
// other than guessing.
//
// For scale, a trivial widget in this same harness costs about 1.8 ms a frame
// after a setState. Anything above that is the editor's own tree.
void main() {
  /// A layout holding just these panels, so each one's share of a drag frame
  /// can be measured by leaving it out.
  String layoutOf(List<String> kinds) {
    final panels = [
      for (final kind in kinds) '{"id":"$kind","kind":"$kind"}',
    ].join(',');
    return '{"locked":false,"root":'
        '{"type":"group","id":"only","panels":[$panels]}}';
  }

  Future<void> bench(
    WidgetTester tester,
    int count, {
    List<String>? panels,
    String? label,
    Size size = const Size(1440, 900),
  }) async {
    final root = Directory.systemTemp.createTempSync('orbis_drag');
    Directory('${root.path}/scenes').createSync(recursive: true);

    final scene = EditorScene([
      for (var i = 0; i < count; i++)
        SceneObject(
          id: 'o$i',
          name: 'o$i',
          kind: ObjectKind.shape,
          position: Vector3(i * 2.0, 0, 0),
          shape: Shape.of(ShapeKind.stairs),
        ),
    ]);
    File('${root.path}/scenes/main.oscene')
        .writeAsStringSync(SceneDocument.encode(scene, name: 'main'));
    if (panels != null) {
      Directory('${root.path}/.orbis').createSync(recursive: true);
      File('${root.path}/.orbis/layout.json').writeAsStringSync(
        layoutOf(panels),
      );
    }

    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: EditorShell(
        project: Project(
          name: 'T',
          directory: root.path,
          lastOpened: DateTime(2026),
        ),
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final viewport = tester.widget<SceneViewport>(find.byType(SceneViewport));
    final open = viewport.workspace.loaded!;
    final history = viewport.history!;
    final live = open.scene!;
    viewport.onPick!('o0', add: false);
    await tester.pumpAndSettle();

    void runOne(int i) {
      history.run(TransformMany(
        sceneId: open.id,
        field: TransformField.position,
        what: 'o0',
        changes: {
          'o0': (from: Vector3.zero(), to: Vector3(0, i * 0.01, 0)),
        },
      ));
    }

    Future<void> drag(int frames) async {
      for (var i = 0; i < frames; i++) {
        runOne(i);
        await tester.pump();
      }
    }

    await drag(5);

    // What a frame costs when nothing changed, so the harness's own cost is
    // not counted as the editor's.
    final idle = Stopwatch()..start();
    for (var i = 0; i < 60; i++) {
      await tester.pump();
    }
    idle.stop();

    // The command on its own: everything that happens synchronously inside
    // `run`, which is the whole of `_onChanged` bar the frame it asks for.
    final commanding = Stopwatch()..start();
    for (var i = 0; i < 60; i++) {
      runOne(i);
    }
    commanding.stop();
    await tester.pump();

    final watch = Stopwatch()..start();
    await drag(60);
    watch.stop();
    final dragging = watch.elapsedMicroseconds / 60 / 1000;
    final still = idle.elapsedMicroseconds / 60 / 1000;
    print('  ${(label ?? '$count shapes').padRight(24)} '
        '${dragging.toStringAsFixed(2).padLeft(6)} ms a drag frame · '
        '${(commanding.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)}'
        ' of it the command, '
        '${(dragging - commanding.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)}'
        ' the frame');
    expect(live.length, greaterThan(0));
    root.deleteSync(recursive: true);
  }

  testWidgets('what a drag frame costs in the editor', (tester) async {
    print('  one drag frame in the editor:');
    // Warmed first: the very first measured run in a process pays for code
    // that has not been compiled yet, and reporting that as the cost of a
    // frame is how a measurement lies.
    await bench(tester, 40, label: 'warming up');

    // Twice, because the first measurement in a process pays for code that
    // has not been compiled yet.
    for (var round = 0; round < 2; round++) {
      await bench(tester, 40, label: 'forty shapes, one selected');
      await bench(tester, 1, label: 'one shape');
    }
  });
}
