import 'package:flutter/material.dart';

import 'src/editor/editor_shell.dart';
import 'src/launcher/launcher_screen.dart';
import 'src/launcher/project.dart';
import 'src/launcher/splash.dart';
import 'src/theme/orbis_theme.dart';

/// Opens the editor, on a project if one was named.
///
/// `orbis_editor ~/Documents/Orbis/Thing` the way `blender file.blend` and
/// `code .` work — and the only way to reach the editor without clicking,
/// which matters for anything driving it from a script.
void main(List<String> arguments) {
  final path = projectPathIn(arguments);
  final project = path == null ? null : ProjectStore().open(path);
  if (path != null && project == null) {
    // Said out loud rather than falling back to the launcher in silence,
    // which looks like the argument was ignored.
    debugPrint('Orbis: "$path" is not a project folder.');
  }
  runApp(OrbisEditorApp(initialProject: project));
}

/// The folder to open out of what the app was launched with.
///
/// macOS puts its own switches in — `-NSDocumentRevisionsDebugMode YES` when
/// a debug build is started by Xcode, among others — so anything beginning
/// with a dash is not a path somebody typed, and neither is the value that
/// follows it.
String? projectPathIn(List<String> arguments) {
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument.startsWith('-')) {
      // Skip its value as well, or `-NSDocumentRevisionsDebugMode YES` opens
      // a project called YES and reports it missing.
      if (i + 1 < arguments.length && !arguments[i + 1].startsWith('-')) i++;
      continue;
    }
    return argument;
  }
  return null;
}

class OrbisEditorApp extends StatelessWidget {
  const OrbisEditorApp({super.key, this.initialProject});

  final Project? initialProject;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbis',
      debugShowCheckedModeBanner: false,
      theme: orbisTheme(),
      // The mark first, over whatever is starting behind it. Something has to
      // be on screen while the window, the renderer and the project list are
      // all still coming up, and a blank frame reads as an app that failed to
      // open.
      home: OrbisSplash(
        child: EditorRoot(initialProject: initialProject),
      ),
    );
  }
}

/// Switches between the launcher and the editor.
///
/// One or the other, never both: an editor with no project has nothing honest
/// to show, and a launcher over an open project is a modal in disguise.
class EditorRoot extends StatefulWidget {
  const EditorRoot({super.key, this.initialProject});

  final Project? initialProject;

  @override
  State<EditorRoot> createState() => _EditorRootState();
}

class _EditorRootState extends State<EditorRoot> {
  late Project? _open = widget.initialProject;

  @override
  Widget build(BuildContext context) {
    final project = _open;

    // Cross-faded rather than pushed: opening a project is a change of mode,
    // not a place you navigated to, and a back gesture should not undo it.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      child: project == null
          ? LauncherScreen(
              key: const ValueKey('launcher'),
              onOpen: (project) => setState(() => _open = project),
            )
          : EditorShell(
              key: ValueKey(project.directory),
              project: project,
              onClose: () => setState(() => _open = null),
            ),
    );
  }
}
