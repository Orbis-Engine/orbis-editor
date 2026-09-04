import 'package:flutter/material.dart';

import 'src/editor/editor_shell.dart';
import 'src/launcher/launcher_screen.dart';
import 'src/launcher/project.dart';
import 'src/theme/orbis_theme.dart';

void main() => runApp(const OrbisEditorApp());

class OrbisEditorApp extends StatelessWidget {
  const OrbisEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbis',
      debugShowCheckedModeBanner: false,
      theme: orbisTheme(),
      home: const EditorRoot(),
    );
  }
}

/// Switches between the launcher and the editor.
///
/// One or the other, never both: an editor with no project has nothing honest
/// to show, and a launcher over an open project is a modal in disguise.
class EditorRoot extends StatefulWidget {
  const EditorRoot({super.key});

  @override
  State<EditorRoot> createState() => _EditorRootState();
}

class _EditorRootState extends State<EditorRoot> {
  Project? _open;

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
