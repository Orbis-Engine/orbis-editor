import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/grid.dart';
import 'package:orbis_editor/src/editor/snapping.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  late Directory root;
  late GridStore grid;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    root = Directory.systemTemp.createTempSync('orbis_grid');
    grid = GridStore(root.path);
    await grid.prepare();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the quad and the lines are written once', () {
    expect(File('${root.path}/.orbis/grid.glb').existsSync(), isTrue);
    expect(File('${root.path}/.orbis/grid.png').existsSync(), isTrue);
  });

  test('there is no grid until it has been made', () async {
    final fresh = GridStore(root.path);
    expect(fresh.planFor(Snapping(), Vector3.zero()), isNull,
        reason: 'a frame or two without one at startup beats blocking');
    await fresh.prepare();
    expect(fresh.planFor(Snapping(), Vector3.zero()), isNotNull);
  });

  test('turning snapping off turns the grid off', () {
    expect(grid.planFor(Snapping(on: false), Vector3.zero()), isNull);
    expect(grid.planFor(Snapping(), Vector3.zero()), isNotNull);
  });

  test('it is always a hundred squares, whatever the step', () {
    for (final step in Snapping.steps) {
      final plan = grid.planFor(Snapping(step: step), Vector3.zero())!;
      expect(plan.extent / plan.step, closeTo(GridPlan.across, 1e-9),
          reason: 'so it says how big a snap is, not how big the world is');
    }
  });

  test('it follows the camera in whole squares', () {
    final plan = grid.planFor(Snapping(step: 0.5), Vector3(3.3, 9, -7.1))!;
    // Snapped, so it slides under the camera rather than appearing to move.
    expect(plan.centre.x % 0.5, closeTo(0, 1e-9));
    expect(plan.centre.z % 0.5, closeTo(0, 1e-9));
    expect(plan.centre.x, closeTo(3.5, 1e-9));
    expect(plan.centre.y, 0, reason: 'a grid is the ground, not a height');
  });

  test('the quad is scaled to the whole extent and sits just under nought',
      () {
    final plan = grid.planFor(Snapping(step: 1), Vector3.zero())!;
    final scale = plan.transform.getMaxScaleOnAxis();
    expect(scale, closeTo(plan.extent, 1e-6));
    // A hair below, so anything built on the ground plane wins the depth
    // test rather than flickering against it.
    expect(plan.transform.getTranslation().y, lessThan(0));
    expect(plan.transform.getTranslation().y, greaterThan(-0.01));
  });

  test('it is drawn as a hint rather than as a thing in the world', () {
    final plan = grid.planFor(Snapping(), Vector3.zero())!;
    final object = plan.object;
    final material = plan.material;

    expect(object.castShadows, isFalse);
    expect(object.receiveShadows, isFalse);
    // Blended, unlit and writing no depth: hidden by what is in front of it,
    // and hiding nothing itself.
    expect(material.depthWrite, isFalse);
    expect(material.baseColour.w, lessThan(1));
    expect(material.baseColourMap, isNotNull);
    // Ten across the image and ten images across the quad.
    expect(material.tiling.x * 10, closeTo(GridPlan.across, 1e-9));
  });

  test('its key is nowhere near an object key', () {
    // The grid is not an object and never will be one, so it can never
    // collide with something a scene put in the list.
    expect(GridPlan.renderKey, lessThan(0));
  });

  test('a project folder it cannot write to is a project with no grid',
      () async {
    final missing = GridStore('/definitely/not/a/place');
    await missing.prepare();
    expect(missing.planFor(Snapping(), Vector3.zero()), isNull);
  });
}
