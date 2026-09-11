import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide Clipboard;
import 'package:flutter/services.dart' as services;
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

import '../launcher/project.dart';
import '../platform/command_shortcuts.dart';
import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'asset_browser.dart';
import 'assets.dart';
import 'clipboard.dart';
import 'code_editor.dart';
import 'boundary.dart';
import 'commands.dart';
import 'console.dart';
import 'console_panel.dart';
import 'data_panel.dart';
import 'data_store.dart';
import 'dock.dart';
import 'grid.dart';
import 'drawing.dart';
import 'frame_rate.dart';
import 'dock_view.dart';
import 'game_view.dart';
import 'geometry_store.dart';
import 'script_build.dart';
import 'ui_editor.dart';
import 'history.dart';
import 'inspector.dart';
import 'mesh_edit.dart';
import 'mesh_panel.dart';
import 'model_bounds.dart';
import 'modelling_panel.dart';
import 'mesh_tools.dart';
import 'outliner.dart';
import 'prefab.dart';
import 'scene.dart';
import 'snapping.dart';
import 'surface.dart';
import 'uv_panel.dart';
import 'scene_document.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:orbis_ui/orbis_ui.dart';

import 'viewport.dart';
import 'workspace.dart';

/// The editor, once a project is open.
///
/// Regions rather than free-floating windows: a fixed rail, an outliner, the
/// viewport, an inspector and a status bar. Docking comes later, and it comes
/// more easily to a layout that already knows what its regions are.
class EditorShell extends StatefulWidget {
  const EditorShell({
    super.key,
    required this.project,
    required this.onClose,
  });

  final Project project;

  /// Back to the launcher.
  final VoidCallback onClose;

  @override
  State<EditorShell> createState() => _EditorShellState();
}

class _EditorShellState extends State<EditorShell> {
  late final Workspace _workspace = Workspace(widget.project.directory);
  late final History _history = History(_workspace);
  late final AssetTree _assets = AssetTree(widget.project.directory);

  late final DataStore _data = DataStore(widget.project.directory);

  /// Geometry built here, written out for the renderer to load.
  late final GeometryStore _geometry = GeometryStore(widget.project.directory);

  // ---- editing geometry ----

  /// Whether the whole object is selected, or its parts.
  EditContext _context = EditContext.object;

  ElementMode _elementMode = ElementMode.face;

  ElementSelection _elements = ElementSelection();

  /// How much the next action does, per action.
  ///
  /// Kept between presses: somebody extruding a corridor extrudes it in equal
  /// steps, and a distance that reset to a half every time would be a number
  /// they retyped every time.
  final Map<String, double> _amounts = {};

  /// The object whose parts are being edited, or null.
  ///
  /// Only a shape, and only while the context says so. Editing the parts of a
  /// referenced glTF model would mean editing a file somebody else's
  /// application also owns.
  ({SceneObject object, Mesh mesh, Matrix4 transform})? get _editing {
    if (_context != EditContext.element) return null;

    final open = _workspace.sceneHolding(_primary ?? '');
    final scene = open?.scene;
    final object = _primary == null ? null : scene?[_primary!];
    if (object == null || object.kind != ObjectKind.shape) return null;

    final mesh = object.currentMesh;
    if (mesh == null || mesh.isEmpty) return null;

    return (
      object: object,
      mesh: mesh,
      transform: scene!.worldOf(object.id),
    );
  }

  /// The selected shape, whichever context is on.
  ///
  /// Separate from [_editing], which is only about element editing. Conforming
  /// normals or welding a whole shape is something somebody does to the object
  /// without going into it, and requiring them to would be a mode for no
  /// reason.
  ({SceneObject object, Mesh mesh, SceneEntry entry})? get _shapeSelected {
    final open = _workspace.sceneHolding(_primary ?? '');
    final object = _primary == null ? null : open?.scene?[_primary!];
    if (object == null || object.kind != ObjectKind.shape) return null;

    final mesh = object.currentMesh;
    if (mesh == null || mesh.isEmpty) return null;
    return (object: object, mesh: mesh, entry: open!);
  }

  /// Whether the selection could be edited part by part.
  bool get _canEditParts => _shapeSelected != null;

  void _setContext(EditContext context) {
    if (context == EditContext.element && !_canEditParts) return;
    setState(() {
      _context = context;
      if (context == EditContext.object) _elements.clear();
    });
  }

  /// Adds what was clicked to the selection, or replaces it.
  void _pickElement(Object? what, {required bool add}) {
    setState(() {
      if (!add) _elements.clear();
      if (what == null) return;

      switch (what) {
        case final int index when _elementMode == ElementMode.vertex:
          _toggle(_elements.vertices, index);
        case final int index when _elementMode == ElementMode.face:
          _toggle(_elements.faces, index);
        case final MeshEdge edge:
          _toggle(_elements.edges, edge);
        default:
          break;
      }
    });
  }

  static void _toggle<T>(Set<T> set, T value) {
    if (!set.remove(value)) set.add(value);
  }

  /// Does one of the mesh actions and puts the result on the undo stack.
  ///
  /// The whole mesh per step. An extrude adds vertices and faces and moves
  /// others, and describing that as a diff is more code than the extrude —
  /// while a mesh is a few thousand doubles, which is nothing next to a frame.
  void _runMeshAction(MeshAction action) {
    // The selected shape, not the one being element-edited: an object action
    // works without going into the geometry first.
    final chosen = _shapeSelected;
    if (chosen == null) return;

    final next = chosen.mesh.copy();
    final after = action.run(
      next,
      _elements,
      _amounts[action.label] ?? action.amount?.value ?? 1,
    );

    _run(SetGeometry(
      sceneId: chosen.entry.id,
      id: chosen.object.id,
      name: chosen.object.name,
      to: next,
      what: action.label,
    ));

    setState(() => _elements = after);
    _geometry.forget(chosen.object.id);
    _refreshGeometry();
  }

  /// What a drag lands on.
  ///
  /// One for the whole editor rather than one a viewport, so four views of a
  /// scene agree about the grid — and a view setting, not a document one: it
  /// is not saved and it is not undone.
  final Snapping _snapping = Snapping();

  /// Everything somebody does to geometry, in one place.
  ///
  /// Built here rather than in the inspector because it is a panel of its own
  /// now: it stays put when the selection changes, and says what it is
  /// waiting for when there is nothing to work on.
  Widget _modellingTools() {
    final chosen = _shapeSelected;
    return ModellingPanel(
      shape: chosen?.object.shape,
      geometry: chosen?.object.geometry,
      context_: _context,
      mode: _elementMode,
      selection: _elements,
      amounts: _amounts,
      onContext: _setContext,
      onMode: (mode) => setState(() => _elementMode = mode),
      onAction: _runMeshAction,
      onAmount: (action, amount) =>
          setState(() => _amounts[action] = amount),
      seeThrough: _seeThrough,
      onSeeThrough: (value) => setState(() => _seeThrough = value),
      surfaces: chosen?.object.surfaces ?? const [],
      onSurfaces: (surfaces, {required live}) {
        if (chosen == null) return;
        _setSurfaces(chosen.object, surfaces, live: live);
      },
      onPaint: _paintFaces,
      format: _format,
      onFormat: (one) => setState(() => _format = one),
      onExport: () {
        if (chosen != null) _exportShape(chosen.object);
      },
      tool: _drawing.tool,
      onTool: _useTool,
      drawing: _drawing,
      snapping: _snapping,
      onSnapping: (_) => setState(() {}),
    );
  }

  /// What a drag in the coordinate view does.
  UvGesture _uvGesture = UvGesture.move;

