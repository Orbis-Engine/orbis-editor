import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/mesh_edit.dart';
import 'package:orbis_editor/src/editor/mesh_tools.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  MeshAction named(String label) =>
      MeshTools.all.firstWhere((action) => action.label == label);

  /// The index of the face pointing up.
  int topOf(Mesh mesh) =>
      mesh.faces.indexWhere((f) => mesh.normalOf(f).y > 0.9);

  group('what is offered', () {
    test('nothing that needs a selection, when there is none', () {
      final offered = MeshTools.availableIn(
        ElementMode.face,
        ElementSelection(),
      );

      expect(offered.every((action) => action.modes.isEmpty), isTrue);
    });

    test('the face actions, with a face selected', () {
      final offered = MeshTools.availableIn(
        ElementMode.face,
        ElementSelection(faces: {0}),
      );

      expect([for (final a in offered) a.label],
          containsAll(['Extrude', 'Inset', 'Subdivide', 'Delete']));
    });

    test('nothing that needs two, when only one is selected', () {
      final offered = MeshTools.availableIn(
        ElementMode.face,
        ElementSelection(faces: {0}),
      );

      expect([for (final a in offered) a.label], isNot(contains('Merge')));
    });

    test('the object actions are always offered', () {
      final offered = MeshTools.availableIn(null, ElementSelection());
      expect([for (final a in offered) a.label],
          containsAll(['Conform normals', 'Flip all normals', 'Weld all']));
    });

    test('an edge action is not offered in face mode', () {
      final offered = MeshTools.availableIn(
        ElementMode.face,
        ElementSelection(faces: {0, 1}),
      );
      expect([for (final a in offered) a.label], isNot(contains('Bridge')));
    });
  });

  group('running one', () {
    test('extruding moves the face and selects it again', () {
      final mesh = cube();
      final selection = ElementSelection(faces: {topOf(mesh)});

      final after = named('Extrude').run(mesh, selection, 2);

      expect(mesh.bounds.max.y, closeTo(3, 1e-9));
      // Selected again, because somebody who extrudes once usually extrudes
      // twice.
      expect(after.faces, hasLength(1));
      expect(mesh.centreOf(after.facesIn(mesh).single).y, closeTo(3, 1e-9));
    });

    test('deleting leaves nothing selected', () {
      final mesh = cube();
      final after = named('Delete')
          .run(mesh, ElementSelection(faces: {topOf(mesh)}), 0);

      expect(mesh.faces, hasLength(5));
      expect(after.isEmpty, isTrue);
    });

    test('subdividing selects the pieces it made', () {
      final mesh = cube();
      final after = named('Subdivide')
          .run(mesh, ElementSelection(faces: {topOf(mesh)}), 0);

      expect(after.faces, hasLength(4));
      expect(mesh.faces, hasLength(9));
    });

    test('growing without an angle takes the neighbours', () {
      final mesh = cube();
      final after =
          named('Grow').run(mesh, ElementSelection(faces: {topOf(mesh)}), 180);

      expect(after.faces, hasLength(5));
    });

    test('growing within an angle stops at the corner', () {
      final mesh = cube();
      final after =
          named('Grow').run(mesh, ElementSelection(faces: {topOf(mesh)}), 5);

      expect(after.faces, hasLength(1));
    });

    test('flipping normals turns just the selected face', () {
      final mesh = cube();
      final top = topOf(mesh);
      named('Flip normals').run(mesh, ElementSelection(faces: {top}), 0);

      expect(mesh.normalOf(mesh.faces[top]).y, closeTo(-1, 1e-9));
    });

    test('conforming turns it back', () {
      final mesh = cube();
      mesh.flipFaces([mesh.faces[topOf(mesh)]]);

      named('Conform normals').run(mesh, ElementSelection(), 0);

      expect(mesh.normalOf(mesh.faces[topOf(mesh)]).y, closeTo(1, 1e-9));
    });

    test('an edge loop selects the ring round a cylinder', () {
      final mesh =
          Shape.of(ShapeKind.cylinder).copyWith(sides: 8, capped: false).build();
      final face = mesh.faces.first;
      final selection =
          ElementSelection(edges: {edgeOf(face.vertices[0], face.vertices[1])});

      final after = named('Edge ring').run(mesh, selection, 0);

      expect(after.edges.length, greaterThanOrEqualTo(2));
    });

    test('filling a hole closes what delete opened', () {
      final mesh = cube();
      named('Delete').run(mesh, ElementSelection(faces: {topOf(mesh)}), 0);

      final border = mesh.openEdges;
      final after = named('Fill hole').run(
        mesh,
        ElementSelection(edges: border),
        0,
      );

      expect(after.faces, hasLength(1));
      expect(mesh.openEdges, isEmpty);
    });

    test('every action leaves a mesh whose faces name real points', () {
      // The property that matters: an action that corrupts the mesh is one
      // that crashes the renderer two frames later, a long way from here.
      for (final action in MeshTools.all) {
        final mesh = Shape.of(ShapeKind.cube).build();
        final selection = ElementSelection(
          faces: {0, 1},
          edges: {
            edgeOf(mesh.faces[0].vertices[0], mesh.faces[0].vertices[1]),
            edgeOf(mesh.faces[1].vertices[0], mesh.faces[1].vertices[1]),
          },
          vertices: {0, 1, 2},
        );

        action.run(mesh, selection, action.amount?.value ?? 1);

        for (final face in mesh.faces) {
          for (final index in face.vertices) {
            expect(index, inInclusiveRange(0, mesh.positions.length - 1),
                reason: action.label);
          }
          expect(face.vertices.length, greaterThanOrEqualTo(3),
              reason: action.label);
        }
      }
    });

    test('and one that can be drawn', () {
      for (final action in MeshTools.all) {
        final mesh = Shape.of(ShapeKind.cube).build();
        action.run(
          mesh,
          ElementSelection(faces: {0}, vertices: {0, 1}, edges: {(0, 1)}),
          action.amount?.value ?? 1,
        );

        final tris = mesh.triangulate();
        for (final index in tris.indices) {
          expect(index, lessThan(tris.vertexCount), reason: action.label);
        }
      }
    });
  });
}
