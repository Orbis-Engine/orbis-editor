import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../theme/orbis_theme.dart';
import 'commands.dart';
import 'gizmo.dart';
import 'snapping.dart';
import 'history.dart';
import 'mesh_edit.dart';
import 'scene.dart';
import 'ui_canvas.dart';
import 'workspace.dart';

/// Where the viewer is standing, in orbit terms.
///
/// Orbit rather than free flight, because an editor viewport is nearly always
/// used to look *at* something, and yaw/pitch/distance cannot be driven into a
/// state you have to reset your way out of.
class OrbitCamera {
  OrbitCamera({
    this.yaw = 0.6,
    this.pitch = 0.35,
    this.distance = 12,
    this.fieldOfView = 50,
    Vector3? target,
  }) : target = target ?? Vector3(0, 0.5, 0);

  final double yaw;
  final double pitch;
  final double distance;
  final double fieldOfView;

  /// What the camera turns around and looks at.
  final Vector3 target;

  /// Pitch is clamped just short of straight up and straight down: at exactly
  /// vertical the up vector and the view direction are parallel and the view
  /// matrix collapses, which shows up as the image flipping.
  static const _pitchLimit = math.pi / 2 - 0.02;

  OrbitCamera orbit(Offset delta) => OrbitCamera(
        yaw: yaw - delta.dx * 0.008,
        pitch: (pitch + delta.dy * 0.008).clamp(-_pitchLimit, _pitchLimit),
        distance: distance,
        fieldOfView: fieldOfView,
        target: target,
      );

  OrbitCamera zoom(double amount) => OrbitCamera(
        yaw: yaw,
        pitch: pitch,
        distance: (distance * math.exp(amount * 0.0016)).clamp(1.5, 200.0),
        fieldOfView: fieldOfView,
        target: target,
      );

  /// The three axes the camera sees along, in world space.
  ///
  /// Right, up and forward — the basis every movement here is expressed in,
  /// because "left" means left of where somebody is looking and not left of
  /// the world.
  ({Vector3 right, Vector3 up, Vector3 forward}) get basis {
    final right = Vector3(math.cos(yaw), 0, -math.sin(yaw));
    final up = Vector3(
      -math.sin(yaw) * math.sin(pitch),
      math.cos(pitch),
      -math.cos(yaw) * math.sin(pitch),
    );
    // Towards what the camera is looking at, which is the way the eye is
    // offset from the target, reversed.
    final forward = Vector3(
      -math.sin(yaw) * math.cos(pitch),
      -math.sin(pitch),
      -math.cos(yaw) * math.cos(pitch),
    );
    return (right: right, up: up, forward: forward);
  }

  /// Turns on the spot, without moving.
  ///
  /// What [orbit] does not do: orbiting swings the eye around a fixed target,
  /// and looking around keeps the eye still and moves the target. From inside
  /// a room the difference is the whole difference between the two.
  OrbitCamera looking(Offset delta) {
    final was = toRenderCamera().position;
    final nextYaw = yaw - delta.dx * 0.005;
    final nextPitch =
        (pitch + delta.dy * 0.005).clamp(-_pitchLimit, _pitchLimit);

    // The target is put back behind the new direction so the eye stays exactly
    // where it was. Everything else in the editor works in orbit terms —
    // framing, panning, the gizmos — and this keeps it that way rather than
    // giving the camera a second mode with its own maths.
    final horizontal = distance * math.cos(nextPitch);
    return OrbitCamera(
      yaw: nextYaw,
      pitch: nextPitch,
      distance: distance,
      fieldOfView: fieldOfView,
      target: Vector3(
        was.x - horizontal * math.sin(nextYaw),
        was.y - distance * math.sin(nextPitch),
        was.z - horizontal * math.cos(nextYaw),
      ),
    );
  }

  /// Moves the camera itself, along the axes it is looking down.
  ///
  /// [along] is right, up and forward in metres. Both the eye and what it
  /// looks at move together, which is what flying is: the view does not swing
  /// around anything, it goes somewhere.
  OrbitCamera flying(Vector3 along) {
    final axes = basis;
    return OrbitCamera(
      yaw: yaw,
      pitch: pitch,
      distance: distance,
      fieldOfView: fieldOfView,
      target: target +
          axes.right * along.x +
          axes.up * along.y +
          axes.forward * along.z,
    );
  }

  /// Slides the camera sideways, keeping its angle. What a middle-drag does.
  OrbitCamera pan(Offset delta) {
    // Scaled by distance so panning feels the same close up and far away, and
    // moved along the camera's own axes rather than the world's.
    final scale = distance * 0.0016;
    final right = Vector3(math.cos(yaw), 0, -math.sin(yaw));
    final up = Vector3(
      -math.sin(yaw) * math.sin(pitch),
      math.cos(pitch),
      -math.cos(yaw) * math.sin(pitch),
    );

    return OrbitCamera(
      yaw: yaw,
      pitch: pitch,
      distance: distance,
      fieldOfView: fieldOfView,
      target: target - right * (delta.dx * scale) + up * (delta.dy * scale),
    );
  }

  /// Points the camera at a box, far enough back to see all of it.
  ///
  /// Keeps the angle it was already at, because framing something should not
  /// also spin the view — somebody pressing F wants the thing on screen, not a
  /// different shot of it.
  OrbitCamera framing({required Vector3 centre, required double radius}) {
    // Fitted to the vertical field of view with room to spare, and floored so
    // framing a flat or tiny object does not put the camera inside it.
    final fitted = radius / math.tan(radians(fieldOfView) / 2) * 1.6;

    return OrbitCamera(
      yaw: yaw,
      pitch: pitch,
      distance: fitted.clamp(1.5, 200.0),
      fieldOfView: fieldOfView,
      target: centre.clone(),
    );
  }

  OrbisCamera toRenderCamera() {
    final horizontal = distance * math.cos(pitch);
    return OrbisCamera(
      position: Vector3(
        target.x + horizontal * math.sin(yaw),
        target.y + distance * math.sin(pitch),
        target.z + horizontal * math.cos(yaw),
      ),
      target: target.clone(),
      fieldOfView: fieldOfView,
    );
  }
}

