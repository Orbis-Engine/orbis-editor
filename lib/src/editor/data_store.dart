import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'data_object.dart';

/// The data objects a project has, read once and kept.
///
/// Cached because a reference is looked up on every rebuild of the inspector
/// and forty objects can point at the same file. Reading it forty times a
/// frame would make a panel that shows a number feel like a panel that opens
/// a file.
///
/// A [ChangeNotifier] so that editing a value in one place shows up
/// everywhere it is used — which is the reason to have shared data at all.
class DataStore extends ChangeNotifier {
  DataStore(this.root);

  /// The project directory. Every path here is relative to it.
  final String root;

  final Map<String, DataObject?> _held = {};

  /// The data object at a path, or null when it is missing or unreadable.
  ///
  /// The failure is cached too. A reference to a deleted file would otherwise
  /// hit the disk on every frame, which is the one case where it matters
  /// most that it does not.
  DataObject? operator [](String relative) {
    if (_held.containsKey(relative)) return _held[relative];
    return _held[relative] = _read(relative);
  }

  DataObject? _read(String relative) {
    try {
      final file = File(p.join(root, relative));
      if (!file.existsSync()) return null;
      return DataObject.read(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Writes one back, and tells everything showing it.
  ///
  /// Returns what went wrong, or null. Not undoable, for the same reason
  /// renaming and deleting a file are not: the undo stack covers the scene,
  /// and a step that silently rewrote a file on disk would be a worse
  /// surprise than one that does not.
  String? write(String relative, DataObject data) {
    try {
      final file = File(p.join(root, relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(data.toText());
    } on FileSystemException catch (error) {
      return error.osError?.message ?? 'Could not write it.';
    }
    _held[relative] = data;
    notifyListeners();
    return null;
  }

  /// Forgets what was read, for when the folder changes underneath.
  void forget([String? relative]) {
    if (relative == null) {
      _held.clear();
    } else {
      _held.remove(relative);
    }
    notifyListeners();
  }
}