  /// The coordinate view, and the rule's numbers under it.
  ///
  /// One panel rather than a section of the inspector: a texture is looked at
  /// while the shape is being turned in the viewport, and something that
  /// takes half a sidebar wants to be somewhere somebody chose to put it.
  Widget _uvEditor() {
    final chosen = _shapeSelected;
    final mesh = chosen?.mesh;
    final faces = mesh == null ? const <Face>[] : _elements.facesIn(mesh);
    // Only meaningful for faces: a vertex has as many coordinates as it has
    // faces, and asking which one somebody means is a question with no good
    // answer.
    final wrongMode = _context == EditContext.element &&
        _elementMode != ElementMode.face;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wrongMode)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.xs),
            child: Text(
              'Texture coordinates belong to faces. Press G until Faces is on.',
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          ),
        UvPanel(
          mesh: mesh,
          selection: _elementMode == ElementMode.face
              ? _elements
              : nothingSelected,
          gesture: _uvGesture,
          onGesture: (one) => setState(() => _uvGesture = one),
          onNudge: (by) => _editUvs('Move texture', (mesh, faces) {
            mesh.nudgeUvs(faces, by);
          }),
          onScale: (by) => _editUvs('Scale texture', (mesh, faces) {
            mesh.scaleUvs(faces, by);
          }),
          onTurn: (degrees) => _editUvs('Turn texture', (mesh, faces) {
            mesh.turnUvs(faces, degrees);
          }),
          onDone: () => _gesture = null,
          onAction: _runUvAction,
        ),
        if (faces.length == 1 && !faces.single.uv.isManual) ...[
          const SizedBox(height: Space.sm),
          UvRuleControls(
            uv: faces.single.uv,
            onChanged: (next, {required live}) => _editUvs(
              'Texture',
              (mesh, faces) {
                for (final face in faces) {
                  face.uv = next;
                }
              },
              live: live,
            ),
            onDone: () => _gesture = null,
          ),
        ],
      ],
    );
  }

  /// Runs one of the coordinate buttons.
  void _runUvAction(UvAction action) {
    _editUvs(action.label, (mesh, faces) {
      switch (action) {
        case UvAction.freeze:
          mesh.freezeUvs(faces);
        case UvAction.release:
          mesh.releaseUvs(faces);
        case UvAction.fit:
          mesh.fitUvs(faces);
        case UvAction.planar:
          mesh.projectPlanar(faces);
        case UvAction.box:
          mesh.projectBox(faces);
      }
    }, live: false);
  }

  /// One coordinate edit, on a copy, through the undo stack.
  ///
  /// [live] folds a run of them into one step, which is what a drag or a
  /// slider needs and what a button must not have — two presses of Fit are
  /// two things somebody did.
  void _editUvs(
    String what,
    void Function(Mesh mesh, List<Face> faces) change, {
    bool live = true,
  }) {
    final chosen = _shapeSelected;
    if (chosen == null) return;

    final next = chosen.mesh.copy();
    final faces = _elements.facesIn(next);
    if (faces.isEmpty) return;

    change(next, faces);

    if (!live) {
      _gesture = null;
    } else {
      _gesture ??= Object();
    }

    _run(SetGeometry(
      sceneId: chosen.entry.id,
      id: chosen.object.id,
      name: chosen.object.name,
      to: next,
      what: what,
      gesture: live ? _gesture : null,
    ));
    if (!live) _gesture = null;

    _geometry.forget(chosen.object.id);
    _geometry.pathFor(chosen.object);
    setState(() {});
  }

  /// Changes a drawn shape's height, or turns it over.
  void _setOutline(SceneObject object, PolyShape next, {required bool live}) {
    final entry = _workspace.sceneHolding(object.id);
    if (entry == null) return;
    if (!live) _gesture = Object();

    _run(SetOutline(
      sceneId: entry.id,
      id: object.id,
      name: object.name,
      to: next,
      gesture: live ? _gesture : null,
    ));
    if (!live) _gesture = null;
    _geometry.forget(object.id);
    _geometry.pathFor(object);
    setState(() {});
  }

  /// The arrow keys, as shortcuts.
  ///
  /// Built rather than written out: four directions times three modifiers is
  /// twelve lines that say the same thing, and one of them would be wrong.
  static final Map<ShortcutActivator, Intent> _nudges = {
    for (final (key, axis, sign) in [
      (LogicalKeyboardKey.arrowLeft, _x, -1),
      (LogicalKeyboardKey.arrowRight, _x, 1),
      (LogicalKeyboardKey.arrowUp, _z, -1),
      (LogicalKeyboardKey.arrowDown, _z, 1),
    ]) ...{
      SingleActivator(key): _NudgeIntent(axis, sign),
      SingleActivator(key, alt: true): _NudgeIntent(axis, sign * 10),
    },
    // Up and down are the exception: there is no arrow for them, so shift
    // turns the near-and-far pair into a high-and-low one.
    SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
        _NudgeIntent(_y, 1),
    SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
        _NudgeIntent(_y, -1),
    SingleActivator(LogicalKeyboardKey.arrowUp, shift: true, alt: true):
        _NudgeIntent(_y, 10),
    SingleActivator(LogicalKeyboardKey.arrowDown, shift: true, alt: true):
        _NudgeIntent(_y, -10),
  };

  static final Vector3 _x = Vector3(1, 0, 0);
  static final Vector3 _y = Vector3(0, 1, 0);
  static final Vector3 _z = Vector3(0, 0, 1);

  /// Moves the selection a whole number of squares.
  ///
  /// One press, one step on the undo stack — unlike a drag, which is one step
  /// however many frames it took. Pressing an arrow twice is two things
  /// somebody did.
  void _nudge(Vector3 axis, int squares) {
    final scene = _working?.scene;
    final entry = _working;
    if (scene == null || entry == null) return;

    final ids = [
      for (final id in _selected)
        if (scene[id] != null && scene[id]!.kind != ObjectKind.scene) id,
    ];
    if (ids.isEmpty) return;

    // The grid's step even when the grid is off: an arrow key is a request
    // for a definite amount, and the definite amount on offer is a square.
    final by = axis * (_snapping.step * squares);
    final changes = <String, ({Vector3 from, Vector3 to})>{};
    for (final id in ids) {
      final object = scene[id]!;
      final parentId = object.parentId;
      final local = parentId == null || !scene.contains(parentId)
          ? by
          : Matrix4.inverted(scene.worldOf(parentId)).rotated3(by.clone());
      changes[id] = (
        from: object.position.clone(),
        to: object.position + local,
      );
    }

    _run(TransformMany(
      sceneId: entry.id,
      field: TransformField.position,
      what: ids.length == 1 ? scene[ids.first]!.name : '${ids.length} objects',
      changes: changes,
    ));
    // Sealed, so the next press is its own step rather than merging into
    // this one the way a drag's frames do.
    _history.seal();
  }

  /// Changes where an object begins and ends.
  void _setBoundary(SceneObject object, Boundary next, {required bool live}) {
    final entry = _workspace.sceneHolding(object.id);
    if (entry == null) return;
    if (!live) _gesture = Object();

    _run(SetBoundary(
      sceneId: entry.id,
      id: object.id,
      name: object.name,
      to: next,
      gesture: live ? _gesture : null,
    ));
    if (!live) _gesture = null;
    setState(() {});
  }

  /// How fast the editor is actually drawing.
  ///
  /// Listened to rather than read on every build, and it only speaks a couple
  /// of times a second — a status bar rebuilt sixty times a second to say how
  /// fast things are would be its own answer to the question.
  final FrameRate _frames = FrameRate();

  /// The grid, made once and then only placed.
  late final GridStore _grid = GridStore(widget.project.directory);

  /// How big each imported model says it is, read once a file.
  late final ModelBounds _models = ModelBounds(widget.project.directory);

  /// The outline or cut being drawn, if one is.
  ///
  /// One for the editor rather than one a viewport, so the same drawing shows
  /// in all four views and can be finished in a different one from the one it
  /// was started in.
  final Drawing _drawing = Drawing();

  /// Starts or stops a drawing tool.
  void _useTool(ViewportTool tool) {
    setState(() {
      if (_drawing.tool == tool) {
        _drawing.clear();
        return;
      }
      _drawing.start(tool);
      if (tool == ViewportTool.cut && _shapeSelected == null) {
        _drawing.clear();
        _say('Select a shape to cut first.', level: LogLevel.warning);
      }
    });
  }

  /// Puts down one point.
  void _drawPoint(Vector3 at, Vector3 origin, Vector3 normal, int? face) {
    setState(() {
      _drawing.planeAt(origin, normal, onFace: face);
      _drawing.add(at);
    });
  }

  /// Finishes whatever is being drawn.
  void _finishDrawing() {
    if (!_drawing.canFinish) {
      _say(
        _drawing.tool == ViewportTool.cut
            ? 'A cut needs two points, both on the edge of a face.'
            : 'A shape needs three points.',
        level: LogLevel.warning,
      );
      return;
    }
    switch (_drawing.tool) {
      case ViewportTool.polyShape:
        _makeDrawnShape();
      case ViewportTool.cut:
        _applyCut();
      case ViewportTool.none:
        break;
    }
  }

  /// Turns the outline into an object.
  void _makeDrawnShape() {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) return;

    final normal = _drawing.normal ?? Vector3(0, 1, 0);
    if (outlineCrosses(_drawing.points, normal)) {
      _say('That outline crosses itself.', level: LogLevel.warning);
      return;
    }

    // The points are kept relative to where the object stands, so moving the
    // object later moves the outline with it rather than leaving the two
    // describing different places.
    final middle = Vector3.zero();
    for (final at in _drawing.points) {
      middle.add(at);
    }
    middle.scale(1 / _drawing.points.length);

    final outline = PolyShape(
      points: [for (final at in _drawing.points) at - middle],
      height: 2,
    );

    final object = SceneObject(
      id: _nextObjectId(),
      name: _uniqueName(scene, 'Shape'),
      kind: ObjectKind.shape,
      position: middle,
      outline: outline,
      colour: const Color(0xFF8E99A8),
    );

    _run(AddObject(object, sceneId: open.id));
    setState(_drawing.clear);
    _select(object.id);
    _geometry.forget(object.id);
    _refreshGeometry();
    _say('Drew ${object.name}. Its height is in the inspector.');
  }

  /// Cuts the face the path was drawn on.
  void _applyCut() {
    final chosen = _shapeSelected;
    final face = _drawing.face;
    if (chosen == null || face == null) {
      _say('There is no face to cut.', level: LogLevel.warning);
      return;
    }

    final next = chosen.mesh.copy();
    if (face < 0 || face >= next.faces.length) {
      setState(_drawing.clear);
      return;
    }

    // Into the object's own space, which is where its geometry lives.
    final inverse = Matrix4.inverted(chosen.entry.scene!.worldOf(
      chosen.object.id,
    ));
    final path = [
      for (final at in _drawing.points) inverse.transformed3(at.clone()),
    ];

    final made = next.cutFace(next.faces[face], path);
    if (made.isEmpty) {
      _say(
        'A cut has to start and end on the edge of the face, or come back '
        'to where it began.',
        level: LogLevel.warning,
      );
      return;
    }

    _run(SetGeometry(
      sceneId: chosen.entry.id,
      id: chosen.object.id,
      name: chosen.object.name,
      to: next,
      what: 'Cut',
    ));
    setState(() {
      _drawing.clear();
      // What came out of the cut, because that is what somebody is about to
      // extrude — which is why they cut it.
      _elements = ElementSelection(faces: {
        for (var i = 0; i < next.faces.length; i++)
          if (made.contains(next.faces[i])) i,
      });
      _elementMode = ElementMode.face;
      _context = EditContext.element;
    });
    _geometry.forget(chosen.object.id);
    _geometry.pathFor(chosen.object);
    _say('Cut into ${made.length} faces.');
  }

  /// Which format the export button writes. A view setting: not saved, not
  /// undone, and remembered only for as long as the editor is open.
  MeshFormat _format = MeshFormat.obj;

  /// Writes a shape out, into the project's own exports folder.
  ///
  /// Inside the project rather than wherever a file dialog was last pointed:
  /// an export is a thing somebody made and will want again, and a folder
  /// beside the scenes is where they will look for it.
  Future<void> _exportShape(SceneObject object) async {
    final mesh = object.currentMesh;
    if (mesh == null || mesh.isEmpty) {
      _say('There is no geometry to export.');
      return;
    }

    final name = await promptForName(
      context,
      title: 'Export ${object.name}',
      initial: object.name,
      hint: 'Goes in exports/, as .${_format.extension}.',
      action: 'Export',
    );
    if (!mounted || name == null || name.isEmpty) return;
    if (name.contains(p.separator)) {
      _say('A file name cannot contain a path.');
      return;
    }

    final folder = Directory(
      p.join(widget.project.directory, 'exports'),
    );
    final files = mesh.writeAs(
      _format,
      name: name,
      materials: [for (final one in object.surfaces) one.toGlb()],
    );

    try {
      folder.createSync(recursive: true);
      for (final file in files) {
        File(p.join(folder.path, file.name)).writeAsBytesSync(file.bytes);
      }
    } on FileSystemException catch (error) {
      _say('Could not write the export: ${error.message}');
      return;
    }

    // Both names when there are two: an OBJ without the library it names is a
    // grey model and no clue why.
    _say('Exported ${files.map((one) => one.name).join(' and ')} to '
        'exports/.');
  }

  /// Whether picking reaches what is behind the surface.
  ///
  /// A view setting, not a document one: it is not saved and it is not
  /// undone, and two people editing the same shape can disagree about it.
  bool _seeThrough = false;

  /// Takes everything a marquee drew round.
  void _selectElements(List<Object> what, {required bool add}) {
    setState(() {
      if (!add) _elements.clear();
      for (final one in what) {
        switch (one) {
          case final int index when _elementMode == ElementMode.vertex:
            _elements.vertices.add(index);
          case final int index when _elementMode == ElementMode.face:
            _elements.faces.add(index);
          case final MeshEdge edge:
            _elements.edges.add(edge);
          default:
            break;
        }
      }
      // A new set object, so anything comparing the old one against the new
      // sees that it changed.
      _elements = _elements.copy();
    });
  }

  /// Changes a shape's material slots.
  void _setSurfaces(
    SceneObject object,
    List<Surface> surfaces, {
    required bool live,
  }) {
    final entry = _workspace.sceneHolding(object.id);
    if (entry == null) return;
    if (!live) _gesture = Object();

    _run(SetSurfaces(
      sceneId: entry.id,
      id: object.id,
      name: object.name,
      to: surfaces,
      what: 'Materials',
      // A slider run folds into one step; adding a slot does not.
      gesture: live ? _gesture : null,
    ));
    if (!live) _gesture = null;
    _geometry.forget(object.id);
    _geometry.pathFor(object);
    setState(() {});
  }

  /// Paints the selected faces with one of the shape's material slots.
  void _paintFaces(int slot) {
    final chosen = _shapeSelected;
    if (chosen == null || _elements.faces.isEmpty) return;

    final next = chosen.mesh.copy();
    var painted = 0;
    for (final at in _elements.faces) {
      if (at < 0 || at >= next.faces.length) continue;
      next.faces[at].material = slot;
      painted++;
    }
    if (painted == 0) return;

    _run(SetGeometry(
      sceneId: chosen.entry.id,
      id: chosen.object.id,
      name: chosen.object.name,
      to: next,
      what: 'Paint',
    ));
    _geometry.forget(chosen.object.id);
    _geometry.pathFor(chosen.object);
    setState(() {});
  }

  /// Takes a mesh a viewport drag has changed.
  ///
  /// The same path a tool button takes, with two differences: the step is
  /// named after the gesture rather than the tool, and every frame after the
  /// first folds into the first — so a drag across the screen is one thing to
  /// undo however many frames it took.
  void _dragElements(
    Mesh mesh,
    ElementSelection selection,
    String what, {
    required bool merge,
  }) {
    final chosen = _shapeSelected;
    if (chosen == null) return;

    // A key that lasts the gesture. Bumped on the first change of a drag, so
    // two separate drags of the same face never fold into each other.
    if (!merge) _gesture = Object();

    _run(SetGeometry(
      sceneId: chosen.entry.id,
      id: chosen.object.id,
      name: chosen.object.name,
      to: mesh,
      what: what,
      gesture: _gesture,
    ));

    setState(() => _elements = selection);
    _geometry.forget(chosen.object.id);
    // Only the one being dragged. Writing every shape in the project on every
    // frame of a drag is the whole project's geometry sixty times a second.
    _geometry.pathFor(chosen.object);
  }

  /// What ties one gesture's worth of commands together.
  Object? _gesture;

  /// Writes out the geometry of every shape that has changed.
  ///
  /// Called when something changes rather than when something is drawn. Doing
  /// it from the render path meant a shape was only written where there was a
  /// renderer to write it for — so on a platform Filament has not reached, or
  /// in a headless run, the file never appeared at all.
  void _refreshGeometry() {
    // Not clearing the imported-size cache. That cache is keyed on an
    // object's `meshAsset`, which a shape does not have — so clearing it here
    // never made a shape's box any newer, and did make every imported model
    // in the scene read its file from disk again. On every frame of a drag.
    for (final entry in [..._workspace.entries, _workspace.sharedEntry]) {
      final scene = entry.scene;
      if (scene == null) continue;
      for (final object in scene.objects) {
        if (object.kind != ObjectKind.shape) continue;
        _geometry.pathFor(object);
      }
    }
  }

  /// Changes a shape's numbers.
  void _reshape(SceneObject object, Shape shape) {
    final open = _workspace.sceneHolding(object.id);
    if (open == null) return;

    _run(SetShape(
      sceneId: open.id,
      id: object.id,
      name: object.name,
      to: shape,
    ));
    _geometry.forget(object.id);
    _refreshGeometry();
  }

  late final ScriptBuilder _builder = ScriptBuilder(widget.project.directory);

  /// Interfaces read off disk, by path.
  ///
  /// Cached because the scene is rebuilt every frame and a canvas object asks
  /// for its document each time. Cleared when the project folder changes, so
  /// editing an interface shows up in the scene without reopening it.
  final Map<String, UiDocument?> _interfaces = {};

  /// Whether the interface is drawn over the viewport.
  bool _showInterface = true;

  /// Whether the renderer outlines the selection, or the boundaries are drawn
  /// over the picture instead. Held here so every viewport agrees.
  bool _outlineSelection = true;


  /// Everything the editor has said. Kept, rather than shown for four seconds
  /// in a corner and lost.
  final EditorLog _log = EditorLog();

  /// Puts Flutter's own errors in the console. Undone on dispose.
  late final VoidCallback _stopCatching = _log.catchFlutterErrors();


  /// The data object being looked at, or null when the inspector is showing
  /// the scene's selection.
  String? _dataAsset;

  /// The selected objects. Empty when the scene itself is selected.
  final Set<String> _selected = {};

  /// The one the inspector shows, and what a shift-click ranges from.
  String? _primary;

  bool _playing = false;


  /// What the renderer has already been heard on, so a note is said once
  /// rather than on every frame of a drag. A subject that stops being
  /// reported leaves this set, so fixing a scene and breaking it again is
  /// heard both times.
  final Set<String> _reportedNotes = {};

  int _nextSceneId = 0;

  /// Survives a scene being unloaded, which is what makes moving something
  /// from one scene to another possible at all.
  final SceneClipboard _clipboard = SceneClipboard();

  @override
  void initState() {
    super.initState();
    // Read once so the handlers are installed, since a late final is not
    // initialised until something asks for it.
    _stopCatching;
    _history.addListener(_onHistoryChanged);
    _workspace.addListener(_onChanged);
    _frames
      ..start()
      ..addListener(_onChanged);

    // The grid's quad and lines, written once. Nothing waits for it: until it
    // is there `planFor` says there is no grid, and a frame or two without
    // one at startup is not worth blocking on.
    _grid.prepare().then((_) {
      if (mounted) setState(() {});
    });

    final opened = _read(_defaultScenePath(), quiet: true);
    _workspace.add(SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: opened.scene.name,
      scene: opened.scene,
      path: opened.path,
      neverWritten: opened.isNew,
    ));
    // Every other scene in the project is listed but not loaded, so they can
    // be reached without going hunting for them.
    _listSiblingScenes();
    _readShared();

    if (opened.problems.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _report(opened.problems),
      );
    }
  }

  /// Reads what every scene in this project has in it.
  ///
  /// A project without one is not a problem — it means nobody has put
  /// anything there yet, and the empty set behaves exactly like an empty
  /// scene.
  void _readShared() {
    final file = File(p.join(widget.project.directory, sharedFileName));
    if (!file.existsSync()) return;

    try {
      final loaded = SceneDocument.decode(file.readAsStringSync());
      _workspace.sharedEntry
        ..scene = loaded.scene
        ..neverWritten = false;
      if (loaded.problems.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _report(loaded.problems),
        );
      }
    } on SceneFormatException catch (error) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _say('The shared objects could not be read: ${error.message}'),
      );
    } on FileSystemException catch (error) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _say('The shared objects could not be read: ${error.message}'),
      );
    }
  }

  @override
  void dispose() {
    _history
      ..removeListener(_onHistoryChanged)
      ..dispose();
    _workspace
      ..removeListener(_onChanged)
      ..dispose();
    _assets.dispose();
    _frames
      ..removeListener(_onChanged)
      ..dispose();
    // Flutter's error handlers are global: leaving ours installed would send
    // the next editor window's errors, and a test's, into a log that is gone.
    _stopCatching();
    _log.dispose();
    super.dispose();
  }

  void _onChanged() {
    // An undo can bring a shape back or change what it is, and the file the
    // renderer loads has to follow it.
    _refreshGeometry();
    setState(() {});
  }

  /// A change from the undo stack.
  ///
  /// Split from the one above so that a drag — which runs a command a frame
  /// and only ever moves things — can rebuild the parts that show where
  /// things are and leave the rest of the editor alone.
  void _onHistoryChanged() {
    _refreshGeometry();
    if (_history.lastOnlyMoved) {
      _rebuildForMove();
      return;
    }
    setState(() {});
  }

  /// Whether everything has to be built again, or only what shows movement.
  ///
  /// Set by `setState` itself rather than by each caller, so the safe answer
  /// is the automatic one: a path that forgets to say anything gets a full
  /// rebuild, which costs a frame. The other way round costs a panel showing
  /// something that is no longer true.
  bool _deep = true;
  bool _shallow = false;

  /// What the frame being built decided. [_deep] is cleared as the build
  /// starts, and the panels are built after that.
  bool _deeply = true;

  @override
  void setState(VoidCallback fn) {
    if (!_shallow) _deep = true;
    super.setState(fn);
  }

  void _rebuildForMove() {
    _shallow = true;
    setState(() {});
    _shallow = false;
  }

  /// The panels as they were last built, so a panel a move cannot affect is
  /// handed back unchanged — and Flutter, seeing the same widget, leaves its
  /// whole subtree alone: no rebuild, no layout, no paint.
  final Map<String, Widget> _panels = {};

  /// Which panels show where things are.
  ///
  /// The inspector is not one of them, even though it shows the numbers: the
  /// three rows that do listen for themselves, so the rest of it — a dozen
  /// text fields with their own focus, actions and overlays — is left alone.
  static bool _showsMovement(PanelKind kind) =>
      kind == PanelKind.viewport || kind == PanelKind.game;

  String _defaultScenePath() =>
      p.join(widget.project.directory, 'scenes', 'main$sceneExtension');

  /// Replaces, adds to, or extends the selection.
  void _select(String id, {bool additive = false, bool range = false}) {
    final scene = _current?.scene;
    if (scene == null) return;

    setState(() {
      _selectedScene = null;
      // Back to the scene: the inspector shows one thing, and it is whatever
      // was touched last.
      _dataAsset = null;

      if (range && _primary != null) {
        // Everything between the anchor and here, in the order the tree is
        // drawn — which is what somebody shift-clicking means, rather than the
        // order objects happen to sit in the document.
        final order = _visibleOrder(scene);
        final from = order.indexOf(_primary!);
        final to = order.indexOf(id);
        if (from >= 0 && to >= 0) {
          final low = from < to ? from : to;
          final high = from < to ? to : from;
          _selected.addAll(order.sublist(low, high + 1));
          _primary = id;
          return;
        }
      }

      if (additive) {
        if (!_selected.remove(id)) {
          _selected.add(id);
          _primary = id;
        } else if (_primary == id) {
          _primary = _selected.isEmpty ? null : _selected.last;
        }
        return;
      }

      _selected
        ..clear()
        ..add(id);
      _primary = id;
    });
  }

  /// Object ids in the order the tree draws them.
  List<String> _visibleOrder(EditorScene scene) {
    final order = <String>[];
    void walk(List<SceneObject> objects) {
      for (final object in objects) {
        order.add(object.id);
        walk(scene.childrenOf(object.id));
      }
    }

    walk(scene.roots);
    return order;
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _primary = null;
      });

  /// The scene an edit goes into. Only one is loaded, so there is only one.
  SceneEntry? get _current => _workspace.loaded;

  /// The scene whose settings the inspector shows: the loaded one, or one
  /// somebody has clicked to look at without opening.
  SceneEntry? get _inspected =>
      _selectedScene == null ? _workspace.loaded : _workspace[_selectedScene!];

  /// What is on the clipboard, kept so a menu can name it without reading the
  /// system clipboard, which cannot be done without waiting.
  String get _clipboardLabel => _clipboard.description;

  String? _selectedScene;

  /// Whether a scene has changes that are not on disk.
  bool _isUnsaved(SceneEntry entry) =>
      entry.isLoaded &&
      (entry.neverWritten || _history.stampFor(entry.id) != entry.savedStamp);

  bool get _anyUnsaved => _workspace.entries.any(_isUnsaved);

  /// Lists the project's other scenes without loading them.
  void _listSiblingScenes() {
    final folder = Directory(p.join(widget.project.directory, 'scenes'));
    if (!folder.existsSync()) return;

    for (final file in folder.listSync().whereType<File>()) {
      if (p.extension(file.path) != sceneExtension) continue;
      if (_workspace.entryFor(file.path) != null) continue;
      _workspace.add(SceneEntry(
        id: 'scene${_nextSceneId++}',
        name: p.basenameWithoutExtension(file.path),
        path: file.path,
      ));
    }
  }

  void _run(EditorCommand command) {
    try {
      _history.run(command);
    } on SceneError catch (error) {
      _say(error.message);
    }
  }

  /// Reads a scene file without touching any state.
  ({EditorScene scene, String? path, bool isNew, List<String> problems}) _read(
    String path, {
    bool quiet = false,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      return (
        scene: EditorScene.starter(),
        path: path,
        isNew: true,
        problems: quiet ? const <String>[] : ['There is no scene at $path.'],
      );
    }

    try {
      final load = SceneDocument.decode(file.readAsStringSync());
      return (
        scene: load.scene,
        path: path,
        isNew: false,
        problems: load.problems,
      );
    } on SceneFormatException catch (error) {
      return (
        scene: EditorScene.starter(),
        path: null,
        isNew: false,
        problems: [error.message],
      );
    } on FileSystemException catch (error) {
      return (
        scene: EditorScene.starter(),
        path: null,
        isNew: false,
        problems: ['Could not read that scene: ${error.message}'],
      );
    }
  }

  /// Loads a scene, replacing whatever was loaded.
  ///
  /// One at a time, so the viewport shows one document and there is never a
  /// question about which scene an edit belongs to. What was loaded is put
  /// back to being a name and a path — and if it had unsaved changes, that is
  /// asked about first, because unloading is the moment the work would be
  /// lost.
  Future<void> _loadScene(SceneEntry entry) async {
    if (entry.isLoaded) return;

    final leaving = _workspace.loaded;
    if (leaving != null && _isUnsaved(leaving)) {
      final answer = await _confirmLeaving(leaving);
      if (answer == null) return;
      if (answer) {
        _save(leaving);
        // Refused or failed, so the change is still only in memory.
        if (_isUnsaved(leaving)) return;
      }
    }

    final path = entry.path;
    if (path == null) {
      _say('${entry.title} has never been saved, so there is nothing to load.');
      return;
    }

    final opened = _read(path);
    if (opened.path == null) {
      _report(opened.problems);
      return;
    }

    if (leaving != null) {
      // Its steps go with it: undoing into a scene that is not loaded would be
      // a step that appears to do nothing.
      _history.forget(leaving.id);
      _workspace.unload(leaving);
    }

    _workspace.load(entry, opened.scene);
    entry
      ..name = opened.scene.name
      ..neverWritten = false
      ..savedStamp = _history.stampFor(entry.id);

    setState(() {
      _selected.clear();
      _primary = null;
      _selectedScene = null;
      _camera = OrbitCamera();
      _reportedNotes.clear();
    });
    _report(opened.problems);
  }

  /// Lists a scene file and loads it.
  Future<void> _openScene(String path) async {
    final existing = _workspace.entryFor(path);
    if (existing != null) {
      await _loadScene(existing);
      return;
    }

    final entry = SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: p.basenameWithoutExtension(path),
      path: path,
    );
    _workspace.add(entry);
    await _loadScene(entry);
  }

  void _report(List<String> problems) {
    if (problems.isEmpty) return;
    _say(
      problems.length == 1
          ? problems.single
          : '${problems.length} things in that scene could not be read. '
              'First: ${problems.first}',
    );
  }

  /// Writes the loaded scene back to the file it came from.
  ///
  /// Synchronous on purpose. An awaited write leaves a gap between encoding
  /// the scene and recording that it was saved — an edit landing in that gap
  /// is not in the file, but the history would call itself clean.
  void _save([SceneEntry? which]) {
    final entry = which ?? _current;
    final scene = entry?.scene;
    if (entry == null || scene == null) return;

    final path = entry.path;
    if (path == null) {
      _saveAs(entry);
      return;
    }

    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(SceneDocument.encode(scene));
    } on FileSystemException catch (error) {
      _say('Could not save ${entry.title}: ${error.message}');
      return;
    }

    setState(() {
      entry
        ..neverWritten = false
        ..savedStamp = _history.stampFor(entry.id);
    });
    _say('Saved ${_assets.relative(path)}');

    // What every scene has goes with whichever one was saved. Asking somebody
    // to save two files to keep one project consistent is asking them to
    // forget one of them.
    if (!identical(entry, _workspace.sharedEntry)) _saveShared();
  }

  /// Writes the shared set, if anything has happened to it.
  void _saveShared() {
    final entry = _workspace.sharedEntry;
    final scene = entry.scene;
    final path = entry.path;
    if (scene == null || path == null) return;
    if (entry.savedStamp == _history.stampFor(entry.id) &&
        !entry.neverWritten) {
      return;
    }
    // Nothing in it and never written: no reason to leave an empty file in
    // somebody's repository.
    if (scene.length == 0 && entry.neverWritten) return;

    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(SceneDocument.encode(scene));
    } on FileSystemException catch (error) {
      _say('Could not save the shared objects: ${error.message}', level: LogLevel.error);
      return;
    }

    setState(() {
      entry
        ..neverWritten = false
        ..savedStamp = _history.stampFor(entry.id);
    });
  }

  Future<void> _saveAs([SceneEntry? which]) async {
    final open = which ?? _current;
    if (open == null || !open.isLoaded) return;

    final name = await promptForName(
      context,
      title: 'Save scene as',
      initial: open.title,
      hint: 'Goes in scenes/, as $sceneExtension.',
      action: 'Save',
    );
    if (!mounted || name == null || name.isEmpty) return;

    if (name.contains(p.separator)) {
      _say('A scene name cannot contain a path.');
      return;
    }

    final path = _workspace.pathFor(name);
    if (File(path).existsSync() &&
        (open.path == null || !p.equals(path, open.path!))) {
      _say('There is already a scene called $name.');
      return;
    }

    setState(() => open.path = path);
    _save(open);
  }

  /// Starts a new scene, replacing whatever is loaded.
  Future<void> _newScene() async {
    final leaving = _workspace.loaded;
    if (leaving != null && _isUnsaved(leaving)) {
      final answer = await _confirmLeaving(leaving);
      if (answer == null) return;
      if (answer) {
        _save(leaving);
        if (_isUnsaved(leaving)) return;
      }
    }

    if (leaving != null) {
      _history.forget(leaving.id);
      _workspace.unload(leaving);
    }

    final name = _workspace.availableName('Untitled');
    final entry = SceneEntry(
      id: 'scene${_nextSceneId++}',
      name: name,
      neverWritten: true,
    );
    _workspace
      ..add(entry)
      ..load(entry, EditorScene.starter()..name = name);

    setState(() {
      _selected.clear();
      _primary = null;
      _selectedScene = null;
      _camera = OrbitCamera();
    });
  }

  /// Takes a scene off the list, asking first if it has changes.
  Future<void> _closeScene(SceneEntry entry) async {
    if (_isUnsaved(entry)) {
      final answer = await _confirmLeaving(entry);
      if (answer == null) return;
      if (answer) {
        _save(entry);
        if (_isUnsaved(entry)) return;
      }
    }

    _history.forget(entry.id);
    _workspace.remove(entry.id);
    setState(() {
      _selected.clear();
      _primary = null;
      if (_selectedScene == entry.id) _selectedScene = null;
    });
  }

  /// True to save, false to discard, null to stop.
  ///
  /// Asked whenever a scene with changes is about to stop being loaded —
  /// which is the only moment the work could be lost, and so the only moment
  /// worth interrupting for.
  Future<bool?> _confirmLeaving(SceneEntry open) async {
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Save ${open.title} first?', style: OrbisText.title),
        content: Text(
          open.path == null
              ? 'It has never been written to disk. Closing it loses it.'
              : 'It has changes that have not been written to disk.',
          style: OrbisText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (answer == 'save') return true;
    if (answer == 'discard') return false;
    return null;
  }

  /// The scene being worked in, which is not always the one that is loaded.
  ///
  /// The shared set — the objects every scene has — is a scene that is always
  /// there and never the loaded one. Something selected in it is being edited
  /// in it, and every edit that reaches for "the scene" has to mean that one
  /// or the shared set becomes a place things can only be built, never
  /// copied, pasted, duplicated or dragged into.
  SceneEntry? get _working => _primary == null
      ? _current
      : (_workspace.sceneHolding(_primary!) ?? _current);

  void _add(ObjectKind kind) {
    // Wherever the selection is. Selecting something in the shared set and
    // pressing Add means adding to the shared set — anything else would be
    // the button ignoring where somebody is working.
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.', level: LogLevel.warning);
      return;
    }

    final name = _uniqueName(scene, switch (kind) {
      ObjectKind.mesh => 'Mesh',
      ObjectKind.light => 'Light',
      ObjectKind.camera => 'Camera',
      ObjectKind.group => 'Group',
      ObjectKind.scene => 'Scene',
      ObjectKind.weather => 'Weather',
      ObjectKind.canvas => 'Canvas',
      ObjectKind.shape => 'Shape',
    });

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      kind: kind,
      colour: kind == ObjectKind.light
          ? const Color(0xFFFFF3E0)
          : const Color(0xFFD9634F),
    );

    // Added inside whatever is selected when that can hold things, which is
    // what somebody building a hierarchy means by "add" most of the time.
    final selected = _primary == null ? null : scene[_primary!];
    final parent = selected == null
        ? null
        : (selected.kind == ObjectKind.group ? selected.id : selected.parentId);

    _run(AddObject(object, sceneId: open.id, parentId: parent));
    _select(object.id);
  }

  /// Puts a shape in the scene.
  ///
  /// Parametric to begin with: it is a width, a height and a depth until
  /// somebody pulls a face off it, and until then changing the width should
  /// change the width rather than move eight corners.
  void _addShape(ShapeKind kind) {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.', level: LogLevel.warning);
      return;
    }

    final object = SceneObject(
      id: _nextObjectId(),
      name: _uniqueName(scene, kind.label),
      kind: ObjectKind.shape,
      shape: Shape(kind: kind),
      colour: const Color(0xFF8E99A8),
    );

    final selected = _primary == null ? null : scene[_primary!];
    _run(AddObject(
      object,
      sceneId: open.id,
      parentId: selected?.kind == ObjectKind.group ? selected!.id : null,
    ));
    _select(object.id);
    _refreshGeometry();
  }

  String _uniqueName(EditorScene scene, String base) {
    final taken = {for (final o in scene.objects) o.name};
    if (!taken.contains(base)) return base;
    for (var i = 2;; i++) {
      if (!taken.contains('$base $i')) return '$base $i';
    }
  }

  /// Deletes one object, whatever is selected.
  void _delete(String id) {
    final open = _workspace.sceneHolding(id);
    final object = open?.scene?[id];
    if (open == null || object == null) return;

    _run(DeleteObjects(sceneId: open.id, ids: [id], what: object.name));
    setState(() {
      _selected.remove(id);
      if (_primary == id) _primary = _selected.lastOrNull;
    });
  }

  /// Deletes everything selected, as one step.
  void _deleteSelection() {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null || _selected.isEmpty) return;

    final ids = _visibleOrder(scene).where(_selected.contains).toList();
    if (ids.isEmpty) return;

    final what = ids.length == 1
        ? (scene[ids.single]?.name ?? 'object')
        : '${ids.length} objects';

    _run(DeleteObjects(sceneId: open.id, ids: ids, what: what));
    _clearSelection();
  }

  /// Moves an object in the tree, by reparenting, reordering, or both.
  void _move(String id, Drop drop) {
    final open = _workspace.sceneHolding(id);
    final scene = open?.scene;
    final object = scene?[id];
    if (open == null || scene == null || object == null) return;

    // Onto a different scene's row — the shared set, most often. A different
    // operation rather than a refusal: one scene loses the subtree and
    // another gains it.
    if (drop.sceneId != open.id) {
      _run(MoveBetweenScenes(
        fromSceneId: open.id,
        sceneId: drop.sceneId,
        id: id,
        name: object.name,
        parentId: drop.parentId,
        index: drop.index,
      ));
      return;
    }

    final fromIndex = scene.indexOf(id);
    var toIndex = drop.index;
    // Removing it first shifts everything after it down by one, so an index
    // taken from the tree as drawn is one too many when moving down.
    if (object.parentId == drop.parentId && fromIndex < toIndex) toIndex -= 1;
    if (object.parentId == drop.parentId && fromIndex == toIndex) return;

    _run(MoveObject(
      sceneId: open.id,
      id: id,
      name: object.name,
      from: object.parentId,
      to: drop.parentId,
      fromIndex: fromIndex,
      toIndex: toIndex,
    ));
  }

  /// Puts the selection on the clipboard, and on the system's.
  ///
  /// Written out as text as well, so a copy can cross into another window —
  /// or into a text editor, where it is readable rather than an opaque blob.
  Future<void> _copy() async {
    final scene = _working?.scene;
    if (scene == null || _selected.isEmpty) return;

    _clipboard.take(scene, _selected);
    setState(() {});
    await services.Clipboard.setData(
      services.ClipboardData(text: _clipboard.toText()),
    );
    _say('Copied ${_clipboard.description}.');
  }

  /// Copies the selection and then removes it.
  Future<void> _cut() async {
    final scene = _working?.scene;
    if (scene == null || _selected.isEmpty) return;

    // Copied before it is deleted, since the delete is what makes it
    // unreachable.
    _clipboard.take(scene, _selected);
    await services.Clipboard.setData(
      services.ClipboardData(text: _clipboard.toText()),
    );
    _deleteSelection();
  }

  /// Puts the clipboard into the loaded scene.
  ///
  /// Beside whatever is selected rather than inside it, which is what somebody
  /// pressing paste usually means — pasting into the thing you were looking at
  /// buries it one level down.
  Future<void> _paste() async {
    // Into whatever holds the selection, so pasting next to a shared prop
    // puts the copy beside it rather than in the scene behind it.
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) return;

    // The system clipboard first, so a copy from another window wins over
    // whatever this one did last.
    final text = await services.Clipboard.getData('text/plain');
    if (!mounted) return;
    _clipboard.takeText(text?.text);

    if (_clipboard.isEmpty) {
      _say('There is nothing on the clipboard to paste.', level: LogLevel.warning);
      return;
    }

    final beside = _primary == null ? null : scene[_primary!];
    final content = _clipboard.contents(
      nextId: _nextObjectId,
      parentId: beside?.parentId,
    );

    _run(PasteObjects(
      sceneId: open.id,
      objects: content.objects,
      roots: content.roots,
      worlds: content.worlds,
      what: _clipboard.description,
    ));

    setState(() {
      _selected
        ..clear()
        ..addAll(content.roots);
      _primary = content.roots.lastOrNull;
    });
  }

  /// Copies the selection and pastes it straight back.
  void _duplicate() {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null || _selected.isEmpty) return;

    // On its own clipboard, so duplicating does not throw away what somebody
    // had copied earlier.
    final taken = SceneClipboard()..take(scene, _selected);
    final content = taken.contents(
      nextId: _nextObjectId,
      parentId: _primary == null ? null : scene[_primary!]?.parentId,
    );

    _run(PasteObjects(
      sceneId: open.id,
      objects: content.objects,
      roots: content.roots,
      worlds: content.worlds,
      what: taken.description,
    ));

    setState(() {
      _selected
        ..clear()
        ..addAll(content.roots);
      _primary = content.roots.lastOrNull;
    });
  }

  String _nextObjectId() =>
      'o${DateTime.now().microsecondsSinceEpoch}_${_nextObject++}';

  int _nextObject = 0;

  void _reportSceneNotes(Map<String, String> notes) {
    // Said once each. The scene is republished on every frame of a drag, and
    // the same missing file would otherwise arrive a hundred times while
    // somebody moved the object that names it.
    _reportedNotes.removeWhere((subject) => !notes.containsKey(subject));

    final fresh = [
      for (final entry in notes.entries)
        if (_reportedNotes.add(entry.key)) entry,
    ];
    if (fresh.isEmpty) return;

    final first = fresh.first;
    // A path is worth shortening to its file name; a subject like "too many
    // lights" is not a path and is left as it is.
    final subject = first.key.contains('/') ? p.basename(first.key) : null;
    _say(
      fresh.length == 1
          ? (subject == null ? first.value : '$subject: ${first.value}')
          : '${fresh.length} things in this scene need attention. '
              '${subject ?? first.key}: ${first.value}',
      level: LogLevel.warning,
      // Every one of them, not just the first: the status bar has room for
      // one line and the console does not.
      detail: [
        for (final note in fresh) '${note.key}: ${note.value}',
      ].join('\n'),
    );
  }

  /// Opens the project in a code editor, optionally on one file.
  ///
  /// The project folder rather than the single file, so imports resolve and
  /// the type definitions next door are findable.
  void _openInCode([String? file]) {
    final problem = CodeEditor.open(widget.project.directory, file: file);
    if (problem != null) {
      _say(problem);
      return;
    }
    _say(file == null
        ? 'Opened the project in ${CodeEditor.available ?? 'your editor'}.'
        : 'Opened ${p.basename(file)} in '
            '${CodeEditor.available ?? 'your editor'}.');
  }

  /// Says something, in both places it belongs.
  ///
  /// The status bar for somebody who is looking, the console for somebody who
  /// was not — which, while they were reading the last message, they were not.
  void _say(String message, {LogLevel level = LogLevel.info, String detail = ''}) {
    _log.say(message, level: level, detail: detail);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: OrbisColors.raised,
        behavior: SnackBarBehavior.floating,
        width: 460,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _frameSelection() {
    final id = _primary;
    final scene = _current?.scene;
    if (scene == null) return;

    final bounds = id == null || !scene.contains(id)
        ? scene.boundsOfEverything()
        : scene.boundsOf(id);

    setState(() {
      _camera = _camera.framing(
        centre: bounds.centre,
        radius: bounds.radius,
      );
    });
  }

  /// Puts a texture on the selected object.
  ///
  /// The case this is for is an asset pack that ships a model and its colour
  /// map as separate files: the model loads grey, because its file names no
  /// texture, and the fix used to be a round trip through a modelling package
  /// to bind the two and export again. The renderer binds them itself — a
  /// material named on an object overrides whatever its mesh brought — so
  /// this only has to say which texture.
  void _applyTexture(String path) {
    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to texture anything in.');
      return;
    }
    final id = _primary;
    final object = id == null ? null : scene[id];
    if (object == null) {
      _say('Select an object first; a texture goes on whatever is selected.');
      return;
    }
    if (!object.isDrawable) {
      _say('${object.name} is a ${object.kind.name}, and has nothing to '
          'draw a texture on.');
      return;
    }
    _run(SetMaterialAsset(
      sceneId: open.id,
      id: object.id,
      name: object.name,
      from: object.materialAsset,
      to: _assets.relative(path),
    ));
  }

  void _dropAsset(String path) {
    final kind = AssetKind.of(path);

    if (kind == AssetKind.scene) {
      _openScene(path);
      return;
    }
    if (kind == AssetKind.prefab) {
      _placePrefab(path);
      return;
    }
    if (kind == AssetKind.dataObject) {
      _attachData(path);
      return;
    }
    if (kind == AssetKind.canvas) {
      _putInterfaceOnScene(path);
      return;
    }
    if (kind == AssetKind.texture) {
      _applyTexture(path);
      return;
    }
    if (kind != AssetKind.mesh) {
      _say('${p.basename(path)} is a ${kind.label.toLowerCase()}. '
          'Meshes, prefabs and scenes are what a scene takes; a texture '
          'goes on whatever is selected.');
      return;
    }

    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.');
      return;
    }

    final object = SceneObject(
      id: 'o${DateTime.now().microsecondsSinceEpoch}',
      name: _uniqueName(scene, p.basenameWithoutExtension(path)),
      kind: ObjectKind.mesh,
      meshAsset: _assets.relative(path),
    );

    _run(AddObject(object, sceneId: open.id));
    _select(object.id);
  }


  // ---- panels ----

  /// How the panels are arranged. Data, so it survives being closed.
  late DockLayout _layout = _readLayout() ?? DockLayout.standard();

  /// A camera per scene view.
  ///
  /// Four views onto one world is four places to be standing. Without one
  /// each, the second view would jump to wherever the first was looking the
  /// moment anybody moved it.
  final Map<String, OrbitCamera> _cameras = {};

  /// The view last used, which is the one F frames in.
  String _using = 'scene';

  OrbitCamera _cameraFor(String id) => _cameras[id] ??= OrbitCamera();

  /// The camera of the view being worked in.
  OrbitCamera get _camera => _cameraFor(_using);

  set _camera(OrbitCamera camera) => _cameras[_using] = camera;

  /// Where the layout is kept: with the project, since it is about this
  /// project's panels rather than about the editor.
  File get _layoutFile =>
      File(p.join(widget.project.directory, '.orbis', 'layout.json'));

  DockLayout? _readLayout() {
    try {
      final file = _layoutFile;
      if (!file.existsSync()) return null;
      return DockLayout.read(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  void _relayout(DockLayout layout) {
    setState(() => _layout = layout);
    try {
      final file = _layoutFile;
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(layout.toText());
    } on FileSystemException {
      // Not worth a message. A layout that cannot be saved comes back as the
      // standard one, which is a small loss and not one worth interrupting
      // somebody over.
    }
  }

  /// One panel, whatever it happens to be.
  ///
  /// The layout says what goes where and this says what each one is. Keeping
  /// the two apart is what lets the arrangement be a file and a drag rather
  /// than a widget tree somebody has to edit.
  Widget _buildPanel(BuildContext context, DockPanel panel) {
    // A move can only change where things are, so a panel that does not show
    // that is handed back exactly as it was. Flutter compares the widget by
    // identity and skips the subtree — which is the whole saving, because a
    // subtree that is not rebuilt is not laid out or painted either.
    if (!_deeply && !_showsMovement(panel.kind)) {
      final was = _panels[panel.id];
      if (was != null) return was;
    }

    final built = _panelFor(context, panel);
    _panels[panel.id] = built;
    return built;
  }

  Widget _panelFor(BuildContext context, DockPanel panel) {
    final selected = _primary == null ? null : _inspected?.scene?[_primary!];

    return switch (panel.kind) {
      PanelKind.outliner => Outliner(
            workspace: _workspace,
            selected: _selected,
            primary: _primary,
            onSelect: _select,
            onSelectScene: (entry) => setState(() {
            _selected.clear();
            _primary = null;
            _selectedScene = entry.id;
            }),
            onLoadScene: _loadScene,
            onMove: _move,
            onDelete: _delete,
            onCloseScene: _closeScene,
            ),
      PanelKind.inspector => Inspector(
            entry: _inspected,
            object: selected,
            history: _history,
            onLoad: _loadScene,
            selectionCount: _selected.length,
            dataAsset: _dataAsset,
            dataPanel: _dataAsset == null
            ? null
            : DataPanel(
            key: ValueKey(_dataAsset),
            path: _dataAsset!,
            store: _data,
            onProblem: _say,
            onExportTypes: () =>
            _exportBindings(_dataAsset!),
            ),
            onOpenData: _showData,
            // The shape and geometry controls. The inspector shows what it is
            // given and does not know what an extrude is.
            meshPanel: selected?.kind != ObjectKind.shape
                ? null
                : MeshPanel(
                    shape: selected!.shape,
                    geometry: selected.geometry,
                    onShape: (shape) => _reshape(selected, shape),
                    outline: selected.outline,
                    onOutline: (next, {required live}) =>
                        _setOutline(selected, next, live: live),
                    boundary: selected.boundary,
                    onBoundary: (next, {required live}) =>
                        _setBoundary(selected, next, live: live),
                    naturalSize:
                        selected.localBounds(reported: _models.of(selected)),
                    onOpenTools: () => setState(
                      () => _layout = _layout.add(
                        const DockPanel(id: 'modelling',
                            kind: PanelKind.modelling),
                      ),
                    ),
                  ),
            onOpenInterface: (path) => _openInterface(
            p.join(widget.project.directory, path),
            ),
            onDetachData: _detachData,
            onApplyPrefab: _applyPrefab,
            onRevertPrefab: _revertPrefab,
            onUnpackPrefab: _unpackPrefab,
            ),
      PanelKind.viewport => SceneViewport(
            workspace: _workspace,
            camera: _cameraFor(panel.id),
            onCameraChanged: (camera) =>
                setState(() => _cameras[panel.id] = camera),
            selected: _selected,
            primary: _primary,
            history: _history,
            onPick: (id, {required bool add}) {
              // Whichever view was last used is the one F frames in.
              _using = panel.id;
            // Clicking empty space clears the
            // selection, which is how somebody puts the
            // handles away without reaching for a menu.
            if (id == null) {
            if (add) return;
            setState(() {
            _selected.clear();
            _primary = null;
            _selectedScene = null;
            });
            return;
            }
            _select(id, additive: add);
            },
            onDropAsset: _dropAsset,
            projectRoot: widget.project.directory,
            editing: _editing,
            elementMode: _elementMode,
            elementSelection: _elements,
            onPickElement: _pickElement,
            onDragElements: _dragElements,
            onSelectElements: _selectElements,
            seeThroughElements: _seeThrough,
            snapping: _snapping,
            grid: _grid,
            models: _models,
            drawing: _drawing,
            onDrawPoint: _drawPoint,
            onDrawFinish: _finishDrawing,
            onSnapping: (next) => setState(() {
              _snapping
                ..on = next.on
                ..step = next.step
                ..angle = next.angle;
            }),
            geometryOf: _geometry.pathFor,
            interface: _sceneInterface,
            showInterface: _showInterface,
            onToggleInterface: () => setState(
            () => _showInterface = !_showInterface,
            ),
            outlineSelection: _outlineSelection,
            onToggleOutline: () => setState(
              () => _outlineSelection = !_outlineSelection,
            ),
            previewOf: (camera) => GameView(
              workspace: _workspace,
              projectRoot: widget.project.directory,
              geometryOf: _geometry.pathFor,
              through: camera,
              plain: true,
            ),
            onSceneNotes: _reportSceneNotes,
            // The viewport owns the clock; this is how
            // the tree and the inspector hear about it.
            onClock: () {
            if (mounted) setState(() {});
            },
            ),
      PanelKind.game => GameView(
          workspace: _workspace,
          projectRoot: widget.project.directory,
          geometryOf: _geometry.pathFor,
          interface: _sceneInterface,
        ),
      PanelKind.project => AssetBrowser(
            tree: _assets,
                        onOpenAsset: (asset) {
            // A scene opens here; anything somebody would
            // type into goes where they type.
            if (asset.kind == AssetKind.scene) {
            _openScene(asset.path);
            return;
            }
            if (asset.kind == AssetKind.canvas) {
            _openInterface(asset.path);
            return;
            }
            if (asset.kind == AssetKind.texture) {
            _applyTexture(asset.path);
            return;
            }
            const editable = {
            AssetKind.script,
            AssetKind.style,
            AssetKind.native,
            AssetKind.data,
            AssetKind.material,
            };
            if (editable.contains(asset.kind)) {
            _openInCode(asset.path);
            }
            },
            onProblem: _say,
            onMakePrefab: _makePrefab,
            onBuild: (asset) => _buildScript(asset.path),
            onSelectAsset: (asset) => setState(() {
            // Only a data object claims the inspector.
            // Selecting a mesh should not take the panel
            // away from the object being edited.
            _dataAsset =
            asset?.kind == AssetKind.dataObject
            ? _assets.relative(asset!.path)
            : null;
            }),
            ),
      PanelKind.console => ConsolePanel(log: _log),
      PanelKind.modelling => SingleChildScrollView(
          padding: const EdgeInsets.all(Space.sm),
          child: _modellingTools(),
        ),
      PanelKind.uvs => SingleChildScrollView(
          padding: const EdgeInsets.all(Space.sm),
          child: _uvEditor(),
        ),
    };
  }

  // ---- interfaces ----

  /// Puts an interface on the open scene.
  ///
  /// Onto the selected canvas if there is one, and onto a new canvas object if
  /// there is not. Dropping a file and being told to make an object first
  /// would be the editor knowing what somebody meant and refusing to do it.
  void _putInterfaceOnScene(String path) {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.');
      return;
    }

    final relative = _assets.relative(path);
    final selected = _primary == null ? null : scene[_primary!];

    if (selected != null && selected.kind == ObjectKind.canvas) {
      _run(SetInterface(
        sceneId: open.id,
        id: selected.id,
        name: selected.name,
        to: relative,
      ));
      _say('${selected.name} now shows ${p.basename(path)}.');
      return;
    }

    final object = SceneObject(
      id: _nextObjectId(),
      name: _uniqueName(scene, p.basenameWithoutExtension(path)),
      kind: ObjectKind.canvas,
      interfaceAsset: relative,
    );
    _run(AddObject(object, sceneId: open.id));
    _select(object.id);
  }

  /// The interface the open scene puts on screen, if any.
  ///
  /// The first visible canvas object, since a screen shows one interface at a
  /// time. Two canvases both visible is a scene saying two things, and picking
  /// the first is at least the one nearest the top of the tree.
  UiDocument? get _sceneInterface {
    final scene = _current?.scene;
    if (scene == null) return null;

    for (final object in scene.objects) {
      if (object.kind != ObjectKind.canvas) continue;
      if (!object.visible || !scene.isShown(object.id)) continue;

      final path = object.interfaceAsset;
      if (path == null) continue;
      return _interfaces.putIfAbsent(path, () => _readInterface(path));
    }
    return null;
  }

  UiDocument? _readInterface(String relative) {
    try {
      final file = File(p.join(widget.project.directory, relative));
      if (!file.existsSync()) return null;
      return UiDocument.read(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Opens a canvas for laying out.
  ///
  /// A screen of its own rather than a panel. A canvas is a design surface at
  /// a fixed size, and one squeezed into the space beside a 3D viewport is a
  /// view too small to lay anything out in next to a viewport nobody is
  /// looking at.
  Future<void> _openInterface(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      _say('${p.basename(path)} is not in the project any more.');
      return;
    }

    final document = UiDocument.read(file.readAsStringSync());
    if (document == null) {
      _say('${p.basename(path)} is not a readable interface.');
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => UiEditor(
          path: path,
          document: document,
          onProblem: _say,
        ),
      ),
    );
    // Read again: the scene is showing what was on disk before it was edited.
    if (mounted) setState(() => _interfaces.clear());
  }

  // ---- scripts ----

  /// Compiles a C++ script and says what the compiler said.
  ///
  /// A success is a line in the status bar; a failure is a panel, because a
  /// compiler error is several lines long and the first of them is rarely the
  /// useful one.
  Future<void> _buildScript(String path) async {
    final name = p.basename(path);
    _say('Building $name…');

    // Off the frame: a compile is a second or two, and a frozen editor for
    // that long reads as a crash.
    final built = await Future(() => _builder.build(path));
    if (!mounted) return;

    if (built.ok) {
      _say(
        'Built $name.${built.output.isEmpty ? '' : ' With warnings.'}',
        level: built.output.isEmpty ? LogLevel.info : LogLevel.warning,
        detail: built.output,
      );
      if (built.output.isEmpty) return;
    } else {
      _say(
        '$name did not build.',
        level: LogLevel.error,
        detail: built.output,
      );
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text(
          built.ok ? '$name built, with warnings' : '$name did not build',
          style: OrbisText.title,
        ),
        content: SizedBox(
          width: 640,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              built.output.isEmpty ? 'The compiler said nothing.' : built.output,
              style: OrbisText.mono.copyWith(fontSize: 11.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---- data objects ----

  /// Points the selection at a data object.
  ///
  /// Everything selected, not just one: attaching the same settings to forty
  /// crates is the case this exists for, and doing it one at a time forty
  /// times is not an improvement on typing the number forty times.
  void _attachData(String path) {
    final open = _working;
    final scene = open?.scene;
    if (open == null || scene == null) return;

    final relative = _assets.relative(path);
    if (_data[relative] == null) {
      _say('${p.basename(path)} is not a readable data object.');
      return;
    }

    final wanted = [
      for (final id in _selected)
        if (scene[id] case final object?)
          if (!object.data.contains(relative)) object,
    ];

    if (wanted.isEmpty) {
      _say(_selected.isEmpty
          ? 'Select something first, then drop ${p.basename(path)} on it.'
          : 'Already using ${p.basename(path)}.');
      return;
    }

    for (final object in wanted) {
      _run(SetDataLinks(
        sceneId: open.id,
        id: object.id,
        name: object.name,
        paths: [...object.data, relative],
        what: 'Add ${p.basenameWithoutExtension(path)}',
      ));
    }
    _say(wanted.length == 1
        ? 'Added ${p.basename(path)} to ${wanted.single.name}.'
        : 'Added ${p.basename(path)} to ${wanted.length} objects.');
  }

  void _detachData(String id, String relative) {
    final open = _workspace.sceneHolding(id);
    final object = open?.scene?[id];
    if (open == null || object == null) return;

    _run(SetDataLinks(
      sceneId: open.id,
      id: id,
      name: object.name,
      paths: [for (final path in object.data) if (path != relative) path],
      what: 'Remove ${p.basenameWithoutExtension(relative)}',
    ));
  }

  /// Shows a data object in the inspector, from wherever it was named.
  void _showData(String relative) {
    if (_data[relative] == null) {
      _say('$relative is not in the project any more.');
      return;
    }
    setState(() => _dataAsset = relative);
  }

  /// Writes the bindings a script reads a data object through.
  ///
  /// Both languages from the one declaration, which is the piece that makes
  /// three front ends feel like one: a field renamed here breaks the build of
  /// everything that reads it, in TypeScript and in C++, rather than quietly
  /// returning nothing at runtime. The alternative is a string key and hope.
  void _exportBindings(String relative) {
    final data = _data[relative];
    if (data == null) return;

    final name = p.basenameWithoutExtension(relative);
    final folder = p.join(widget.project.directory, p.dirname(relative));

    final written = <String>[];
    for (final one in [
      (file: '$name.d.ts', text: data.toTypeScript(name)),
      (file: '$name.h', text: data.toCpp(name)),
    ]) {
      final path = p.join(folder, one.file);
      try {
        File(path).writeAsStringSync(one.text);
      } on FileSystemException catch (error) {
        _say('Could not write ${one.file}: '
            '${error.osError?.message ?? error.message}', level: LogLevel.error);
        return;
      }
      written.add(one.file);
    }
    _say('Wrote ${written.join(' and ')}.');
  }

  // ---- prefabs ----

  /// Saves an object and everything under it as a prefab asset.
  ///
  /// The object it was made from becomes the first instance, the way it does
  /// in every editor that has prefabs. Anything else and the thing on screen
  /// would look like the prefab while quietly not being one.
  void _makePrefab(ObjectDrag dragged, String directory) {
    final open = _workspace.sceneHolding(dragged.id);
    final scene = open?.scene;
    if (open == null || scene == null) return;

    final object = scene[dragged.id];
    if (object == null) return;
    if (object.kind == ObjectKind.scene) {
      _say('A scene is already a file. Save it instead.');
      return;
    }

    final Prefab prefab;
    try {
      prefab = Prefab.fromScene(scene, dragged.id);
    } on SceneError catch (error) {
      _say(error.message);
      return;
    }

    final made = _assets.write(
      directory,
      '${object.name}${Prefab.extension}',
      prefab.toText(),
    );
    if (made.problem != null || made.path == null) {
      _say('Could not save the prefab: ${made.problem}', level: LogLevel.error);
      return;
    }

    final source = _assets.relative(made.path!);
    _run(LinkPrefab(
      sceneId: open.id,
      ids: [dragged.id, for (final child in scene.descendantsOf(dragged.id)) child.id],
      source: source,
      what: object.name,
    ));
    _say('Saved ${p.basename(made.path!)}. '
        '${object.name} is now an instance of it.');
  }

  /// Reads a prefab off disk, saying so rather than failing silently.
  Prefab? _readPrefab(String relativeOrAbsolute) {
    final path = p.isAbsolute(relativeOrAbsolute)
        ? relativeOrAbsolute
        : p.join(widget.project.directory, relativeOrAbsolute);

    final file = File(path);
    if (!file.existsSync()) {
      _say('${p.basename(path)} is not in the project any more.');
      return null;
    }

    final prefab = Prefab.read(file.readAsStringSync());
    if (prefab == null) _say('${p.basename(path)} is not a readable prefab.');
    return prefab;
  }

  /// Puts an instance of a prefab into the open scene.
  void _placePrefab(String path) {
    final open = _current;
    final scene = open?.scene;
    if (open == null || scene == null) {
      _say('There is no scene loaded to add to.');
      return;
    }

    final prefab = _readPrefab(path);
    if (prefab == null) return;

    final selected = _primary == null ? null : scene[_primary!];
    final parent = selected == null
        ? null
        : (selected.kind == ObjectKind.group ? selected.id : selected.parentId);

    final made = prefab.instantiate(
      nextId: _nextObjectId,
      source: _assets.relative(path),
      parentId: parent,
      name: _uniqueName(scene, prefab.name),
    );

    _run(PasteObjects(
      sceneId: open.id,
      objects: made.objects,
      roots: [made.rootId],
      what: prefab.name,
    ));
    _select(made.rootId);
  }

  /// Writes what an instance looks like now back to its prefab, and brings
  /// every other instance of it into line.
  ///
  /// The other instances keep where they stand and what they are called;
  /// everything else comes from the asset. Any other property somebody had
  /// changed on one of them goes, which is why this says how many it touched
  /// rather than doing it quietly.
  void _applyPrefab(String id) {
    final open = _workspace.sceneHolding(id);
    final scene = open?.scene;
    final object = scene?[id];
    final source = object?.prefab;
    if (open == null || scene == null || object == null || source == null) {
      return;
    }

    final Prefab prefab;
    try {
      prefab = Prefab.fromScene(scene, id);
    } on SceneError catch (error) {
      _say(error.message);
      return;
    }

    final path = p.join(widget.project.directory, source);
    try {
      File(path).writeAsStringSync(prefab.toText());
    } on FileSystemException catch (error) {
      _say('Could not write ${p.basename(path)}: '
          '${error.osError?.message ?? error.message}');
      return;
    }

    final touched = _syncInstances(prefab, source, except: id);
    _say(touched == 0
        ? 'Saved ${p.basename(path)}.'
        : 'Saved ${p.basename(path)} and updated $touched other '
            'instance${touched == 1 ? '' : 's'}.');
  }

  /// Throws away an instance's local changes and takes the prefab's again.
  void _revertPrefab(String id) {
    final open = _workspace.sceneHolding(id);
    final scene = open?.scene;
    final object = scene?[id];
    final source = object?.prefab;
    if (open == null || scene == null || object == null || source == null) {
      return;
    }

    final prefab = _readPrefab(source);
    if (prefab == null) return;

    final made = prefab.resyncing(
      scene,
      id,
      nextId: _nextObjectId,
      source: source,
    );
    _run(ReplaceSubtree(
      sceneId: open.id,
      rootId: made.rootId,
      objects: made.objects,
      what: object.name,
    ));
    _select(made.rootId);
  }

  /// Brings every instance of one prefab, in every loaded scene, into line
  /// with it. Returns how many were changed.
  int _syncInstances(Prefab prefab, String source, {String? except}) {
    var touched = 0;

    for (final entry in _workspace.entries) {
      final scene = entry.scene;
      if (scene == null) continue;

      // Roots only: an instance nested inside another instance is replaced by
      // its parent's own resync, and doing both would replace it twice.
      final roots = [
        for (final object in scene.objects.toList())
          if (object.prefab == source &&
              object.id != except &&
              (object.parentId == null ||
                  scene[object.parentId!]?.prefab != source))
            object.id,
      ];

      for (final id in roots) {
        if (!scene.contains(id)) continue;
        final made = prefab.resyncing(
          scene,
          id,
          nextId: _nextObjectId,
          source: source,
        );
        _run(ReplaceSubtree(
          sceneId: entry.id,
          rootId: made.rootId,
          objects: made.objects,
          what: scene[id]?.name ?? prefab.name,
          label_: 'Update',
        ));
        touched++;
      }
    }

    return touched;
  }

  /// Cuts an instance loose from its prefab.
  void _unpackPrefab(String id) {
    final open = _workspace.sceneHolding(id);
    final scene = open?.scene;
    final object = scene?[id];
    if (open == null || scene == null || object == null) return;

    _run(UnpackPrefab(
      sceneId: open.id,
      ids: [id, for (final child in scene.descendantsOf(id)) child.id],
      what: object.name,
    ));
  }

  /// Undo, then show what it changed, so a step in another scene is not
  /// invisible.
  void _undo() {
    final sceneId = _history.undoSceneId;
    _history.undo();
    _reveal(sceneId);
  }

  void _redo() {
    final sceneId = _history.redoSceneId;
    _history.redo();
    _reveal(sceneId);
  }

  void _reveal(String? sceneId) {
    if (sceneId == null) return;
    final scene = _workspace[sceneId]?.scene;
    if (scene == null) return;
    setState(() {
      _selected.removeWhere((id) => !scene.contains(id));
      if (_primary != null && !scene.contains(_primary!)) {
        _primary = _selected.lastOrNull;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _current;
    // Read and cleared here, so the next change decides afresh how much has
    // to be built.
    _deeply = _deep;
    _deep = false;

    return Shortcuts(
      shortcuts: {
        commandShortcut(LogicalKeyboardKey.keyZ): _UndoIntent(),
        commandShortcut(LogicalKeyboardKey.keyZ, shift: true): _RedoIntent(),
        // Windows and Linux both also expect Ctrl+Y for redo, alongside the
        // Ctrl+Shift+Z that commandShortcut above already binds; macOS has no
        // second convention to match.
        if (!commandIsMeta)
          const SingleActivator(LogicalKeyboardKey.keyY, control: true):
              _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
        const SingleActivator(LogicalKeyboardKey.backspace): _DeleteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF): _FrameIntent(),
        // The two keys a modelling tool has. Escape comes back out of the
        // geometry and G goes round the three ways of selecting it, which is
        // what somebody presses without thinking about it.
        const SingleActivator(LogicalKeyboardKey.escape): _LeaveEditIntent(),
        const SingleActivator(LogicalKeyboardKey.enter): _FinishDrawIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _FinishDrawIntent(),
        const SingleActivator(LogicalKeyboardKey.keyG): _CycleModeIntent(),
        // The brackets, which is where every tool with a brush size puts
        // them.
        const SingleActivator(LogicalKeyboardKey.bracketRight):
            _GridIntent(true),
        const SingleActivator(LogicalKeyboardKey.bracketLeft):
            _GridIntent(false),
        // Whole squares at a time, which is the one way of placing something
        // that needs no aim at all. The arrows work the floor, because that
        // is where things are arranged; shift takes them up and down, and
        // holding option does ten at once.
        ..._nudges,
        commandShortcut(LogicalKeyboardKey.keyS): _SaveIntent(),
        commandShortcut(LogicalKeyboardKey.keyS, shift: true): _SaveAsIntent(),
        commandShortcut(LogicalKeyboardKey.keyN): _NewSceneIntent(),
        commandShortcut(LogicalKeyboardKey.keyC): _CopyIntent(),
        commandShortcut(LogicalKeyboardKey.keyX): _CutIntent(),
        commandShortcut(LogicalKeyboardKey.keyV): _PasteIntent(),
        commandShortcut(LogicalKeyboardKey.keyD): _DuplicateIntent(),
      },
      child: Actions(
        actions: {
          _LeaveEditIntent: CallbackAction<_LeaveEditIntent>(onInvoke: (_) {
            // A drawing first: somebody halfway through an outline who
            // presses escape means the outline, not the geometry.
            if (_drawing.tool.isDrawing) {
              setState(_drawing.clear);
              return null;
            }
            _setContext(EditContext.object);
            return null;
          }),
          _FinishDrawIntent: CallbackAction<_FinishDrawIntent>(
            onInvoke: (_) {
              if (_drawing.tool.isDrawing) _finishDrawing();
              return null;
            },
          ),
          _NudgeIntent: CallbackAction<_NudgeIntent>(onInvoke: (intent) {
            _nudge(intent.axis, intent.squares);
            return null;
          }),
          _GridIntent: CallbackAction<_GridIntent>(onInvoke: (intent) {
            setState(() {
              _snapping.step =
                  intent.coarser ? _snapping.coarser : _snapping.finer;
              // Changing the grid turns it on: somebody reaching for the key
              // is asking about the grid, and answering with a size that does
              // nothing is the wrong answer.
              _snapping.on = true;
            });
            return null;
          }),
          _CycleModeIntent: CallbackAction<_CycleModeIntent>(onInvoke: (_) {
            // Into the geometry if not already, then round the modes: one key
            // that always does the obvious next thing.
            if (_context != EditContext.element) {
              _setContext(EditContext.element);
            } else {
              setState(() => _elementMode = _elementMode.next);
            }
            return null;
          }),
          _UndoIntent: CallbackAction<_UndoIntent>(onInvoke: (_) => _undo()),
          _RedoIntent: CallbackAction<_RedoIntent>(onInvoke: (_) => _redo()),
          _DeleteIntent: CallbackAction<_DeleteIntent>(
            onInvoke: (_) {
              // While drawing, backspace takes back the last point rather
              // than deleting what happens to be selected — which would be a
              // very unwelcome surprise halfway through an outline.
              if (_drawing.tool.isDrawing) {
                setState(_drawing.undo);
                return null;
              }
              _deleteSelection();
              return null;
            },
          ),
          _FrameIntent: CallbackAction<_FrameIntent>(
            onInvoke: (_) {
              _frameSelection();
              return null;
            },
          ),
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              _save();
              return null;
            },
          ),
          _SaveAsIntent: CallbackAction<_SaveAsIntent>(
            onInvoke: (_) {
              _saveAs();
              return null;
            },
          ),
          _NewSceneIntent: CallbackAction<_NewSceneIntent>(
            onInvoke: (_) {
              _newScene();
              return null;
            },
          ),
          _CopyIntent: CallbackAction<_CopyIntent>(onInvoke: (_) => _copy()),
          _CutIntent: CallbackAction<_CutIntent>(onInvoke: (_) => _cut()),
          _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) => _paste()),
          _DuplicateIntent:
              CallbackAction<_DuplicateIntent>(onInvoke: (_) => _duplicate()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: OrbisColors.ground,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  project: widget.project,
                  playing: _playing,
                  history: _history,
                  dirty: _anyUnsaved,
                  onPlay: () => setState(() => _playing = !_playing),
                  onClose: widget.onClose,
                  onAdd: _add,
                  onAddShape: _addShape,
                  onSave: _save,
                  onSaveAs: _saveAs,
                  onNewScene: () => _newScene(),
                  layout: _layout,
                  onLayout: _relayout,
                  onOpenInCode: _openInCode,
                  onReveal: () {
                    final problem =
                        CodeEditor.reveal(widget.project.directory);
                    if (problem != null) _say(problem);
                  },
                  onUndo: _undo,
                  onRedo: _redo,
                  selectionCount: _selected.length,
                  clipboard: _clipboardLabel,
                  onCopy: _copy,
                  onCut: _cut,
                  onPaste: _paste,
                  onDuplicate: _duplicate,
                ),
                // The panels, arranged as the layout says. What is where is
                // data — saved with the project, put back exactly, and
                // changed by dragging a tab rather than by editing this.
                Expanded(
                  child: DockView(
                    layout: _layout,
                    panel: _buildPanel,
                    onChanged: _relayout,
                  ),
                ),
                _StatusBar(
                  objects: open?.scene?.length ?? 0,
                  message: _history.undoLabel == null
                      ? 'Ready'
                      : 'Last change: ${_history.undoLabel}',
                  file: open == null
                      ? 'No scene loaded'
                      : (open.path == null
                          ? '${open.title} (unsaved)'
                          : _assets.relative(open.path!)),
                  dirty: open != null && _isUnsaved(open),
                  rate: _frames.fps,
                  frameMs: _frames.fps == null
                      ? null
                      : (_frames.gpuBound
                          ? _frames.rasterMs
                          : _frames.buildMs),
                  gpuBound: _frames.gpuBound,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UndoIntent extends Intent {}

class _RedoIntent extends Intent {}

class _DeleteIntent extends Intent {}

class _FrameIntent extends Intent {}

class _SaveIntent extends Intent {}

class _SaveAsIntent extends Intent {}

class _NewSceneIntent extends Intent {}

class _CopyIntent extends Intent {}

class _CutIntent extends Intent {}

class _PasteIntent extends Intent {}

class _DuplicateIntent extends Intent {}

/// The bar between the viewport and the project browser.
class _Splitter extends StatefulWidget {
  const _Splitter({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onVerticalDragUpdate: (details) => widget.onDrag(details.delta.dy),
        child: Container(
          height: 6,
          color: _hovering ? OrbisColors.line : Colors.transparent,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.project,
    required this.playing,
    required this.history,
    required this.dirty,
    required this.onPlay,
    required this.onClose,
    required this.onAdd,
    required this.onAddShape,
    required this.onSave,
    required this.onSaveAs,
    required this.onNewScene,
    required this.onOpenInCode,
    required this.onReveal,
    required this.layout,
    required this.onLayout,
    required this.onUndo,
    required this.onRedo,
    required this.selectionCount,
    required this.clipboard,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onDuplicate,
  });

  final Project project;
  final bool playing;
  final History history;
  final bool dirty;
  final VoidCallback onPlay;
  final VoidCallback onClose;
  final ValueChanged<ObjectKind> onAdd;
  final ValueChanged<ShapeKind> onAddShape;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;

  final VoidCallback onNewScene;
  final VoidCallback onOpenInCode;
  final VoidCallback onReveal;

  /// How the panels are arranged, and how to change it.
  final DockLayout layout;
  final ValueChanged<DockLayout> onLayout;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final int selectionCount;

  /// What is on the clipboard, or empty for nothing.
  final String clipboard;

  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          OrbisButton(
            label: project.name,
            icon: Icons.chevron_left,
            tone: ButtonTone.quiet,
            onPressed: onClose,
          ),
          const SizedBox(width: Space.md),
          _SceneMenu(
            dirty: dirty,
            onSave: onSave,
            onSaveAs: onSaveAs,
            onNewScene: onNewScene,
            onOpenInCode: onOpenInCode,
            onReveal: onReveal,
          ),
          const SizedBox(width: Space.xs),
          _AddMenu(onAdd: onAdd, onAddShape: onAddShape),
          const SizedBox(width: Space.xs),
          _EditMenu(
            selectionCount: selectionCount,
            clipboard: clipboard,
            onCopy: onCopy,
            onCut: onCut,
            onPaste: onPaste,
            onDuplicate: onDuplicate,
          ),
          const SizedBox(width: Space.xs),
          _ViewMenu(
            layout: layout,
            onLayout: onLayout,
          ),
          const SizedBox(width: Space.md),
          // Labelled with what they would undo, so the tooltip answers the
          // question somebody actually has before they press it.
          _TransportButton(
            icon: Icons.undo,
            tooltip: history.undoLabel == null
                ? 'Nothing to undo'
                : 'Undo ${history.undoLabel}',
            active: false,
            enabled: history.canUndo,
            onTap: onUndo,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.redo,
            tooltip: history.redoLabel == null
                ? 'Nothing to redo'
                : 'Redo ${history.redoLabel}',
            active: false,
            enabled: history.canRedo,
            onTap: onRedo,
          ),
          const Spacer(),
          // Transport in the centre, where it is in every editor that has one,
          // because muscle memory is worth more than novelty here.
          _TransportButton(
            icon: playing ? Icons.pause : Icons.play_arrow,
            tooltip: playing ? 'Pause' : 'Play',
            active: playing,
            onTap: onPlay,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.stop,
            tooltip: 'Stop',
            active: false,
            onTap: () {},
          ),
          const Spacer(),
          Text('pre-alpha', style: OrbisText.caption),
        ],
      ),
    );
  }
}

class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final bool enabled;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 32,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? OrbisColors.emberWash
                  : (_hovering && widget.enabled
                      ? OrbisColors.raised
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: !widget.enabled
                  ? OrbisColors.line
                  : (widget.active
                      ? OrbisColors.ember
                      : (_hovering ? OrbisColors.ink : OrbisColors.inkMid)),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.objects,
    required this.message,
    required this.file,
    required this.dirty,
    this.rate,
    this.frameMs,
    this.gpuBound = false,
  });

  final int objects;
  final String message;
  final String file;
  final bool dirty;

  /// Frames a second, or null before there has been anything to measure.
  final double? rate;

  /// How long the slower half of a frame takes, and which half it is.
  final double? frameMs;
  final bool gpuBound;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(top: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              style: OrbisText.caption.copyWith(fontSize: 11),
            ),
          ),
          const Spacer(),
          Text(
            dirty ? '$file •' : file,
            style: OrbisText.mono.copyWith(
              fontSize: 11,
              color: dirty ? OrbisColors.ember : OrbisColors.inkDim,
            ),
          ),
          const SizedBox(width: Space.lg),
          Text('$objects objects', style: OrbisText.mono.copyWith(fontSize: 11)),
          const SizedBox(width: Space.lg),
          Text(
            rate == null ? '— fps' : '${rate!.round()} fps',
            style: OrbisText.mono.copyWith(
              fontSize: 11,
              // Below about fifty a frame is late often enough to feel it.
              color: rate != null && rate! < 50
                  ? OrbisColors.warn
                  : OrbisColors.inkDim,
            ),
          ),
          if (frameMs != null) ...[
            const SizedBox(width: Space.sm),
            Text(
              // Which half of the frame the time went in, because "slow" and
              // "slow at what" are different questions.
              '${frameMs!.toStringAsFixed(1)} ms ${gpuBound ? "gpu" : "cpu"}',
              style: OrbisText.mono.copyWith(
                fontSize: 11,
                color: OrbisColors.inkDim,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Add menu.
class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.onAdd, required this.onAddShape});

  final ValueChanged<ObjectKind> onAdd;

  /// Shapes are their own submenu: there are seven of them and they are the
  /// thing somebody reaches for most while blocking a level out.
  final ValueChanged<ShapeKind> onAddShape;

  static const _items = [
    // Not 'Cube': it is an object that draws a cube until it is given a mesh
    // to draw instead, and there is a real cube one submenu above.
    (ObjectKind.mesh, 'Mesh object', Icons.view_in_ar_outlined),
    (ObjectKind.light, 'Light', Icons.wb_sunny_outlined),
    (ObjectKind.camera, 'Camera', Icons.videocam_outlined),
    (ObjectKind.group, 'Group', Icons.folder_outlined),
    (ObjectKind.weather, 'Weather', Icons.cloud_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        SubmenuButton(
          menuStyle: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.panel),
                side: const BorderSide(color: OrbisColors.line),
              ),
            ),
          ),
          leadingIcon: const Icon(Icons.category_outlined,
              size: 14, color: OrbisColors.inkMid),
          menuChildren: [
            for (final shape in ShapeKind.values)
              MenuItemButton(
                onPressed: () => onAddShape(shape),
                child: Text(shape.label, style: OrbisText.label),
              ),
          ],
          child: Text('Shape', style: OrbisText.label),
        ),
        const Divider(height: 9, color: OrbisColors.line),
        for (final (kind, label, icon) in _items)
          MenuItemButton(
            onPressed: () => onAdd(kind),
            leadingIcon: Icon(icon, size: 14, color: OrbisColors.inkMid),
            child: Text(label, style: OrbisText.label),
          ),
      ],
      builder: (context, controller, child) => OrbisButton(
        label: 'Add',
        icon: Icons.add,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// New, Save and Save As.
class _SceneMenu extends StatelessWidget {
  const _SceneMenu({
    required this.dirty,
    required this.onSave,
    required this.onSaveAs,
    required this.onNewScene,
    required this.onOpenInCode,
    required this.onReveal,
  });

  final bool dirty;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;

  final VoidCallback onNewScene;

  /// Opens the project folder in whatever code editor is installed.
  final VoidCallback onOpenInCode;

  /// Shows the project folder in the desktop's file browser.
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: onNewScene,
          leadingIcon: const Icon(Icons.note_add_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('New scene', style: OrbisText.label),
        ),
        MenuItemButton(
          onPressed: onSave,
          leadingIcon: const Icon(Icons.save_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Save', style: OrbisText.label),
        ),
        MenuItemButton(
          onPressed: onSaveAs,
          leadingIcon: const Icon(Icons.drive_file_move_outline,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Save as…', style: OrbisText.label),
        ),
        const Divider(height: 9, color: OrbisColors.line),
        MenuItemButton(
          onPressed: onOpenInCode,
          leadingIcon: const Icon(Icons.code,
              size: 14, color: OrbisColors.inkMid),
          // Named after what is installed, so it says where it is going
          // rather than promising an editor that is not there.
          child: Text(
            'Open project in ${CodeEditor.available ?? 'VS Code'}',
            style: OrbisText.label,
          ),
        ),
        MenuItemButton(
          onPressed: onReveal,
          leadingIcon: const Icon(Icons.folder_open_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text(
            Platform.isMacOS ? 'Show in Finder' : 'Show project folder',
            style: OrbisText.label,
          ),
        ),
      ],
      builder: (context, controller, child) => OrbisButton(
        // The dot is the unsaved marker, in the place somebody looks for it.
        label: dirty ? 'Scene •' : 'Scene',
        icon: Icons.description_outlined,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Cut, copy, paste and duplicate.
///
/// Worth a menu rather than only shortcuts: copying between scenes is the
/// only way to move an object from one to another, and nobody discovers a
/// keystroke that is not written down anywhere.
class _EditMenu extends StatelessWidget {
  const _EditMenu({
    required this.selectionCount,
    required this.clipboard,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onDuplicate,
  });

  final int selectionCount;
  final String clipboard;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        _item(
          selectionCount > 1 ? 'Cut $selectionCount objects' : 'Cut',
          commandShortcutLabel('X'),
          Icons.content_cut,
          selectionCount > 0 ? onCut : null,
        ),
        _item(
          selectionCount > 1 ? 'Copy $selectionCount objects' : 'Copy',
          commandShortcutLabel('C'),
          Icons.content_copy,
          selectionCount > 0 ? onCopy : null,
        ),
        _item(
          clipboard.isEmpty ? 'Paste' : 'Paste $clipboard',
          commandShortcutLabel('V'),
          Icons.content_paste,
          onPaste,
        ),
        _item(
          'Duplicate',
          commandShortcutLabel('D'),
          Icons.copy_all,
          selectionCount > 0 ? onDuplicate : null,
        ),
      ],
      builder: (context, controller, child) => OrbisButton(
        label: 'Edit',
        icon: Icons.content_copy,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _item(
    String label,
    String shortcut,
    IconData icon,
    VoidCallback? onPressed,
  ) {
    final enabled = onPressed != null;
    return MenuItemButton(
      onPressed: onPressed,
      leadingIcon: Icon(
        icon,
        size: 14,
        color: enabled ? OrbisColors.inkMid : OrbisColors.line,
      ),
      trailingIcon: Text(
        shortcut,
        style: OrbisText.mono.copyWith(
          fontSize: 11,
          color: enabled ? OrbisColors.inkDim : OrbisColors.line,
        ),
      ),
      child: Text(
        label,
        style: OrbisText.label.copyWith(
          color: enabled ? OrbisColors.ink : OrbisColors.line,
        ),
      ),
    );
  }
}

/// Where the panels are, and whether they can be moved.
///
/// An arrangement somebody has settled into is worth keeping, and a layout
/// that can always be pulled apart eventually is — by a drag that was meant to
/// be something else. So it locks. And the two arrangements worth one press
/// are here, because building a four-view layout by dragging is a minute of
/// somebody's time every time they want one.
class _ViewMenu extends StatelessWidget {
  const _ViewMenu({required this.layout, required this.onLayout});

  final DockLayout layout;
  final ValueChanged<DockLayout> onLayout;

  /// The panels that can be opened, in a sensible order.
  static const _openable = [
    (PanelKind.outliner, 'outliner'),
    (PanelKind.inspector, 'inspector'),
    (PanelKind.viewport, 'scene'),
    (PanelKind.game, 'game'),
    (PanelKind.project, 'project'),
    (PanelKind.console, 'console'),
    (PanelKind.modelling, 'modelling'),
    (PanelKind.uvs, 'uvs'),
  ];

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(OrbisColors.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.panel),
            side: const BorderSide(color: OrbisColors.line),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => onLayout(
            layout.copyWith(locked: !layout.locked),
          ),
          leadingIcon: Icon(
            layout.locked ? Icons.lock_outline : Icons.lock_open_outlined,
            size: 14,
            color: layout.locked ? OrbisColors.ember : OrbisColors.inkMid,
          ),
          child: Text(
            layout.locked ? 'Unlock the layout' : 'Lock the layout',
            style: OrbisText.label,
          ),
        ),
        const Divider(height: 9, color: OrbisColors.line),
        MenuItemButton(
          onPressed: () =>
              onLayout(DockLayout.standard().copyWith(locked: layout.locked)),
          leadingIcon: const Icon(Icons.view_quilt_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('One view', style: OrbisText.label),
        ),
        MenuItemButton(
          onPressed: () =>
              onLayout(DockLayout.fourViews().copyWith(locked: layout.locked)),
          leadingIcon: const Icon(Icons.grid_view_outlined,
              size: 14, color: OrbisColors.inkMid),
          child: Text('Four views', style: OrbisText.label),
        ),
        const Divider(height: 9, color: OrbisColors.line),
        // Opening one that is already open shows it rather than adding a
        // second, which is why every one of these can be pressed at any time.
        for (final (kind, id) in _openable)
          MenuItemButton(
            onPressed: () => onLayout(
              layout.add(DockPanel(id: id, kind: kind)),
            ),
            leadingIcon: Icon(
              kind.icon,
              size: 14,
              color: layout.holds(id)
                  ? OrbisColors.ember
                  : OrbisColors.inkMid,
            ),
            child: Text(kind.label, style: OrbisText.label),
          ),
      ],
      builder: (context, controller, child) => OrbisButton(
        label: layout.locked ? 'View •' : 'View',
        icon: Icons.dashboard_outlined,
        tone: ButtonTone.quiet,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Back out of a mesh, to the object it belongs to.
class _LeaveEditIntent extends Intent {
  const _LeaveEditIntent();
}

/// Round the three ways of selecting part of a mesh.
/// Makes the grid coarser or finer.
class _GridIntent extends Intent {
  const _GridIntent(this.coarser);

  final bool coarser;
}

/// Finishes whatever is being drawn.
/// Moves the selection by whole squares.
class _NudgeIntent extends Intent {
  const _NudgeIntent(this.axis, this.squares);

  /// Which way, as a unit vector.
  final Vector3 axis;

  /// How many squares, signed.
  final int squares;
}

class _FinishDrawIntent extends Intent {
  const _FinishDrawIntent();
}

class _CycleModeIntent extends Intent {
  const _CycleModeIntent();
}
