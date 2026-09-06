import 'package:flutter/foundation.dart';

import 'scene.dart';

/// Where a command finds the scene it belongs to.
///
/// Commands name a scene rather than holding one, so a scene can be closed and
/// reopened without every step on the undo stack pointing at a dead object.
abstract interface class SceneHost {
  EditorScene? sceneFor(String sceneId);
}

/// One undoable change to the scene.
///
/// Every edit goes through one of these. A widget that mutated the scene
/// directly would work perfectly and be invisible to undo, which is the kind
/// of gap nobody finds until they have lost work to it.
abstract class EditorCommand {
  /// Which open scene this changes.
  String get sceneId;

  /// What the change is called, as it appears next to Undo. Written as the
  /// action, not the outcome: "Move Cube", so the menu reads "Undo Move Cube".
  String get label;

  void apply(SceneHost host);

  void revert(SceneHost host);

  /// Every scene this changes, which is usually just [sceneId].
  ///
  /// A move between scenes changes two documents, and both of them have to
  /// read as unsaved afterwards. Stamping only the destination would leave the
  /// scene the object came *out* of looking clean while it is a whole object
  /// short of what is on disk.
  Set<String> get touches => {sceneId};

  /// Identifies a run of changes that should collapse into one undo step.
  ///
  /// Dragging a slider produces a command per frame. Without this, undo would
  /// step back through a hundred of them and feel broken. Null means the
  /// command always stands alone.
  Object? get mergeKey => null;

  /// Set by the history each time this command is run or absorbs another.
  ///
  /// What lets "has anything changed since the last save" be answered exactly.
  /// Depth alone cannot: a merged drag leaves the stack the same length while
  /// changing what it means.
  int stamp = 0;

  /// Folds a later command of the same [mergeKey] into this one.
  ///
  /// The earlier command keeps the value it started from and takes the later
  /// one's destination, so undoing the run returns to where the drag began.
  void absorb(EditorCommand later) {}
}

/// What has been done, and what can be undone.
///
/// Notifies rather than being polled, so the toolbar's Undo button and the
/// viewport both learn about a change the same way.
/// One stack across every open scene.
///
/// Global rather than one per scene: an editor where undo depends on which
/// scene happens to be selected undoes the wrong thing exactly when somebody
/// is moving between two of them, which is the moment they most need it to be
/// predictable.
class History extends ChangeNotifier {
  History(this.host);

  final SceneHost host;

  final List<EditorCommand> _done = [];
  final List<EditorCommand> _undone = [];

  /// Stops the next command merging into the last one.
  ///
  /// Set when a gesture ends. A time window would be the obvious alternative
  /// and is worse: it makes undo depend on how fast somebody dragged.
  bool _sealed = true;

  /// How many steps are kept. Deep enough to cover a working session, bounded
  /// so a long one does not grow without limit.
  static const int limit = 200;

  int _stamps = 0;

  /// Whether anything has changed since the last [markSaved].
  ///
  /// Undoing back to the point the file was written reads as clean again,
  /// which is what somebody who changed their mind expects.
  /// The stamp of the most recent change to one scene, or zero for none.
  ///
  /// What "has this scene changed since it was written" is answered with. A
  /// scene is unchanged when the last thing done to it is the same thing that
  /// was there when it was saved, whatever has happened to other scenes since.
  int stampFor(String sceneId) {
    for (var i = _done.length - 1; i >= 0; i--) {
      if (_done[i].touches.contains(sceneId)) return _done[i].stamp;
    }
    return 0;
  }

  /// Forgets every step belonging to a scene, for when one is closed.
  void forget(String sceneId) {
    _done.removeWhere((command) => command.touches.contains(sceneId));
    _undone.removeWhere((command) => command.touches.contains(sceneId));
    _sealed = true;
    notifyListeners();
  }

  bool get canUndo => _done.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;

  String? get undoLabel => _done.isEmpty ? null : _done.last.label;
  String? get redoLabel => _undone.isEmpty ? null : _undone.last.label;

  @visibleForTesting
  List<String> get labels => [for (final c in _done) c.label];

  /// Applies a command and records it.
  ///
  /// Throws whatever the command throws, having recorded nothing — a refused
  /// edit must not leave a step on the stack that would undo something else.
  void run(EditorCommand command) {
    final key = command.mergeKey;
    if (!_sealed && key != null && _done.isNotEmpty &&
        _done.last.mergeKey == key) {
      command.apply(host);
      _done.last
        ..absorb(command)
        ..stamp = ++_stamps;
      notifyListeners();
      return;
    }

    command.apply(host);

    // Cleared only once the command has applied without throwing. A redo stack
    // discarded by an edit that then failed would lose work for no reason.
    _undone.clear();
    command.stamp = ++_stamps;
    _done.add(command);
    if (_done.length > limit) _done.removeAt(0);
    _sealed = key == null;
    notifyListeners();
  }

  /// Ends a run of merging commands. Call when a drag or a typed edit finishes.
  void seal() => _sealed = true;

  void undo() {
    if (_done.isEmpty) return;
    final command = _done.removeLast();
    command.revert(host);
    _undone.add(command);
    _sealed = true;
    notifyListeners();
  }

  void redo() {
    if (_undone.isEmpty) return;
    final command = _undone.removeLast();
    command.apply(host);
    _done.add(command);
    _sealed = true;
    notifyListeners();
  }

  void clear() {
    _done.clear();
    _undone.clear();
    _sealed = true;
    notifyListeners();
  }

  /// The scene the next undo would change, so the shell can select it.
  String? get undoSceneId => _done.isEmpty ? null : _done.last.sceneId;

  String? get redoSceneId => _undone.isEmpty ? null : _undone.last.sceneId;
}
