import 'package:flutter/material.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

import 'mesh_edit.dart';

/// One thing somebody can do to geometry.
///
/// A description rather than a method call, so the same list draws the menu,
/// answers whether it can be pressed, and runs. Three copies of "which mode is
/// Extrude available in" is two copies too many.
class MeshAction {
  const MeshAction({
    required this.label,
    required this.icon,
    required this.modes,
    required this.run,
    this.needs = 1,
    this.hint = '',
    this.amount,
  });

  final String label;
  final IconData icon;

  /// Which modes it appears in. Empty means the whole object.
  final Set<ElementMode> modes;

  /// How many elements it needs. Bridging needs two edges; extruding needs
  /// one face.
  final int needs;

  /// What it says on the tooltip.
  final String hint;

  /// The number it takes, if it takes one — a distance, a count.
  final ({String label, double value, double min, double max})? amount;

  /// Does it, and says what should be selected afterwards.
  ///
  /// The mesh is changed in place and handed back, because a mesh is a few
  /// thousand doubles and copying one is nothing next to a frame — while
  /// describing an extrude as a diff is more code than the extrude.
  final ElementSelection Function(
    Mesh mesh,
    ElementSelection selection,
    double amount,
  ) run;

  bool availableIn(ElementMode? mode, ElementSelection selection) {
    if (modes.isEmpty) return true;
    if (mode == null || !modes.contains(mode)) return false;
    return selection.countIn(mode) >= needs;
  }
}

/// Everything the editor can do to a mesh.
///
/// The set ProBuilder has, less the ones that need something this engine does
/// not have yet — there are no colliders to set, no submeshes to detach to,
/// and no UV editor for the ones that are really about texture coordinates.
/// What is here is the geometry.
abstract final class MeshTools {
  /// Faces, by position, for the selection.
  static Set<int> _positionsOf(Mesh mesh, Iterable<Face> faces) {
    final wanted = faces.toSet();
    return {
      for (var i = 0; i < mesh.faces.length; i++)
        if (wanted.contains(mesh.faces[i])) i,
    };
  }

