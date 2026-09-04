import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../editor/scene.dart';
import '../editor/scene_document.dart';

/// What a project looks like on disk.
///
/// One file at the root, named so a folder is recognisably a project without
/// opening it, and versioned so an editor that meets a newer one can say so
/// rather than misread it.
const String projectFileName = 'orbis.project.json';
const int projectFormatVersion = 1;

/// What a new project starts as.
enum ProjectTemplate {
  /// Nothing but a scene. For someone who knows what they are building.
  empty(
    'Empty',
    'A single empty scene, and nothing else.',
  ),

  /// A lit scene with a ground plane and something to look at.
  scene(
    'Lit scene',
    'A ground plane, a sun, and an object — enough to see that it works.',
  ),

  /// A scene plus a controllable camera rig.
  thirdPerson(
    'Third person',
    'A lit scene with a follow camera and a character to drive.',
  );

  const ProjectTemplate(this.label, this.description);

  final String label;
  final String description;
}

/// A project the editor knows about.
class Project {
  const Project({
    required this.name,
    required this.directory,
    required this.lastOpened,
    this.engineVersion = '0.1.0',
  });

  factory Project.fromJson(Map<String, Object?> json, String directory) {
    return Project(
      name: json['name'] as String? ?? p.basename(directory),
      directory: directory,
      engineVersion: json['engine'] as String? ?? 'unknown',
      lastOpened:
          DateTime.tryParse(json['lastOpened'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String name;
  final String directory;
  final String engineVersion;
  final DateTime lastOpened;

  String get displayPath {
    final home = Platform.environment['HOME'];
    if (home != null && directory.startsWith(home)) {
      return '~${directory.substring(home.length)}';
    }
    return directory;
  }

  /// Whether the folder is still where it was last seen.
  bool get exists => File(p.join(directory, projectFileName)).existsSync();

  Map<String, Object?> toJson() => {
        'formatVersion': projectFormatVersion,
        'name': name,
        'engine': engineVersion,
        'lastOpened': lastOpened.toIso8601String(),
      };

  Project touched() => Project(
        name: name,
        directory: directory,
        engineVersion: engineVersion,
        lastOpened: DateTime.now(),
      );
}

/// Reading, creating and remembering projects.
class ProjectStore {
  /// Projects the editor has opened, most recent first.
  ///
  /// A project whose folder has since moved or been deleted is kept in the
  /// list rather than dropped silently — the launcher shows it as missing, so
  /// somebody who moved a folder sees why it is not opening instead of
  /// wondering where their work went.
  Future<List<Project>> recents() async {
    final file = await _recentsFile();
    if (!file.existsSync()) return const [];

    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      final projects = [
        for (final entry in decoded)
          if (entry is Map<String, Object?> && entry['directory'] is String)
            Project.fromJson(entry, entry['directory']! as String),
      ]..sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
      return projects;
    } on FormatException {
      // A corrupt list is not worth failing to launch over.
      return const [];
    }
  }

  Future<void> remember(Project project) async {
    final existing = await recents();
    final updated = [
      project.touched(),
      for (final other in existing)
        if (other.directory != project.directory) other,
    ];

    final file = await _recentsFile();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert([
        for (final entry in updated.take(20))
          {...entry.toJson(), 'directory': entry.directory},
      ]),
    );
  }

  Future<void> forget(Project project) async {
    final remaining = (await recents())
        .where((other) => other.directory != project.directory)
        .toList();
    final file = await _recentsFile();
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert([
        for (final entry in remaining)
          {...entry.toJson(), 'directory': entry.directory},
      ]),
    );
  }

  /// Reads a project from a folder, or null if there is not one there.
  Project? open(String directory) {
    final file = File(p.join(directory, projectFileName));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return null;
      return Project.fromJson(decoded, directory);
    } on FormatException {
      return null;
    }
  }

  /// Creates a project folder and everything a template puts in it.
  ///
  /// Refuses rather than merges if the folder already holds a project, since
  /// silently adopting somebody's existing work is the worse failure.
  Future<Project> create({
    required String name,
    required String parentDirectory,
    required ProjectTemplate template,
  }) async {
    final directory = Directory(p.join(parentDirectory, _folderName(name)));
    if (File(p.join(directory.path, projectFileName)).existsSync()) {
      throw StateError('There is already a project in ${directory.path}.');
    }

    directory.createSync(recursive: true);
    Directory(p.join(directory.path, 'scenes')).createSync();
    Directory(p.join(directory.path, 'assets')).createSync();

    final project = Project(
      name: name,
      directory: directory.path,
      lastOpened: DateTime.now(),
    );

    File(p.join(directory.path, projectFileName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
    File(p.join(directory.path, 'scenes', 'main$sceneExtension'))
        .writeAsStringSync(SceneDocument.encode(sceneFor(template)));
    File(p.join(directory.path, '.gitignore'))
        .writeAsStringSync('build/\n.orbis/\n');

    await remember(project);
    return project;
  }

  /// A folder name from a project name, since a name is for people and a path
  /// is for filesystems.
  String _folderName(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'orbis-project' : slug;
  }

  Future<File> _recentsFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'recent_projects.json'));
  }
}

/// What a template starts a project with.
///
/// Built as a real scene and written through [SceneDocument], so a new project
/// opens on exactly what the editor would have saved. A separate hand-written
/// shape here would drift from the format the editor reads, and the drift
/// would only show up as a new project failing to open.
EditorScene sceneFor(ProjectTemplate template) {
  final sun = SceneObject(
    id: 'sun',
    name: 'Sun',
    kind: ObjectKind.light,
    rotation: Vector3(-55, 35, 0),
    colour: const Color(0xFFFFF3E0),
    power: 1400,
  );
  final ground = SceneObject(
    id: 'ground',
    name: 'Ground',
    kind: ObjectKind.mesh,
    position: Vector3(0, -1.05, 0),
    scale: Vector3(8, 0.05, 8),
    colour: const Color(0xFF3B424C),
  );

  return switch (template) {
    ProjectTemplate.empty => EditorScene([]),
    ProjectTemplate.scene => EditorScene([
        sun,
        ground,
        SceneObject(
          id: 'cube',
          name: 'Cube',
          kind: ObjectKind.mesh,
          rotation: Vector3(0, 25, 0),
        ),
      ]),
    ProjectTemplate.thirdPerson => EditorScene([
        sun,
        ground,
        SceneObject(
          id: 'character',
          name: 'Character',
          kind: ObjectKind.mesh,
          scale: Vector3(0.5, 0.9, 0.5),
          colour: const Color(0xFFE5B84F),
        ),
        SceneObject(
          id: 'camera',
          name: 'Follow Camera',
          kind: ObjectKind.camera,
          position: Vector3(0, 3, 7),
          rotation: Vector3(-15, 0, 0),
        ),
      ]),
  };
}
