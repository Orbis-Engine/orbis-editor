import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'data_object.dart';

/// What an asset is, decided by its extension.
///
/// Extension rather than content, because the browser has to label a thousand
/// files fast enough to scroll, and opening each one to be certain is what
/// makes a project window feel slow.
enum AssetKind {
  folder('Folder', Icons.folder_outlined),
  scene('Scene', Icons.public),
  mesh('Mesh', Icons.view_in_ar_outlined),
  texture('Texture', Icons.image_outlined),
  material('Material', Icons.grain),
  script('Script', Icons.code),
  style('Stylesheet', Icons.style_outlined),
  native('C++', Icons.memory),
  prefab('Prefab', Icons.widgets_outlined),
  dataObject('Data object', Icons.dataset_outlined),
  audio('Audio', Icons.graphic_eq),
  data('Data', Icons.data_object),
  other('File', Icons.insert_drive_file_outlined);

  const AssetKind(this.label, this.icon);

  final String label;
  final IconData icon;

  static const _byExtension = <String, AssetKind>{
    '.oscene': scene,
    '.gltf': mesh, '.glb': mesh, '.obj': mesh, '.fbx': mesh,
    '.png': texture, '.jpg': texture, '.jpeg': texture,
    '.ktx2': texture, '.hdr': texture, '.exr': texture,
    '.fmat': material, '.mat': material,
    '.ts': script, '.tsx': script, '.js': script, '.jsx': script,
    '.dart': script,
    '.css': style,
    '.cpp': native, '.cc': native, '.h': native, '.hpp': native,
    '.oprefab': prefab,
    '.odata': dataObject,
    '.wav': audio, '.mp3': audio, '.ogg': audio,
    '.json': data, '.yaml': data, '.yml': data,
  };

  static AssetKind of(String path) =>
      _byExtension[p.extension(path).toLowerCase()] ?? other;
}

/// One entry in the project folder.
class Asset {
  const Asset({
    required this.name,
    required this.path,
    required this.kind,
    this.bytes,
  });

  final String name;
  final String path;
  final AssetKind kind;

  /// Null for folders, whose size is not a useful thing to show.
  final int? bytes;

  bool get isFolder => kind == AssetKind.folder;

