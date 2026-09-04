import 'package:flutter/material.dart';

import 'src/editor/editor_shell.dart';
import 'src/launcher/launcher_screen.dart';
import 'src/launcher/project.dart';
import 'src/theme/orbis_theme.dart';

/// Opens the editor, on a project if one was named.
///
/// `orbis_editor ~/Documents/Orbis/Thing` the way `blender file.blend` and
/// `code .` work — and the only way to reach the editor without clicking,
/// which matters for anything driving it from a script.
void main(List<String> arguments) {
  final path = arguments.where((argument) => !argument.startsWith('-')).firstOrNull;
  final project = path == null ? null : ProjectStore().open(path);
  if (path != null && project == null) {
    // Said out loud rather than falling back to the launcher in silence,
    // which looks like the argument was ignored.
    debugPrint('Orbis: "$path" is not a project folder.');
  }
  runApp(OrbisEditorApp(initialProject: project));
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
      home: EditorRoot(initialProject: initialProject),
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
