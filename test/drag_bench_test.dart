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

    // Every frame timed on its own, and the *fastest* one reported.
    //
    // Not the average. This runs on a machine doing other things, and an
    // average is dragged around by whatever else the machine was doing —
    // enough that removing widgets from the tree once measured as making it
    // slower. The fastest frame is the one where nothing interfered, which is
    // the closest thing to what the code actually costs.
    final samples = <double>[];
    for (var i = 0; i < 120; i++) {
      final watch = Stopwatch()..start();
      runOne(i);
      await tester.pump();
      watch.stop();
      samples.add(watch.elapsedMicroseconds / 1000);
    }
    samples.sort();
    print('  ${(label ?? '$count shapes').padRight(28)} '
        'best ${samples.first.toStringAsFixed(2).padLeft(6)} ms   '
        'median ${samples[samples.length ~/ 2].toStringAsFixed(2).padLeft(6)} ms');
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
      await bench(tester, 40, label: 'the usual layout');
      await bench(tester, 40, panels: ['viewport'], label: 'viewport only');
      await bench(tester, 40, panels: ['console'], label: 'console only');
      await bench(tester, 40, panels: ['outliner'], label: 'outliner only');
      await bench(tester, 40, panels: ['inspector'], label: 'inspector only');
    }
  });
}
