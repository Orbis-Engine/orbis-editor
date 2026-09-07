// What one editor frame costs on the CPU, for the parts that changed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/geometry_store.dart';
import 'package:orbis_editor/src/editor/boundary.dart';
import 'package:orbis_editor/src/editor/grid.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/snapping.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// What a piece of per-frame work costs, in milliseconds.
///
/// A benchmark rather than an assertion. The numbers depend on the machine,
/// so nothing here fails on them — what it is for is answering "where did the
/// frame go" with a measurement instead of a guess, and having the answer in
/// the repository next to the thing it is about.
// ignore_for_file: avoid_print

double timed(String what, int times, void Function() run) {
  run();
  final watch = Stopwatch()..start();
  for (var i = 0; i < times; i++) {
    run();
  }
  watch.stop();
  final each = watch.elapsedMicroseconds / times / 1000;
  print('  ${what.padRight(46)} ${each.toStringAsFixed(3)} ms');
  return each;
}

void main() {
  test('what one frame costs', () {
    // Printed, not asserted: see above.
  final scene = EditorScene([
    for (var i = 0; i < 40; i++)
      SceneObject(
        id: 'o$i',
        name: 'o$i',
        kind: ObjectKind.shape,
        position: Vector3(i * 2.0, 0, 0),
        shape: Shape.of(ShapeKind.stairs),
      ),
  ]);
  final selected = scene.objects.take(4).toList();

  print('One frame, forty stairs, four of them selected:');

  timed('the outline, cached', 200, () {
    for (final object in selected) {
      object.boundaryEdges.length;
    }
  });

  timed('the outline, rebuilt every frame as it was', 200, () {
    for (final object in selected) {
      final mesh = object.shape!.build();
      Boundary().meshFrom(mesh)!.allEdges.length;
    }
  });

  timed('the whole scene, no grid', 200, () {
    scene.toRenderScene(
      OrbisCamera(position: Vector3(0, 5, 10), target: Vector3.zero()),
    );
  });

  final grid = GridPlan(
    mesh: '/tmp/grid.glb',
    texture: '/tmp/grid.png',
    centre: Vector3.zero(),
    extent: 50,
    step: 0.5,
  );
  timed('the whole scene, with the grid', 200, () {
    scene.toRenderScene(
      OrbisCamera(position: Vector3(0, 5, 10), target: Vector3.zero()),
      grid: grid,
    );
  });

  timed('packing it for the channel, no grid', 200, () {
    scene
        .toRenderScene(
          OrbisCamera(position: Vector3(0, 5, 10), target: Vector3.zero()),
        )
        .toMessage(0);
  });

  timed('packing it for the channel, with the grid', 200, () {
    scene
        .toRenderScene(
          OrbisCamera(position: Vector3(0, 5, 10), target: Vector3.zero()),
          grid: grid,
        )
        .toMessage(0);
  });

  timed('placing the grid', 200, () {
    GridStore('/tmp').planFor(Snapping(), Vector3(3.3, 0, -7.1));
  });

  // What every frame of a drag runs, because every frame of a drag is a
  // change and every change asks whether any geometry has to be written.
  final root = Directory.systemTemp.createTempSync('orbis_cost');
  addTearDown(() => root.deleteSync(recursive: true));
  final store = GeometryStore(root.path);
  for (final object in scene.objects) {
    store.pathFor(object);
  }

  timed('checking every shape is written, unchanged', 200, () {
    for (final object in scene.objects) {
      store.pathFor(object);
    }
  });

  // The two things that used to be in there, measured on their own so the
  // difference is a number rather than a claim.
  timed('  ...asking the filesystem, as it did', 200, () {
    for (final object in scene.objects) {
      File('${root.path}/.orbis/geometry/${object.id}.glb').existsSync();
    }
  });

  timed('  ...walking every vertex, as it did', 200, () {
    for (final object in scene.objects) {
      final mesh = object.currentMesh!;
      var total = 0.0;
      for (final at in mesh.positions) {
        total += at.x + at.y * 3 + at.z * 7;
      }
      var corners = 0;
      for (final face in mesh.faces) {
        corners += face.vertices.length;
      }
      '${mesh.positions.length}/$corners/${total.toStringAsFixed(4)}';
    }
  });
  });
}
