import 'package:flutter/foundation.dart';

import 'scene.dart';

/// One undoable change to the scene.
///
/// Every edit goes through one of these. A widget that mutated the scene
/// directly would work perfectly and be invisible to undo, which is the kind
/// of gap nobody finds until they have lost work to it.
abstract class EditorCommand {
  /// What the change is called, as it appears next to Undo. Written as the
  /// action, not the outcome: "Move Cube", so the menu reads "Undo Move Cube".
  String get label;

  void apply(EditorScene scene);

  void revert(EditorScene scene);

  /// Identifies a run of changes that should collapse into one undo step.
  ///
  /// Dragging a slider produces a command per frame. Without this, undo would
  /// step back through a hundred of them and feel broken. Null means the
  /// command always stands alone.
  Object? get mergeKey => null;

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
class History extends ChangeNotifier {
  History(this.scene);

  final EditorScene scene;

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
      command.apply(scene);
      _done.last.absorb(command);
      notifyListeners();
      return;
    }

    command.apply(scene);

    // Cleared only once the command has applied without throwing. A redo stack
    // discarded by an edit that then failed would lose work for no reason.
    _undone.clear();
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
    command.revert(scene);
    _undone.add(command);
    _sealed = true;
    notifyListeners();
  }

  void redo() {
    if (_undone.isEmpty) return;
    final command = _undone.removeLast();
    command.apply(scene);
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
}
