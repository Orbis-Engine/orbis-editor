import 'dart:convert';
import 'dart:io';

import 'package:orbis_native/orbis_native.dart';
import 'package:path/path.dart' as p;

/// Compiling a C++ script from the editor.
///
/// The editor builds and checks; it does not load. Loading a script means
/// running somebody's native code inside the editor's own process, and a
/// script with a bad pointer would take the editor down with it along with
/// whatever was unsaved. The runtime loads them; this is the part that says
/// whether it could.
///
/// The same package does both, so what the editor checks against is exactly
/// what the runtime will load — a header that agreed with the editor and not
/// with the engine would be worse than no check at all.
class ScriptBuilder {
  ScriptBuilder(this.projectRoot);

  final String projectRoot;

  /// Where built libraries go: inside the project, out of the way, and
  /// disposable. Nothing here is worth keeping — every build makes a new one.
  Directory get output => Directory(p.join(projectRoot, '.orbis', 'build'));

  /// Null when nothing on this machine can compile C++.
  late final Toolchain? toolchain = Toolchain.find();

  /// The engine headers a script is compiled against.
  ///
  /// Found rather than configured, in the order of what is most likely to be
  /// right: what somebody said explicitly, then the package config, then the
  /// packages themselves.
  late final List<String> includes = _findIncludes();

  /// The packages whose `include` folders a script needs.
  static const _packages = ['orbis_native', 'orbis_core'];

  static List<String> _findIncludes() {
    final said = Platform.environment['ORBIS_INCLUDE'];
    if (said != null && said.isNotEmpty) {
      return said.split(Platform.isWindows ? ';' : ':');
    }

    final fromConfig = _fromPackageConfig();
    if (fromConfig.isNotEmpty) return fromConfig;

    try {
      // Works in a plain Dart VM. Flutter's isolate does not support it, so
      // this is the last resort rather than the first.
      return ScriptRunner.engineIncludes();
    } on Object {
      return const [];
    }
  }

  /// The include folders named by the running build's own package config.
  ///
  /// Walked up from the working directory, which is the editor's package root
  /// when it is run from source and under test. A packaged editor has no
  /// package config and carries the headers beside it instead; ORBIS_INCLUDE
  /// is how it says where.
  static List<String> _fromPackageConfig() {
    File? config;
    for (var at = Directory.current;; at = at.parent) {
      final candidate =
          File(p.join(at.path, '.dart_tool', 'package_config.json'));
      if (candidate.existsSync()) {
        config = candidate;
        break;
      }
      if (at.parent.path == at.path) break;
    }
    if (config == null) return const [];

    final Object? parsed;
    try {
      parsed = jsonDecode(config.readAsStringSync());
    } on Object {
      return const [];
    }
    if (parsed is! Map<String, Object?>) return const [];

    final listed = parsed['packages'];
    if (listed is! List) return const [];

    final found = <String>[];
    for (final entry in listed) {
      if (entry is! Map<String, Object?>) continue;
      if (!_packages.contains(entry['name'])) continue;

      final root = entry['rootUri'];
      if (root is! String) continue;

      // Relative to the config file's own folder, which is what the format
      // says and what a path dependency always is.
      final resolved = config.uri.resolve(
        root.endsWith('/') ? root : '$root/',
      );
      final include = resolved.resolve('include/');
      if (Directory.fromUri(include).existsSync()) {
        found.add(include.toFilePath());
      }
    }
    return found;
  }

  /// What went wrong before a compiler was even reached, or null.
  String? get problem {
    if (toolchain == null) {
      return 'No C++ compiler found. Install the Xcode command line tools, '
          'or clang, or gcc, and try again.';
    }
    if (includes.isEmpty) {
      return 'The engine headers could not be found. Set ORBIS_INCLUDE to the '
          'include folders of orbis_native and orbis_core.';
    }
    return null;
  }

  /// Compiles one source file.
  ///
  /// The revision comes from the clock rather than a counter, because every
  /// build has to go to a file of its own — a library already loaded cannot be
  /// closed, and reusing a path is how a rebuilt script goes on running the
  /// old code.
  BuildResult build(String path) {
    final stopped = problem;
    if (stopped != null) {
      return BuildResult(library: null, output: stopped, command: '');
    }

    return toolchain!.compile(
      File(path),
      into: output,
      includes: includes,
      revision: DateTime.now().millisecondsSinceEpoch % 100000,
    );
  }
}