  /// A size somebody can read at a glance.
  String get size {
    final value = bytes;
    if (value == null) return '';
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Reads what is actually in a project folder, and says when it changes.
///
/// Reads are synchronous and on demand: a folder is small and a build that
/// blocks for a moment beats a list that is a frame behind. [changes] is what
/// tells the browser a read is worth doing again.
class AssetTree {
  AssetTree(this.root);

  /// The project directory, which is the only place the browser will look.
  final String root;

  StreamController<void>? _changes;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _settle;

  /// Fires after the project folder changes, whoever changed it.
  ///
  /// Coalesced: saving one file from another program can produce several
  /// events, and a copy of a hundred assets produces hundreds. Rebuilding the
  /// browser for each one would make the editor stutter during exactly the
  /// operation somebody most wants to watch.
  Stream<void> get changes => (_changes ??= _openWatch()).stream;

  static const Duration _settleDelay = Duration(milliseconds: 180);

  StreamController<void> _openWatch() {
    final controller = StreamController<void>.broadcast(onCancel: _stopWatch);

    try {
      _watch = Directory(root)
          .watch(recursive: true)
          .listen(
            (_) {
              _settle?.cancel();
              _settle = Timer(_settleDelay, () {
                if (!controller.isClosed) controller.add(null);
              });
            },
            // A watch that dies takes the stream with it rather than leaving
            // the browser silently stale — the refresh button still works.
            onError: (Object _) {},
            cancelOnError: true,
          );
    } on FileSystemException {
      // Watching is not available everywhere, and a browser that cannot watch
      // is still a browser. The refresh button is the fallback.
    }

    return controller;
  }

  void _stopWatch() {
    _settle?.cancel();
    _settle = null;
    _watch?.cancel();
    _watch = null;
  }

  /// Stops watching. Call when the browser goes away.
  void dispose() {
    _stopWatch();
    _changes?.close();
    _changes = null;
  }

  /// What is directly inside [directory], folders first and then by name.
  ///
  /// Returns nothing rather than throwing for a folder that has gone: a
  /// project browser open on a folder somebody deleted in Finder should show
  /// an empty list, not take the editor down.
  List<Asset> read(String directory) {
    final target = Directory(directory);
    if (!target.existsSync()) return const [];

    final entries = <Asset>[];
    try {
      for (final entity in target.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        // Dotfiles are the tool's business, not the artist's.
        if (name.startsWith('.')) continue;

        if (entity is Directory) {
          entries.add(Asset(
            name: name,
            path: entity.path,
            kind: AssetKind.folder,
          ));
        } else if (entity is File) {
          entries.add(Asset(
            name: name,
            path: entity.path,
            kind: AssetKind.of(entity.path),
            bytes: _sizeOf(entity),
          ));
        }
      }
    } on FileSystemException {
      // Unreadable folder: an empty list is the truthful answer and the
      // browser stays usable.
      return const [];
    }

    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Every folder under the root, for the tree on the left.
  List<({String path, int depth})> folders({int maximumDepth = 8}) {
    final found = <({String path, int depth})>[];

    void walk(String directory, int depth) {
      if (depth > maximumDepth) return;
      for (final asset in read(directory)) {
        if (!asset.isFolder) continue;
        found.add((path: asset.path, depth: depth));
        walk(asset.path, depth + 1);
      }
    }

    walk(root, 0);
    return found;
  }

  /// Where a path sits relative to the project, for the breadcrumb.
  ///
  /// Anything outside the project comes back as its own path rather than a
  /// string of `..` segments, which would be both ugly and a sign of a bug.
  String relative(String path) {
    if (!p.isWithin(root, path)) return p.equals(root, path) ? '' : path;
    return p.relative(path, from: root);
  }

  /// Deletes a file or a folder and everything in it.
  ///
  /// Returns what went wrong, or null. A deletion that fails silently is how
  /// somebody comes to believe a file is gone when it is not.
  String? delete(String path) {
    try {
      final directory = Directory(path);
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
        return null;
      }
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
        return null;
      }
      return 'It is not there any more.';
    } on FileSystemException catch (error) {
      return error.osError?.message ?? error.message;
    }
  }

  /// Renames a file or folder within its own directory.
  ///
  /// Refuses to overwrite something that is already there, because a rename
  /// that silently replaces another file destroys work nobody asked about.
  String? rename(String path, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'A name cannot be empty.';
    if (trimmed.contains(p.separator) || trimmed == '.' || trimmed == '..') {
      return 'A name cannot contain a path.';
    }

    final target = p.join(p.dirname(path), trimmed);
    if (p.equals(target, path)) return null;

    // Case-only renames look like a collision on a case-insensitive disk, and
    // are the one case where the destination existing is fine.
    final sameFileDifferentCase =
        p.equals(target.toLowerCase(), path.toLowerCase());
    if (!sameFileDifferentCase &&
        (File(target).existsSync() || Directory(target).existsSync())) {
      return 'There is already something called "$trimmed" here.';
    }

    try {
      if (Directory(path).existsSync()) {
        Directory(path).renameSync(target);
      } else {
        File(path).renameSync(target);
      }
      return null;
    } on FileSystemException catch (error) {
      return error.osError?.message ?? error.message;
    }
  }

  /// A path inside [directory] that nothing is using yet.
  /// One entry, for a path already known to exist.
  ///
  /// For the caller that has just made a file and wants to hand it on without
  /// re-reading the whole folder to find it again.
  Asset describe(String path) {
    final file = File(path);
    final folder = FileSystemEntity.isDirectorySync(path);
    return Asset(
      name: p.basename(path),
      path: path,
      kind: folder ? AssetKind.folder : AssetKind.of(path),
      bytes: folder ? null : (file.existsSync() ? file.lengthSync() : null),
    );
  }

  /// Makes one of the things the browser knows how to make.
  ///
  /// Returns what went wrong, or null. The name is made unique first, so
  /// asking for a second New folder gets one rather than an error.
  ({String? problem, String? path}) create(
    String directory,
    NewAsset what,
    String name,
  ) {
    if (!p.isWithin(root, directory) && directory != root) {
      return (problem: 'That folder is outside the project.', path: null);
    }

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return (problem: 'A name is needed.', path: null);
    }
    if (trimmed.contains(p.separator) || trimmed.contains('..')) {
      return (problem: 'A name cannot be a path.', path: null);
    }

    final wanted = what.isFolder ? trimmed : '$trimmed${what.extension}';
    final unique = available(directory, wanted);
    final path = p.join(directory, unique);

    try {
      if (what.isFolder) {
        Directory(path).createSync();
      } else if (what == NewAsset.dataObject) {
        File(path).writeAsStringSync(
          DataObject.blank(p.basenameWithoutExtension(unique)).toText(),
        );
      } else {
        File(path).writeAsStringSync(what.starter ?? '');
      }
    } on FileSystemException catch (error) {
      return (problem: error.osError?.message ?? 'Could not create it.',
              path: null);
    }

    return (problem: null, path: path);
  }