/// The 3D view.
///
/// On macOS this is Filament compositing into a Flutter texture. Everywhere
/// else it is an honest placeholder — a viewport that pretends to work on a
/// platform where the renderer does not exist is worse than one that says so.
// Named SceneViewport rather than Viewport: Flutter already exports a
// Viewport, and a name that collides with the framework's is one somebody has
// to disambiguate at every call site.
class SceneViewport extends StatefulWidget {
  const SceneViewport({
    super.key,
    required this.workspace,
    required this.camera,
    required this.onCameraChanged,
    this.editing,
    this.elementMode = ElementMode.face,
    this.elementSelection = nothingSelected,
    this.onPickElement,
    this.onDragElements,
    this.onSelectElements,
    this.seeThroughElements = false,
    required this.snapping,
    this.onSnapping,
    this.geometryOf,
    this.interface,
    this.showInterface = true,
    this.onToggleInterface,
    this.previewOf,
    this.selected = const {},
    this.onDropAsset,
    this.projectRoot,
    this.onSceneNotes,
    this.onClock,
    this.primary,
    this.history,
    this.onPick,
  });

  /// Only the loaded scene is drawn. The others are names and paths until
  /// somebody opens them.
  final Workspace workspace;

  /// Owned by the shell rather than here, so pressing F anywhere can frame the
  /// selection and so the view could later be saved with the scene.
  final OrbitCamera camera;

  final ValueChanged<OrbitCamera> onCameraChanged;

  /// The objects to outline. All of them, so a multiple selection is visible
  /// in the viewport rather than only in the tree.
  final Set<String> selected;

  /// Called when a file is dragged in from the project browser.
  final ValueChanged<String>? onDropAsset;

  /// Where mesh references are resolved from.
  final String? projectRoot;

  /// Called with anything the scene asked for that the renderer could not
  /// give: a mesh that would not load, a light it has no room to shade.
  final ValueChanged<Map<String, String>>? onSceneNotes;

  /// The object whose parts are being edited, with its geometry and where it
  /// stands, or null when the whole object is what is selected.
  ///
  /// Passed in already resolved: the viewport draws what it is given and does
  /// not decide what is being edited, which is what lets four of them show the
  /// same edit from four angles.
  final ({SceneObject object, Mesh mesh, Matrix4 transform})? editing;

  final ElementMode elementMode;
  final ElementSelection elementSelection;

  /// Called when a click lands on a vertex, an edge or a face — or on none of
  /// them, which is how somebody clears a selection.
  final void Function(Object? what, {required bool add})? onPickElement;

  /// Called with everything a marquee drew round.
  ///
  /// A list rather than one at a time, so a box over forty vertices is one
  /// step and not forty — and so an empty box clears the selection, which is
  /// what somebody drawing on nothing means by it.
  final void Function(List<Object> what, {required bool add})?
      onSelectElements;

  /// Whether what is behind the surface can be picked as well.
  final bool seeThroughElements;

  /// What a drag lands on. Passed in rather than owned here, so four views of
  /// one scene agree about the grid.
  final Snapping snapping;

  /// Called when the chip or a key changes it.
  final ValueChanged<Snapping>? onSnapping;

  /// Called with a mesh a drag has changed, and what should be selected after.
  ///
  /// The whole mesh rather than the change, for the same reason every other
  /// geometry edit is: describing a drag as a diff is more code than the drag.
  /// [merge] is set on every frame after the first, so a gesture that produces
  /// a hundred of these is one step to undo.
  final void Function(
    Mesh mesh,
    ElementSelection selection,
    String what, {
    required bool merge,
  })? onDragElements;

  /// Where an object's built geometry was written, if anywhere.
  ///
  /// Passed in rather than worked out here: the file is written by whatever
  /// owns the project folder, and a viewport that wrote files would be four
  /// viewports writing the same one four times over.
  final String? Function(SceneObject)? geometryOf;

  /// The interface a canvas object in the scene shows, already read.
  ///
  /// Read by the shell rather than here: the viewport draws what it is given
  /// and does not open files, which is what keeps it testable without a
  /// project on disk.
  final UiDocument? interface;

  /// Whether to draw the interface at all. Off while somebody is arranging
  /// the scene behind it and does not want a full-screen heads-up display
  /// over everything they are trying to look at.
  final bool showInterface;

  /// Turns that on and off. This is a view setting and not a scene edit —
  /// hiding the canvas object is what hides the interface in the game.
  final VoidCallback? onToggleInterface;

  /// What a selected camera sees, shown in the corner.
  ///
  /// Built by the shell rather than here, so the viewport does not have to
  /// know how a game view is put together — and so the preview and the game
  /// panel are the same widget rather than two things that agree for now.
  final Widget Function(SceneObject camera)? previewOf;

  /// The one of the selection the handles sit on, and whose transform a drag
  /// writes first. The others follow it.
  final String? primary;

  /// Where a drag's changes go. Without it the viewport can still show and
  /// select, but nothing in it can be moved.
  final History? history;

  /// Called when something in the scene is clicked, or nothing is.
  ///
  /// `add` is set when a modifier was held, which the shell reads as adding to
  /// or taking away from what is already selected rather than replacing it.
  final void Function(String? id, {required bool add})? onPick;

  /// Called a few times a second while a scene is animating, so the panels
  /// that are not the viewport can keep up.
  ///
  /// A few, not sixty: the tree and the inspector show the hour and the name
  /// of whatever is in the sky, and those change slowly enough to read. The
  /// viewport draws every frame; the rest of the editor does not have to.
  final VoidCallback? onClock;

  @override
  State<SceneViewport> createState() => _SceneViewportState();
}

