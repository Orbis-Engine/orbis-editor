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
  /// Found by the same code the runtime uses, so the header the editor checks
  /// against cannot differ from the one a script is loaded through. A packaged
  /// editor has no package config to read and carries the headers instead;
  /// ORBIS_INCLUDE is how it says where.
  late final List<String> includes = ScriptRunner.engineIncludes();

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