  static final List<MeshAction> all = [
    // ---- faces ----
    MeshAction(
      label: 'Extrude',
      icon: Icons.open_in_full,
      modes: {ElementMode.face},
      hint: 'Pulls the face out and puts a wall on every edge of it. The move '
          'everything from a doorway to a chimney is made of.',
      amount: (label: 'Distance', value: 0.5, min: -4, max: 4),
      run: (mesh, selection, amount) {
        final after = mesh.extrude(selection.facesIn(mesh), amount);
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Inset',
      icon: Icons.filter_frames,
      modes: {ElementMode.face},
      hint: 'Shrinks the face towards its middle, leaving a border. Inset '
          'then extrude inwards is a window.',
      amount: (label: 'Distance', value: 0.15, min: 0.01, max: 2),
      run: (mesh, selection, amount) {
        final after = mesh.inset(selection.facesIn(mesh), amount);
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Bevel',
      icon: Icons.rounded_corner,
      modes: {ElementMode.face, ElementMode.edge},
      hint: 'Cuts the corner off, leaving a face where the edge was.',
      amount: (label: 'Distance', value: 0.1, min: 0.01, max: 2),
      run: (mesh, selection, amount) {
        final edges = selection.edges.isNotEmpty
            ? selection.edges
            : mesh.edgesOf(selection.facesIn(mesh));
        final after = mesh.bevel(edges, amount);
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Subdivide',
      icon: Icons.grid_4x4,
      modes: {ElementMode.face},
      hint: 'Cuts each face into four, so there is something to pull on.',
      run: (mesh, selection, _) {
        final after = mesh.subdivide(selection.facesIn(mesh));
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Delete',
      icon: Icons.delete_outline,
      modes: {ElementMode.face},
      hint: 'Takes the face out, leaving a hole.',
      run: (mesh, selection, _) {
        mesh.deleteFaces(selection.facesIn(mesh));
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Flip normals',
      icon: Icons.flip,
      modes: {ElementMode.face},
      hint: 'Turns the face the other way, so it is visible from the side it '
          'was not.',
      run: (mesh, selection, _) {
        final faces = selection.facesIn(mesh);
        mesh.flipFaces(faces);
        return ElementSelection(faces: _positionsOf(mesh, faces));
      },
    ),
    MeshAction(
      label: 'Merge',
      icon: Icons.join_full,
      modes: {ElementMode.face},
      needs: 2,
      hint: 'Joins the faces into one and drops the edges between them.',
      run: (mesh, selection, _) {
        final made = mesh.mergeFaces(selection.facesIn(mesh));
        return made == null
            ? selection
            : ElementSelection(faces: _positionsOf(mesh, [made]));
      },
    ),
    MeshAction(
      label: 'Triangulate',
      icon: Icons.change_history,
      modes: {ElementMode.face},
      hint: 'Cuts the faces down to triangles.',
      run: (mesh, selection, _) {
        final after = mesh.triangulateFaces(selection.facesIn(mesh));
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Grow',
      icon: Icons.zoom_out_map,
      modes: {ElementMode.face},
      hint: 'Takes in the neighbours. The angle keeps it on the flat rather '
          'than round a corner.',
      amount: (label: 'Within', value: 180, min: 0, max: 180),
      run: (mesh, selection, amount) {
        final after = mesh.grow(
          selection.facesIn(mesh),
          withinAngle: amount >= 179.5 ? null : amount,
        );
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Shrink',
      icon: Icons.zoom_in_map,
      modes: {ElementMode.face},
      needs: 2,
      hint: 'Drops the faces round the edge of the selection.',
      run: (mesh, selection, _) {
        final after = mesh.shrink(selection.facesIn(mesh));
        return ElementSelection(faces: _positionsOf(mesh, after));
      },
    ),
    MeshAction(
      label: 'Loop',
      icon: Icons.all_inclusive,
      modes: {ElementMode.face},
      hint: 'Selects the ring of faces this one runs round. Quads only.',
      run: (mesh, selection, _) {
        final faces = selection.facesIn(mesh);
        if (faces.isEmpty) return selection;
        final loop = <Face>{};
        for (final face in faces) {
          loop.addAll(mesh.faceLoop(face));
        }
        return ElementSelection(faces: _positionsOf(mesh, loop));
      },
    ),

    // ---- edges ----
    MeshAction(
      label: 'Bridge',
      icon: Icons.compare_arrows,
      modes: {ElementMode.edge},
      needs: 2,
      hint: 'Puts a face between two open edges, joining two pieces.',
      run: (mesh, selection, _) {
        final edges = selection.edges.toList();
        // Guarded here as well as by `needs`. That decides what the menu
        // offers; this is what happens when something calls it anyway — a
        // shortcut, a script, a test — and a range error two frames from here
        // is a worse answer than doing nothing.
        if (edges.length < 2) return selection;
        final made = mesh.bridge(edges[0], edges[1]);
        return made == null
            ? selection
            : ElementSelection(faces: _positionsOf(mesh, [made]));
      },
    ),
    MeshAction(
      label: 'Subdivide edge',
      icon: Icons.linear_scale,
      modes: {ElementMode.edge},
      hint: 'Cuts the edge into pieces, and puts the new points into every '
          'face using it.',
      amount: (label: 'Cuts', value: 1, min: 1, max: 8),
      run: (mesh, selection, amount) {
        final made = mesh.subdivideEdges(
          selection.edges,
          into: amount.round(),
        );
        return ElementSelection(vertices: made.toSet());
      },
    ),
    MeshAction(
      label: 'Edge loop',
      icon: Icons.rotate_right,
      modes: {ElementMode.edge},
      hint: 'Selects the loop running through this edge. Quads only.',
      run: (mesh, selection, _) {
        final loop = <MeshEdge>{};
        for (final edge in selection.edges) {
          loop.addAll(mesh.edgeLoop(edge));
        }
        return ElementSelection(edges: loop);
      },
    ),
    MeshAction(
      label: 'Edge ring',
      icon: Icons.swap_horiz,
      modes: {ElementMode.edge},
      hint: 'Selects the ring of edges parallel to this one. Quads only.',
      run: (mesh, selection, _) {
        final ring = <MeshEdge>{};
        for (final edge in selection.edges) {
          ring.addAll(mesh.edgeRing(edge));
        }
        return ElementSelection(edges: ring);
      },
    ),

    // ---- vertices ----
    MeshAction(
      label: 'Weld',
      icon: Icons.compress,
      modes: {ElementMode.vertex},
      needs: 2,
      hint: 'Joins points that are already in the same place.',
      amount: (label: 'Within', value: 0.01, min: 0.0001, max: 1),
      run: (mesh, selection, amount) {
        mesh.weld(within: amount);
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Collapse',
      icon: Icons.center_focus_strong,
      modes: {ElementMode.vertex},
      needs: 2,
      hint: 'Pulls the points together into one, however far apart they are.',
      run: (mesh, selection, _) {
        mesh.collapse(selection.vertices);
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Split',
      icon: Icons.call_split,
      modes: {ElementMode.vertex},
      hint: 'Gives each face its own copy of the point, so they come apart.',
      run: (mesh, selection, _) {
        mesh.split(selection.vertices);
        return selection;
      },
    ),
    MeshAction(
      label: 'Fill hole',
      icon: Icons.format_color_fill,
      modes: {ElementMode.vertex, ElementMode.edge},
      hint: 'Puts a face over the hole these are on the edge of.',
      run: (mesh, selection, _) {
        final around = selection.vertices.isNotEmpty
            ? selection.vertices
            : {for (final edge in selection.edges) ...[edge.$1, edge.$2]};
        final made = mesh.fillHole(around);
        return ElementSelection(faces: _positionsOf(mesh, made));
      },
    ),

    // ---- the whole object ----
    MeshAction(
      label: 'Subdivide all',
      icon: Icons.grid_on,
      modes: const {},
      hint: 'Cuts every face into four.',
      run: (mesh, selection, _) {
        mesh.subdivide([...mesh.faces]);
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Conform normals',
      icon: Icons.compass_calibration,
      modes: const {},
      hint: 'Turns the odd face back the way the rest of them point. What '
          'fixes a shape that came in partly inside out.',
      run: (mesh, selection, _) {
        mesh.conformNormals();
        return selection;
      },
    ),
    MeshAction(
      label: 'Flip all normals',
      icon: Icons.swap_vert,
      modes: const {},
      hint: 'Turns the whole shape inside out, which is how a box becomes a '
          'room.',
      run: (mesh, selection, _) {
        mesh.flip();
        return selection;
      },
    ),
    MeshAction(
      label: 'Weld all',
      icon: Icons.merge_type,
      modes: const {},
      hint: 'Joins every pair of points in the same place, so pieces that '
          'touch become one solid.',
      amount: (label: 'Within', value: 0.001, min: 0.0001, max: 1),
      run: (mesh, selection, amount) {
        mesh.weld(within: amount);
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Triangulate all',
      icon: Icons.details,
      modes: const {},
      hint: 'Cuts every face down to triangles.',
      run: (mesh, selection, _) {
        mesh.triangulateFaces([...mesh.faces]);
        return ElementSelection();
      },
    ),
    MeshAction(
      label: 'Centre pivot',
      icon: Icons.filter_center_focus,
      modes: const {},
      hint: 'Moves the middle of the object to where it turns and scales '
          'around.',
      run: (mesh, selection, _) {
        mesh.centrePivotOn(const []);
        return selection;
      },
    ),
  ];

  /// The ones that can be pressed right now.
  static List<MeshAction> availableIn(
    ElementMode? mode,
    ElementSelection selection,
  ) =>
      [
        for (final action in all)
          if (action.availableIn(mode, selection)) action,
      ];
}