class _SceneViewportState extends State<SceneViewport>
    with SingleTickerProviderStateMixin {
  Offset? _dragAnchor;

  /// What a drag on a handle does. Kept here rather than in the shell because
  /// it is a property of how somebody is working in this view, not of the
  /// document — it is not saved and it is not undone.
  GizmoMode _mode = GizmoMode.move;

  /// The size of the surface, as laid out. Needed to turn a pointer position
  /// into a ray, and only known once the viewport has been given a box.
  Size? _surface;

  GizmoAxis? _hovered;
  GizmoAxis? _dragging;

  /// Where on the handle the drag began, in world space, and what every
  /// object being dragged looked like before it started.
  Vector3? _grabbed;
  final Map<String, Vector3> _before = {};
  final Map<String, Matrix3> _beforeWorld = {};

  /// The mesh as it stood when an element drag began, and which of its corners
  /// are moving.
  ///
  /// Kept whole and moved from, rather than moved a little each frame: a drag
  /// applied incrementally accumulates every rounding error it makes, and a
  /// slow drag out and back does not come home.
  Mesh? _beforeMesh;
  List<int> _movingPoints = const [];

  /// What the selection should be while an element drag is running. Set when a
  /// drag extrudes, because the faces that come out of an extrude are not the
  /// ones that went in.
  ElementSelection? _draggingSelection;

  /// Whether anything has actually been written yet this drag, so the first
  /// change starts an undo step and the rest fold into it.
  bool _dragStarted = false;

  /// The scene the handles are working in.
  ///
  /// Whichever holds what is selected: the open scene, or the shared set. A
  /// manager put in the shared set is dragged the same way everything else is.
  EditorScene? get _editing {
    final id = widget.primary;
    if (id == null) return widget.workspace.loaded?.scene;
    return widget.workspace.sceneHolding(id)?.scene;
  }

  /// The id of that scene, for the command a drag runs.
  String? get _editingId {
    final id = widget.primary;
    if (id == null) return widget.workspace.loaded?.id;
    return widget.workspace.sceneHolding(id)?.id;
  }

  /// The gizmo as it stands, or null when there is nothing to put it on.
  Gizmo? get _gizmo {
    final scene = _editing;
    final id = widget.primary;
    final size = _surface;
    if (scene == null || id == null || size == null || size.isEmpty) {
      return null;
    }
    final object = scene[id];
    if (object == null || object.kind == ObjectKind.scene) return null;

    return Gizmo(
      mode: _mode,
      // While parts of a mesh are being edited the handles belong to those
      // parts, not to the object round them: dragging a face should move the
      // face. With nothing selected there is nothing to put them on, and
      // falling back to the object would make an empty selection look like a
      // whole-object move waiting to happen.
      pivot: _elementPivot ?? scene.worldOf(id).getTranslation(),
      projection: ViewportProjection(camera: widget.camera, size: size),
    );
  }

  /// Whether a drag right now moves parts of a mesh rather than objects.
  bool get _editingElements =>
      widget.editing != null && !_selectedElements.isEmpty;

  /// The selection a drag is working on — the one that came in, or the one an
  /// extrude made part-way through the gesture.
  ElementSelection get _selectedElements =>
      _draggingSelection ?? widget.elementSelection;

  /// Where the handles sit while editing elements, in the world.
  Vector3? get _elementPivot {
    final editing = widget.editing;
    if (editing == null) return null;
    final middle = _selectedElements.pivotIn(editing.mesh);
    if (middle == null) return null;
    return editing.transform.transformed3(middle);
  }

  /// A grid step as somebody would say it: millimetres below a centimetre,
  /// centimetres below a metre.
  static String _gridLabel(double step) {
    if (step < 0.01) return '${(step * 1000).round()}mm';
    if (step < 1) return '${(step * 100).round()}cm';
    return '${step.toStringAsFixed(step % 1 == 0 ? 0 : 1)}m';
  }

  /// The grid as it applies right now.
  ///
  /// Held down suspends it rather than switching it on, because somebody who
  /// wants a shelf half a millimetre off wants it for one drag and not for
  /// the afternoon.
  Snapping get _snap {
    final held = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed;
    if (!held) return widget.snapping;
    return Snapping(on: false, step: widget.snapping.step, angle: widget.snapping.angle);
  }

  /// A world-space movement, in the object's own frame.
  ///
  /// A shift means something different inside an object that is turned or
  /// scaled, and a face dragged a metre along the world's X on an object
  /// turned ninety degrees should still end up a metre along the world's X.
  Vector3 _intoObject(Vector3 world, Matrix4 transform) {
    final inverse = Matrix4.inverted(transform);
    return inverse.transformed3(world) - inverse.transformed3(Vector3.zero());
  }

  /// Everything a drag moves: the whole selection, or just the one the handles
  /// are on when the selection is empty for some reason.
  List<String> get _targets {
    final scene = _editing;
    if (scene == null) return const [];
    final ids = widget.selected.isEmpty
        ? [if (widget.primary != null) widget.primary!]
        : widget.selected.toList();
    // Only what lives in the same scene as the one the handles are on: a
    // drag is one command, and a command changes one scene.
    return [
      for (final id in ids)
        if (scene[id] != null && scene[id]!.kind != ObjectKind.scene) id,
    ];
  }

  void _hover(Offset local) {
    final axis = _gizmo?.axisAt(local);
    if (axis == _hovered) return;
    setState(() => _hovered = axis);
  }

  /// Picks whatever is under the pointer, or nothing.
  void _pick(Offset local) {
    final scene = widget.workspace.loaded?.scene;
    final size = _surface;
    if (scene == null || size == null || size.isEmpty) return;

    final ray = ViewportProjection(camera: widget.camera, size: size)
        .rayThrough(local);
    // The open scene first, then what every scene has. A shared prop standing
    // in front of a scene's own is the uncommon way round, and picking the
    // thing somebody is working on when both are under the pointer is the
    // better answer of the two.
    final hit = scene.objectAlong(ray.origin, ray.direction) ??
        widget.workspace.shared.objectAlong(ray.origin, ray.direction);

    final modifiers = {
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    };
    final held = HardwareKeyboard.instance.logicalKeysPressed
        .any(modifiers.contains);

    widget.onPick?.call(hit, add: held);
  }

  /// Takes hold of a handle, remembering where everything was.
  bool _grab(Offset local) {
    final gizmo = _gizmo;
    final scene = _editing;
    final axis = gizmo?.axisAt(local);
    if (gizmo == null || scene == null || axis == null) return false;
    if (widget.history == null) return false;

    final grabbed = _mode == GizmoMode.move
        ? gizmo.pointOnAxis(local, axis)
        : gizmo.pointOnRing(local, axis);
    // The pointer is on the handle but the plane behind it is edge-on to the
    // camera, so there is no sensible place to have grabbed. Better to orbit
    // than to teleport whatever is selected.
    if (grabbed == null) return false;

    if (_editingElements) {
      if (!_grabElements()) return false;
      setState(() {
        _dragging = axis;
        _grabbed = grabbed;
      });
      return true;
    }

    _before.clear();
    _beforeWorld.clear();
    for (final id in _targets) {
      final object = scene[id]!;
      _before[id] = _mode == GizmoMode.move
          ? object.position.clone()
          : object.rotation.clone();
      _beforeWorld[id] = scene.worldOf(id).getRotation();
    }

    setState(() {
      _dragging = axis;
      _grabbed = grabbed;
    });
    return true;
  }

  /// Takes hold of the parts of a mesh.
  ///
  /// Holding shift extrudes first and then drags what came out, which is the
  /// move a modelling tool is built around: a doorway, a chimney and a ledge
  /// are all one face pulled out. Extruding by nothing and then moving is
  /// exactly right — the walls are made where the face was, and the drag
  /// takes the face away from them.
  bool _grabElements() {
    final editing = widget.editing;
    if (editing == null || widget.onDragElements == null) return false;

    var selection = widget.elementSelection.copy();
    final mesh = editing.mesh.copy();
    var extruded = false;

    final wantsExtrude = _mode == GizmoMode.move &&
        widget.elementMode == ElementMode.face &&
        HardwareKeyboard.instance.isShiftPressed &&
        selection.faces.isNotEmpty;

    if (wantsExtrude) {
      // The copy's own faces, not the ones on screen. `extrude` matches by
      // identity, and a copied mesh's faces are different objects — passing
      // the originals finds nothing and silently extrudes nothing.
      final made = mesh.extrude(selection.facesIn(mesh), 0);
      if (made.isNotEmpty) {
        final places = <int>{};
        for (var i = 0; i < mesh.faces.length; i++) {
          if (made.contains(mesh.faces[i])) places.add(i);
        }
        selection = ElementSelection(faces: places);
        extruded = true;
      }
    }

    final points = selection.pointsIn(mesh).toList();
    if (points.isEmpty) return false;

    _beforeMesh = mesh;
    _movingPoints = points;
    _draggingSelection = selection;
    _dragStarted = false;

    // The extrude is written straight away rather than waiting for the first
    // movement. Somebody who holds shift, pulls and lets go without moving has
    // still made a face, and it should be there and be undoable.
    if (extruded) {
      widget.onDragElements!(mesh.copy(), selection, 'Extrude', merge: false);
      _dragStarted = true;
    }
    return true;
  }

  /// Moves or turns the parts of a mesh, from where they were when the drag
  /// began.
  void _dragElementsTo(Offset local) {
    final gizmo = _gizmo;
    final editing = widget.editing;
    final start = _beforeMesh;
    final axis = _dragging;
    final grabbed = _grabbed;
    final report = widget.onDragElements;
    if (gizmo == null ||
        editing == null ||
        start == null ||
        axis == null ||
        grabbed == null ||
        report == null) {
      return;
    }

    final next = start.copy();
    final String what;

    if (_mode == GizmoMode.move) {
      final now = gizmo.pointOnAxis(local, axis);
      if (now == null) return;
      // Snapped in the world, where the grid is, and then taken into the
      // object's frame. Snapping after the conversion would put the grid at
      // whatever angle and scale the object happens to have.
      final shift = _snap.along(gizmo.pivot, now - grabbed + gizmo.pivot,
          axis.direction);
      next.movePoints(_movingPoints, _intoObject(shift, editing.transform));
      what = 'Move';
    } else {
      final now = gizmo.pointOnRing(local, axis);
      if (now == null) return;
      final angle = _snap.turn(gizmo.angleBetween(grabbed, now, axis));
      // Into the object's frame first, so the ring somebody grabbed in the
      // world is the axis the corners turn about inside a turned object.
      final about = start.centreOfPoints(_movingPoints);
      if (about == null) return;
      final localAxis =
          _intoObject(axis.direction, editing.transform).normalized();
      next.turnPoints(
        _movingPoints,
        Quaternion.axisAngle(localAxis, angle).asRotationMatrix(),
        about,
      );
      what = 'Turn';
    }

    report(next, _selectedElements, what, merge: _dragStarted);
    _dragStarted = true;
  }

  /// Applies the drag as it stands: one command, however many objects.
  void _dragTo(Offset local) {
    final gizmo = _gizmo;
    final scene = _editing;
    final axis = _dragging;
    final grabbed = _grabbed;
    final history = widget.history;
    final sceneId = _editingId;
    if (gizmo == null ||
        scene == null ||
        axis == null ||
        grabbed == null ||
        history == null ||
        sceneId == null) {
      return;
    }

    if (_editingElements || _beforeMesh != null) {
      _dragElementsTo(local);
      return;
    }

    final changes = <String, ({Vector3 from, Vector3 to})>{};

    if (_mode == GizmoMode.move) {
      final now = gizmo.pointOnAxis(local, axis);
      if (now == null) return;
      // From where the handle was, so a selection of several keeps its shape
      // and the one the handles are on is the one that lands on a line.
      final shift =
          _snap.along(gizmo.pivot, now - grabbed + gizmo.pivot, axis.direction);

      for (final entry in _before.entries) {
        final object = scene[entry.key];
        if (object == null) continue;
        // A world-space shift means something different inside a parent that
        // is itself turned or scaled, so it is taken into that parent's frame
        // before it is added to a local position.
        final parentId = object.parentId;
        final local = parentId == null || !scene.contains(parentId)
            ? shift
            : Matrix4.inverted(scene.worldOf(parentId)).rotated3(shift.clone());
        changes[entry.key] = (from: entry.value, to: entry.value + local);
      }
    } else {
      final now = gizmo.pointOnRing(local, axis);
      if (now == null) return;
      final angle = _snap.turn(gizmo.angleBetween(grabbed, now, axis));
      final turn =
          Quaternion.axisAngle(axis.direction, angle).asRotationMatrix();

      for (final entry in _before.entries) {
        final object = scene[entry.key];
        final was = _beforeWorld[entry.key];
        if (object == null || was == null) continue;

        // Turned about the world axis, then read back into the parent's frame.
        // Each object turns where it stands rather than orbiting the handle,
        // so a selection of several keeps its shape.
        final turned = turn * was;
        final parentId = object.parentId;
        final localRotation = parentId == null || !scene.contains(parentId)
            ? turned
            : (Matrix3.copy(scene.worldOf(parentId).getRotation())..invert()) *
                turned;

        changes[entry.key] = (
          from: entry.value,
          to: eulerDegreesOf(Matrix4.identity()..setRotation(localRotation)),
        );
      }
    }

    if (changes.isEmpty) return;
    history.run(TransformMany(
      sceneId: sceneId,
      field: _mode == GizmoMode.move
          ? TransformField.position
          : TransformField.rotation,
      what: changes.length == 1
          ? scene[changes.keys.first]!.name
          : '${changes.length} objects',
      changes: changes,
    ));
  }

  void _release() {
    if (_dragging == null) return;
    // Sealed here rather than on a timer, so the whole gesture is one step
    // however long somebody took over it.
    widget.history?.seal();
    setState(() {
      _dragging = null;
      _grabbed = null;
      _beforeMesh = null;
      _movingPoints = const [];
      _draggingSelection = null;
      _dragStarted = false;
    });
  }

  /// Drives anything in the scene that moves on its own — a day running, mist
  /// drifting.
  ///
  /// It lives here rather than in the shell so that a running clock repaints
  /// the viewport and nothing else. A ticker at the top would rebuild the
  /// outliner, the inspector and the browser sixty times a second to animate
  /// a sky none of them draw.
  late final Ticker _clock = createTicker(_tick);

  /// Where the clock had got to when it was last stopped, so pausing and
  /// starting again does not jump the sky back to the beginning.
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(SceneViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A scene loaded, unloaded, or had its cycle switched on or off.
    _syncClock();
  }

  @override
  void dispose() {
    _clock.dispose();
    _flyFocus.dispose();
    super.dispose();
  }

  /// Runs the clock only while something is actually moving.
  ///
  /// A ticker that never stops is a viewport that republishes sixty times a
  /// second to draw a scene that has not changed, and on a laptop that is a
  /// fan spinning up to animate nothing.
  void _syncClock() {
    final scene = widget.workspace.loaded?.scene;
    // Flying needs it as much as a day cycle does: the camera moves a little
    // every frame while a key is held, and without a frame there is no every.
    final wanted = _flying || (scene != null && scene.isAnimated);
    if (wanted == _clock.isActive) return;
    if (wanted) {
      _clock.start();
    } else {
      _clock.stop();
    }
  }

  // ---- flying ----

  /// The keys held down while the right button is, in view terms.
  final Set<LogicalKeyboardKey> _held = {};

  /// Where the pointer was when it last moved, while a button is held down to
  /// look around.
  Offset? _looking;

  /// Whether flying was switched on rather than held.
  ///
  /// Holding a button is fine with a mouse and awkward on a trackpad: a
  /// two-finger click held down while the other hand types WASD is a hand
  /// position nobody keeps for long. Switched on, the keys just work and the
  /// view is steered with an ordinary two-finger drag.
  bool _flyLocked = false;

  /// Metres a second. Adjusted by the wheel while flying, the way it is in
  /// every editor that has this — somebody flying across a level and somebody
  /// nudging along a wall want very different numbers, and reaching for a
  /// slider to change it means stopping.
  double _flySpeed = 8;

  final FocusNode _flyFocus = FocusNode(debugLabel: 'viewport fly');

  /// The pinch scale at the last trackpad event, so a zoom is the change
  /// rather than the total — the total restarts at one on every gesture.
  double _panZoomFrom = 1;

  /// Whether fingers are on the trackpad.
  ///
  /// Flutter hands a trackpad gesture to the pan-zoom listeners *and* turns it
  /// into an ordinary drag for the gesture recognizers, so without this both
  /// run and the second undoes the first — the view would move once and then
  /// jump back every frame of the gesture.
  bool _onTrackpad = false;

  bool get _flying => _looking != null || _flyLocked;

  // Not const: LogicalKeyboardKey defines ==, and a constant set may not hold
  // anything that does.
  static final _forwardKeys = {
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.arrowUp,
  };
  static final _backKeys = {
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.arrowDown,
  };
  static final _leftKeys = {
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.arrowLeft,
  };
  static final _rightKeys = {
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.arrowRight,
  };
  static final _upKeys = {LogicalKeyboardKey.keyE, LogicalKeyboardKey.space};
  static final _downKeys = {LogicalKeyboardKey.keyQ};

  /// Every key flying answers to, so one held down is not also passed on to
  /// whatever else is listening.
  static final _flyKeys = {
    ..._forwardKeys,
    ..._backKeys,
    ..._leftKeys,
    ..._rightKeys,
    ..._upKeys,
    ..._downKeys,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  bool _anyHeld(Set<LogicalKeyboardKey> keys) =>
      _held.any(keys.contains);

  /// Which way the keys held down add up to, in right/up/forward.
  Vector3 get _wanted {
    final along = Vector3.zero();
    if (_anyHeld(_rightKeys)) along.x += 1;
    if (_anyHeld(_leftKeys)) along.x -= 1;
    if (_anyHeld(_upKeys)) along.y += 1;
    if (_anyHeld(_downKeys)) along.y -= 1;
    if (_anyHeld(_forwardKeys)) along.z += 1;
    if (_anyHeld(_backKeys)) along.z -= 1;
    // Normalised, or holding two keys would go a metre and a half diagonally
    // for every metre going straight.
    return along.length2 == 0 ? along : along.normalized();
  }

  KeyEventResult _onFlyKey(FocusNode node, KeyEvent event) {
    // The one key that works whether or not the view is already flying.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backquote) {
      _toggleFlying();
      return KeyEventResult.handled;
    }

    if (_flying &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      setState(_stopFlying);
      _syncClock();
      return KeyEventResult.handled;
    }

    // Everything else only while flying. Otherwise W would fly the view every
    // time somebody typed a name into the inspector.
    if (!_flying) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _held.add(event.logicalKey);
    } else if (event is KeyUpEvent) {
      _held.remove(event.logicalKey);
    }

    return _flyKeys.contains(event.logicalKey)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  void _stopFlying() {
    _looking = null;
    _flyLocked = false;
    _held.clear();
  }

  /// Switches flying on or off, for the trackpad.
  void _toggleFlying() {
    setState(() {
      if (_flying) {
        _stopFlying();
      } else {
        _flyLocked = true;
        _lastFlew = _elapsed;
        _flyFocus.requestFocus();
      }
    });
    _syncClock();
  }

  /// Moves the camera for one frame of held keys.
  void _fly(Duration elapsed) {
    if (!_flying) return;

    final along = _wanted;
    if (along.length2 == 0) return;

    final seconds = (elapsed - _lastFlew).inMicroseconds / 1e6;
    _lastFlew = elapsed;
    // Clamped: a frame that took a second — a rebuild, a breakpoint — should
    // not throw the camera across the level.
    final step = seconds.clamp(0.0, 0.05);

    final fast = _held.contains(LogicalKeyboardKey.shiftLeft) ||
        _held.contains(LogicalKeyboardKey.shiftRight);
    widget.onCameraChanged(
      widget.camera.flying(along * (_flySpeed * (fast ? 4 : 1) * step)),
    );
  }

  Duration _lastFlew = Duration.zero;

  void _tick(Duration elapsed) {
    _fly(elapsed);
    _lastFlew = elapsed;

    final scene = widget.workspace.loaded?.scene;
    if (scene == null) return;
    _elapsed = elapsed;
    setState(() => scene.clock = _elapsed.inMicroseconds / 1e6);

    if (elapsed - _lastTold >= _tellInterval) {
      _lastTold = elapsed;
      widget.onClock?.call();
    }
  }

  Duration _lastTold = Duration.zero;
  static const Duration _tellInterval = Duration(milliseconds: 250);

  /// The preview to show, or null when nothing that has a view is selected.
  Widget? get _preview {
    final make = widget.previewOf;
    if (make == null || widget.selected.length != 1) return null;

    final scene = widget.workspace.loaded?.scene;
    final object = scene?[widget.selected.first];
    if (object == null || object.kind != ObjectKind.camera) return null;
    if (!object.visible || !scene!.isShown(object.id)) return null;

    return make(object);
  }

  /// The part of the mesh the pointer is over, while editing one.
  Object? _hoveredElement;

  MeshPicker _pickerFor(
    ({SceneObject object, Mesh mesh, Matrix4 transform}) editing,
    Size surface,
  ) =>
      MeshPicker(
        mesh: editing.mesh,
        transform: editing.transform,
        projection: ViewportProjection(camera: widget.camera, size: surface),
        seeThrough: widget.seeThroughElements,
      );

  /// Where a marquee started and where it has reached, in local pixels.
  Offset? _boxFrom;
  Offset? _boxTo;

  /// The marquee as a rectangle, or null when there is not one.
  Rect? get _box {
    final from = _boxFrom;
    final to = _boxTo;
    if (from == null || to == null) return null;
    final box = Rect.fromPoints(from, to);
    // A rectangle a couple of pixels across is a click that wobbled, and
    // taking it as a marquee would clear a selection somebody meant to keep.
    return box.width < 3 && box.height < 3 ? null : box;
  }

  /// Takes everything the marquee drew round.
  void _takeBox(bool add) {
    final editing = widget.editing;
    final surface = _surface;
    final box = _box;
    if (editing == null || surface == null || box == null) return;

    final picker = _pickerFor(editing, surface);
    final found = switch (widget.elementMode) {
      ElementMode.vertex => picker.verticesIn(box).cast<Object>(),
      ElementMode.edge => picker.edgesIn(box).cast<Object>(),
      ElementMode.face => picker.facesIn(box).cast<Object>(),
    };
    widget.onSelectElements?.call(found.toList(), add: add);
  }

  /// What a pixel lands on, in whatever mode is on.
  Object? _elementAt(Offset pixel) {
    final editing = widget.editing;
    final surface = _surface;
    if (editing == null || surface == null || surface.isEmpty) return null;

    final picker = _pickerFor(editing, surface);

    return switch (widget.elementMode) {
      ElementMode.vertex => picker.vertexAt(pixel),
      ElementMode.edge => picker.edgeAt(pixel),
      ElementMode.face => picker.faceAt(pixel),
    };
  }

  bool get _rendererAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// What is on screen.
  String get _summary {
    final scene = widget.workspace.loaded?.scene;
    if (scene == null) return 'No scene';
    return '${scene.objects.where((o) => o.isDrawable).length} drawn';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(Space.sm),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF14181F),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (_) => widget.onDropAsset != null,
        onAcceptWithDetails: (details) => widget.onDropAsset?.call(details.data),
        builder: (context, candidate, _) => LayoutBuilder(
          builder: (context, constraints) {
            // The size the handles are projected into. Recorded rather than
            // asked for at gesture time, because a pointer arrives before the
            // next layout does.
            _surface = constraints.biggest;

            return Stack(
          children: [
            // The input wraps the placeholder as well as the renderer. A
            // camera is Dart and works whether or not Filament does, and a
            // viewport that cannot be navigated on the platforms the renderer
            // has not reached yet is worse than one that says so and still
            // moves.
            Positioned.fill(child: _buildSurface()),
            if (candidate.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: OrbisColors.emberWash,
                      border: Border.all(color: OrbisColors.ember, width: 2),
                      borderRadius: BorderRadius.circular(Radii.panel),
                    ),
                  ),
                ),
              ),
            // Drawn in Flutter over the texture rather than as a render pass:
            // an outline pass in Filament is a real piece of work, and a box
            // projected with the same camera is honest about where the object
            // is without pretending to be more than it is.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SelectionPainter(
                    workspace: widget.workspace,
                    selected: widget.selected,
                    camera: widget.camera,
                  ),
                ),
              ),
            ),
            // Over the scene and under the handles: an interface is drawn on
            // top of the world in the game, and a gizmo you cannot reach
            // because a heads-up display is over it is a gizmo that does not
            // work. Ignoring the pointer for the same reason — this is a
            // preview of the interface, not the interface.
            if (widget.interface != null && widget.showInterface)
              Positioned.fill(
                child: IgnorePointer(
                  child: UiCanvasView(
                    document: widget.interface!,
                    designing: false,
                  ),
                ),
              ),
            // The parts of whatever is being edited, over the scene and under
            // the handles. A wireframe over everything all the time is a scene
            // nobody can read; this is only up while somebody is in it.
            if (widget.editing case final editing?)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: ElementPainter(
                      mesh: editing.mesh,
                      transform: editing.transform,
                      camera: widget.camera,
                      mode: widget.elementMode,
                      selection: _selectedElements,
                      hovered: _hoveredElement,
                    ),
                  ),
                ),
              ),
            // Over the outline, because a handle you cannot see is a handle
            // you cannot grab — and under nothing, because it has to be the
            // thing the pointer finds first.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: GizmoPainter(
                    gizmo: _gizmo,
                    hovered: _hovered,
                    dragging: _dragging,
                  ),
                ),
              ),
            ),
            if (_box != null)
              Positioned.fromRect(
                rect: _box!,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0x22E5893F),
                      border: Border.all(color: const Color(0xCCE5893F)),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: Space.md,
              top: Space.md,
              child: Row(children: [
                const _ViewportChip('Perspective'),
                const SizedBox(width: Space.xs),
                const _ViewportChip('Shaded'),
                const SizedBox(width: Space.xs),
                _ViewportChip(_summary),
                const SizedBox(width: Space.xs),
                _ViewportChip(
                  widget.snapping.on
                      ? 'Grid ${_gridLabel(widget.snapping.step)}'
                      : 'Grid off',
                  on: widget.snapping.on,
                  tooltip: 'Where a drag lands. Hold control or option to '
                      'suspend it for one drag; the bracket keys make it '
                      'coarser and finer.',
                  onTap: widget.onSnapping == null
                      ? null
                      : () => widget.onSnapping!(
                            Snapping(
                              on: !widget.snapping.on,
                              step: widget.snapping.step,
                              angle: widget.snapping.angle,
                            ),
                          ),
                ),
                // Only when there is one to hide. A switch for something that
                // is not there is a switch that teaches somebody nothing.
                if (_flying) ...[
                  const SizedBox(width: Space.xs),
                  _ViewportChip(
                    'Flying · ${_flySpeed.toStringAsFixed(1)} m/s',
                    on: true,
                    tooltip: 'WASD to move, Q and E for down and up, shift to '
                        'go faster. Two fingers or the right button to steer, '
                        'the wheel to change how fast. Escape or ` to stop.',
                    onTap: _toggleFlying,
                  ),
                ],
                if (widget.interface != null) ...[
                  const SizedBox(width: Space.xs),
                  _ViewportChip(
                    'Interface',
                    on: widget.showInterface,
                    tooltip: 'Draws the scene\'s interface over the viewport. '
                        'Turning it off here is for getting at what is behind '
                        'it — hiding the canvas object is what hides it in the '
                        'game.',
                    onTap: widget.onToggleInterface,
                  ),
                ],
              ]),
            ),
            // What the selected camera sees, in the corner. Unity puts this
            // bottom-right; it is bottom-left here because that is the corner
            // this editor leaves empty, and a preview under the transform
            // tools would cover the thing somebody is about to press.
            if (_preview != null)
              Positioned(
                left: Space.md,
                bottom: 52,
                child: _CameraPreview(child: _preview!),
              ),
            if (_rendererAvailable)
              Positioned(
                left: Space.md,
                bottom: Space.md,
                child: Row(
                  children: [
                    for (final mode in GizmoMode.values) ...[
                      _ToolButton(
                        mode: mode,
                        selected: _mode == mode,
                        onPressed: () => setState(() => _mode = mode),
                      ),
                      const SizedBox(width: Space.xs),
                    ],
                  ],
                ),
              ),
            Positioned(
                right: Space.md,
                bottom: Space.md,
                child: const _ViewportChip(
                  'Drag to orbit · two fingers to orbit, shift to pan, pinch '
                  'to zoom · ` to fly, then WASD',
                ),
              ),
          ],
        );
          },
        ),
      ),
    );
  }

  Widget _buildSurface() {
    return Focus(
      focusNode: _flyFocus,
      onKeyEvent: _onFlyKey,
      child: Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        // While flying the wheel sets how fast, not how close: somebody
        // holding the button down is going somewhere, and zooming the orbit
        // distance under them would move the view sideways as they went.
        if (_flying) {
          setState(() {
            _flySpeed =
                (_flySpeed * math.exp(-event.scrollDelta.dy * 0.0025))
                    .clamp(0.25, 400.0);
          });
          return;
        }
        widget.onCameraChanged(widget.camera.zoom(event.scrollDelta.dy));
      },
      // Trackpad gestures arrive here rather than as scroll events, once
      // something listens for them. That separation is the whole point: a
      // mouse wheel keeps meaning zoom, and two fingers on glass can mean
      // something better than a wheel with no wheel.
      onPointerPanZoomStart: (_) {
        _panZoomFrom = 1;
        _onTrackpad = true;
      },
      onPointerPanZoomUpdate: (event) {
        // Pinching is zoom, whichever mode the view is in. It is the one
        // gesture on a trackpad that has never meant anything else.
        if ((event.scale - _panZoomFrom).abs() > 0.001) {
          final step = event.scale / (_panZoomFrom == 0 ? 1 : _panZoomFrom);
          _panZoomFrom = event.scale;
          widget.onCameraChanged(
            widget.camera.zoom(-math.log(step) * 620),
          );
          return;
        }

        final delta = event.localPanDelta;
        if (delta == Offset.zero) return;

        if (_flying) {
          // Steering, while the keys do the moving. No button held down, which
          // is the whole reason flying can be switched on rather than held.
          widget.onCameraChanged(widget.camera.looking(delta));
          return;
        }

        final shifted = HardwareKeyboard.instance.isShiftPressed;
        widget.onCameraChanged(
          shifted ? widget.camera.pan(delta) : widget.camera.orbit(delta),
        );
      },
      onPointerPanZoomEnd: (_) {
        _panZoomFrom = 1;
        _onTrackpad = false;
      },
      onPointerDown: (event) {
        if (event.buttons & kSecondaryButton == 0) return;
        // The focus has to be here before the first key arrives, and a
        // viewport that took focus on hover would steal it from a name being
        // typed in the inspector.
        _flyFocus.requestFocus();
        setState(() {
          _looking = event.localPosition;
          _lastFlew = _elapsed;
        });
        _syncClock();
      },
      onPointerMove: (event) {
        final was = _looking;
        if (was == null) return;
        if (event.buttons & kSecondaryButton == 0) {
          setState(_stopFlying);
          _syncClock();
          return;
        }
        widget.onCameraChanged(
          widget.camera.looking(event.localPosition - was),
        );
        _looking = event.localPosition;
      },
      onPointerUp: (_) {
        if (!_flying) return;
        setState(_stopFlying);
        // Back to whatever the scene wanted, so a still scene stops drawing.
        _syncClock();
      },
      onPointerCancel: (_) {
        if (!_flying) return;
        setState(_stopFlying);
        _syncClock();
      },
      child: MouseRegion(
        onHover: (event) {
          if (widget.editing != null) {
            final under = _elementAt(event.localPosition);
            if (under != _hoveredElement) {
              setState(() => _hoveredElement = under);
            }
            return;
          }
          _hover(event.localPosition);
        },
        onExit: (_) => setState(() {
          _hovered = null;
          _hoveredElement = null;
        }),
        child: GestureDetector(
        // Opaque so drags land here rather than falling through to whatever
        // scrolls behind the viewport.
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          // A click in a view is how that view becomes the one the keyboard
          // is talking to. Focus that followed the pointer instead would take
          // it away from a name half-typed in the inspector.
          _flyFocus.requestFocus();

          // While somebody is editing a mesh, a click is about its parts.
          // Picking a different object out from under them mid-extrude is not
          // something anybody means by clicking on their own geometry.
          if (widget.editing != null) {
            widget.onPickElement?.call(
              _elementAt(details.localPosition),
              add: HardwareKeyboard.instance.isMetaPressed ||
                  HardwareKeyboard.instance.isShiftPressed,
            );
            return;
          }
          _pick(details.localPosition);
        },
        onPanStart: (details) {
          // Already handled as a trackpad gesture.
          if (_onTrackpad) return;
          // A handle first: a drag that starts on one is a transform, and
          // anywhere else is the view turning. Nothing to hold down and no
          // mode to be in — the handles are the mode.
          if (_grab(details.localPosition)) return;
          // While a mesh is being edited, a drag that missed the handles is a
          // marquee rather than the camera turning. The camera is still there
          // on the right button and on the trackpad, and having to hold
          // something down to select is the wrong way round for the one thing
          // somebody is doing constantly.
          if (widget.editing != null && widget.onSelectElements != null) {
            setState(() {
              _boxFrom = details.localPosition;
              _boxTo = details.localPosition;
            });
            return;
          }
          _dragAnchor = details.localPosition;
        },
        onPanUpdate: (details) {
          if (_onTrackpad) return;
          if (_dragging != null) {
            _dragTo(details.localPosition);
            return;
          }
          if (_boxFrom != null) {
            setState(() => _boxTo = details.localPosition);
            return;
          }
          final anchor = _dragAnchor;
          if (anchor == null) return;
          widget.onCameraChanged(
            widget.camera.orbit(details.localPosition - anchor),
          );
          _dragAnchor = details.localPosition;
        },
        onPanEnd: (_) {
          if (_boxFrom != null) {
            _takeBox(HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isShiftPressed);
            setState(() {
              _boxFrom = null;
              _boxTo = null;
            });
          }
          _release();
          _dragAnchor = null;
        },
        onPanCancel: () {
          setState(() {
            _boxFrom = null;
            _boxTo = null;
          });
          _release();
          _dragAnchor = null;
        },
        child: !_rendererAvailable
            ? const _Placeholder()
            : OrbisView(
                // One scene at a time, so the viewport shows one document and
                // there is never a question about which one an object belongs
                // to.
                scene: (widget.workspace.loaded?.scene ?? EditorScene([]))
                    .toRenderScene(
                  widget.camera.toRenderCamera(),
                  projectRoot: widget.projectRoot,
                  // What every scene in the project has in it, drawn alongside
                  // whichever one is open.
                  shared: widget.workspace.shared,
                  geometryOf: widget.geometryOf,
                ),
                onSceneNotes: widget.onSceneNotes,
              ),
        ),
      ),
    ),
    );
  }
}