  /// Writes a file the editor has made itself — a prefab, most of the time.
  ///
  /// Separate from [create] because the contents are not a starter to be
  /// edited afterwards: they are the thing.
  ({String? problem, String? path}) write(
    String directory,
    String name,
    String contents,
  ) {
    if (!p.isWithin(root, directory) && directory != root) {
      return (problem: 'That folder is outside the project.', path: null);
    }

    final path = p.join(directory, available(directory, name));
    try {
      File(path).writeAsStringSync(contents);
    } on FileSystemException catch (error) {
      return (problem: error.osError?.message ?? 'Could not write it.',
              path: null);
    }
    return (problem: null, path: path);
  }

  String available(String directory, String name) {
    final base = p.basenameWithoutExtension(name);
    final extension = p.extension(name);

    var candidate = p.join(directory, name);
    for (var i = 2; File(candidate).existsSync() ||
        Directory(candidate).existsSync(); i++) {
      candidate = p.join(directory, '$base $i$extension');
    }
    return candidate;
  }

  int? _sizeOf(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// The things the project browser knows how to make.
///
/// A starter rather than an empty file. Somebody who asks for a new script
/// wants to write the second line of it, not to look up which import the
/// first one takes — and a file that runs the moment it is made says more
/// about what the engine expects than any amount of documentation.
enum NewAsset {
  folder(
    label: 'Folder',
    icon: Icons.create_new_folder_outlined,
    extension: '',
    suggested: 'New folder',
  ),

  script(
    label: 'TypeScript',
    icon: Icons.code,
    extension: '.ts',
    suggested: 'behaviour',
    starter: '''
// A behaviour, in TypeScript.
//
// Everything this puts in the world it puts through `spawn`. The engine asks
// for a frame, this runs, and what it says is what is drawn.

import { spawn, onFrame } from "orbis/scene";

spawn({
  id: "thing",
  at: [0, 0, 0],
  size: 1,
  colour: "#D9634F",
});

onFrame((seconds) => {
  spawn({
    id: "thing",
    at: [Math.sin(seconds) * 3, 0, 0],
    size: 1,
    colour: "#D9634F",
  });
});
''',
  ),

  interface(
    label: 'Interface',
    icon: Icons.dashboard_customize_outlined,
    extension: '.tsx',
    suggested: 'panel',
    starter: '''
// An interface, in TypeScript.
//
// A component is a function from props to elements. There is no state hook
// and no lifecycle: the reconciler is on the other side of this, and the
// interface is described again after every event.

import { mount } from "orbis";

const state = { count: 0 };

function Panel() {
  return (
    <column class="p-4 gap-2 bg-slate-900 rounded-lg border border-slate-700">
      <text class="text-lg font-semibold text-slate-100">Panel</text>
      <text class="text-slate-300">Pressed {state.count} times</text>
      <button
        class="px-3 py-2 rounded bg-ember-500 text-white"
        key="press"
        onPressed={() => { state.count += 1; }}
      >
        Press me
      </button>
    </column>
  );
}

mount(() => <Panel />);
''',
  ),

  stylesheet(
    label: 'Stylesheet',
    icon: Icons.style_outlined,
    extension: '.css',
    suggested: 'theme',
    starter: '''
/* Declarations an interface can wear over its class list.
 *
 * A subset, and an honest one: what is here is what maps onto a widget tree
 * without lying. Floats, grid areas, selectors and the cascade need a
 * document, and there is not one.
 */

.panel {
  padding: 16px;
  gap: 8px;
  background: #111418;
  border-radius: 10px;
  border: 1px solid #2A313A;
}

.heading {
  font-size: 18px;
  font-weight: 600;
  color: #E9EDF2;
}
''',
  ),

  native(
    label: 'C++',
    icon: Icons.memory,
    extension: '.cpp',
    suggested: 'system',
    starter: '''
// A system, in C++.
//
// For the work that has to be native: something walking a million components,
// something talking to a device, something a profiler has already pointed at.
// Everything else is quicker to write in TypeScript and fast enough there.

#include <cstdint>

extern "C" {

/// Called once, when this is loaded.
void orbis_start() {}

/// Called every frame, with the seconds since the last one.
void orbis_step(double delta) {
  (void)delta;
}

/// Called once, before this is unloaded.
void orbis_stop() {}

}
''',
  ),

  header(
    label: 'C++ header',
    icon: Icons.description_outlined,
    extension: '.h',
    suggested: 'system',
    starter: '''
// What a system offers to whatever else is compiled with it.
//
// Declarations only. The engine calls the entry points in the .cpp through
// their C names; this is for the code either side of that boundary.

#pragma once

#include <cstdint>

namespace orbis {

/// Called every frame, with the seconds since the last one.
void step(double delta);

}  // namespace orbis
''',
  ),

  theme(
    label: 'Theme',
    icon: Icons.palette_outlined,
    extension: '.css',
    suggested: 'theme',
    starter: '''
/* The values an interface is built out of, in one place.
 *
 * Separate from a stylesheet on purpose: a stylesheet says how one thing
 * looks, and this says what the whole project's colours and spacing are. Two
 * files because they change for different reasons and at different rates.
 */

:root {
  --ink: #E9EDF2;
  --ink-dim: #8A94A3;
  --surface: #111418;
  --raised: #191E25;
  --line: #2A313A;
  --accent: #E58A3F;

  --space: 8px;
  --radius: 10px;
}
''',
  ),

  dataObject(
    label: 'Data object',
    icon: Icons.dataset_outlined,
    extension: '.odata',
    suggested: 'settings',
    // Written by DataObject.blank rather than as text here, so there is one
    // definition of what a new one contains.
    starter: null,
  ),

  json(
    label: 'JSON',
    icon: Icons.data_object,
    extension: '.json',
    suggested: 'data',
    starter: '{}\n',
  ),

  scene(
    label: 'Scene',
    icon: Icons.public,
    extension: '.oscene',
    suggested: 'untitled',
    starter: '{"version":3,"objects":[]}\n',
  );

  const NewAsset({
    required this.label,
    required this.icon,
    required this.extension,
    required this.suggested,
    this.starter,
  });

  final String label;
  final IconData icon;

  /// Empty for a folder, which is the one of these that is not a file.
  final String extension;

  /// What the name box starts with. The browser makes it unique.
  final String suggested;

  /// What the file says the moment it is made. Null for a folder.
  final String? starter;

  bool get isFolder => this == NewAsset.folder;
}

/// How the things somebody can make are laid out on the menu.
///
/// A flat list of six was already a wall, and every kind added makes it
/// worse. Grouped, the menu answers the question somebody actually has —
/// "am I writing code, or styling something, or making a scene" — before it
/// asks them to pick a file extension.
///
/// The commonest thing by far, a folder, stays at the top level: putting it
/// behind a submenu would be tidier and slower.
enum NewAssetGroup {
  script('Script', Icons.code, [
    NewAsset.script,
    NewAsset.interface,
    NewAsset.native,
    NewAsset.header,
  ]),

  style('Style', Icons.style_outlined, [
    NewAsset.stylesheet,
    NewAsset.theme,
  ]),

  data('Data', Icons.dataset_outlined, [
    NewAsset.dataObject,
    NewAsset.json,
  ]);

  const NewAssetGroup(this.label, this.icon, this.members);

  final String label;
  final IconData icon;
  final List<NewAsset> members;

  /// The kinds that sit on the menu itself rather than in a group.
  static const List<NewAsset> loose = [NewAsset.folder, NewAsset.scene];
}
