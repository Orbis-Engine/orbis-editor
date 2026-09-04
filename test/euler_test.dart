import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  // Reparenting rewrites an object's local transform so it does not jump, and
  // that means turning a rotation matrix back into the degrees the inspector
  // shows. Getting the convention wrong is silent: the object lands somewhere
  // plausible and only looks wrong once it is animated.
  test('degrees survive a trip through a rotation and back', () {
    final random = math.Random(7);

    for (var i = 0; i < 200; i++) {
      // Kept off the poles, where two of the three angles are the same axis
      // and no extraction can recover the pair that went in.
      final input = Vector3(
        random.nextDouble() * 340 - 170,
        random.nextDouble() * 160 - 80,
        random.nextDouble() * 340 - 170,
      );

      final object = SceneObject(
        id: 'a',
        name: 'A',
        kind: ObjectKind.mesh,
        rotation: input,
      );
      final recovered = eulerDegreesOf(object.localTransform);

      // Compared as rotations rather than as numbers: a different triple can
      // describe the same orientation, and that is not an error.
      final wanted = SceneObject(
        id: 'b', name: 'B', kind: ObjectKind.mesh, rotation: input,
      ).localTransform.getRotation();
      final got = SceneObject(
        id: 'c', name: 'C', kind: ObjectKind.mesh, rotation: recovered,
      ).localTransform.getRotation();

      for (final probe in [
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        Vector3(0, 0, 1),
      ]) {
        final a = wanted.transformed(probe.clone());
        final b = got.transformed(probe.clone());
        expect(
          (a - b).length,
          lessThan(1e-6),
          reason: 'input $input came back as $recovered',
        );
      }
    }
  });
}