/// One of the two things a drag on a handle can do.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.mode,
    required this.selected,
    required this.onPressed,
  });

  final GizmoMode mode;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: mode.label,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: selected ? OrbisColors.ember : OrbisColors.raised,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(
              color: selected ? OrbisColors.ember : OrbisColors.lineSoft,
            ),
          ),
          child: Icon(
            mode.icon,
            size: 15,
            color: selected ? Colors.white : OrbisColors.inkDim,
          ),
        ),
      ),
    );
  }
}

/// The grid shown where Filament cannot run.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.view_in_ar_outlined,
                  size: 34, color: OrbisColors.inkDim),
              const SizedBox(height: Space.md),
              Text('Viewport', style: OrbisText.label),
              const SizedBox(height: Space.xs),
              Text('The renderer runs on macOS so far.',
                  style: OrbisText.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _ViewportChip extends StatelessWidget {
  const _ViewportChip(this.label, {this.on, this.onTap, this.tooltip});

  final String label;

  /// Null for a chip that only says something. Set for one that is also a
  /// switch, which then reads as on or off rather than as a label.
  final bool? on;

  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final lit = on ?? false;

    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
      decoration: BoxDecoration(
        color: on == null
            ? OrbisColors.surface.withValues(alpha: 0.8)
            : (lit
                ? OrbisColors.emberWash
                : OrbisColors.surface.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(
          color: lit ? OrbisColors.ember : OrbisColors.lineSoft,
        ),
      ),
      child: Text(
        label,
        style: OrbisText.caption.copyWith(
          fontSize: 11,
          color: lit ? OrbisColors.ember : null,
        ),
      ),
    );

    if (tooltip != null) chip = Tooltip(message: tooltip!, child: chip);
    if (onTap == null) return chip;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }
}

/// A faint ground grid, so an empty viewport reads as a space rather than a
/// panel that failed to load.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = OrbisColors.line.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    const spacing = 32.0;

    for (var x = spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}

/// Draws a box round the selected object.
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.workspace,
    required this.selected,
    required this.camera,
  });

  final Workspace workspace;
  final Set<String> selected;
  final OrbitCamera camera;

  /// The unit cube the renderer draws for every object, in its own space.
  static final _corners = [
    for (final x in [-1.0, 1.0])
      for (final y in [-1.0, 1.0])
        for (final z in [-1.0, 1.0]) Vector3(x, y, z),
  ];

  /// Pairs of corner indices making the twelve edges.
  static const _edges = [
    [0, 1], [1, 3], [3, 2], [2, 0],
    [4, 5], [5, 7], [7, 6], [6, 4],
    [0, 4], [1, 5], [2, 6], [3, 7],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (selected.isEmpty || size.isEmpty) return;

    final scene = workspace.loaded?.scene;
    if (scene == null) return;

    final view = camera.toRenderCamera();
    final viewMatrix = makeViewMatrix(
      view.position,
      view.target,
      Vector3(0, 1, 0),
    );
    final projection = makePerspectiveMatrix(
      radians(view.fieldOfView),
      size.width / size.height,
      0.1,
      1000,
    );
    final viewProjection = projection.multiplied(viewMatrix);
    final path = Path();

    for (final id in selected) {
      final object = scene[id];
      if (object == null || !object.isDrawable) continue;

      final clip = viewProjection.multiplied(scene.worldOf(id));
      final points = <Offset>[];
      var visible = true;

      for (final corner in _corners) {
        final projected =
            clip.transform(Vector4(corner.x, corner.y, corner.z, 1));
        // Behind the camera: the perspective divide flips the point to the
        // opposite side of the screen, which would draw a box across the whole
        // viewport. That one is skipped rather than drawn wrong.
        if (projected.w <= 1e-6) {
          visible = false;
          break;
        }
        points.add(Offset(
          (projected.x / projected.w * 0.5 + 0.5) * size.width,
          (1 - (projected.y / projected.w * 0.5 + 0.5)) * size.height,
        ));
      }
      if (!visible) continue;

      for (final edge in _edges) {
        path
          ..moveTo(points[edge[0]].dx, points[edge[0]].dy)
          ..lineTo(points[edge[1]].dx, points[edge[1]].dy);
      }
    }

    if (path.getBounds().isEmpty) return;

    canvas
      // A dark pass under the bright one, so the outline reads against a pale
      // surface as well as a dark one.
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0x66000000),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = OrbisColors.ember,
      );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter old) => true;
}

/// A small window onto what a camera sees.
///
/// Deliberately small and in a corner: it answers "is this shot right" without
/// becoming the thing somebody is looking at. Anything bigger is the game
/// view, which is a panel and can be docked wherever it is wanted.
class _CameraPreview extends StatelessWidget {
  const _CameraPreview({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      height: 135,
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: OrbisColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            alignment: Alignment.centerLeft,
            child: Text('CAMERA', style: OrbisText.section),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(Radii.control),
              ),
              // Nothing in it takes the pointer: it is a picture of the shot,
              // and a click here should still select what is behind it in the
              // viewport.
              child: IgnorePointer(child: child),
            ),
          ),
        ],
      ),
    );
  }
}
