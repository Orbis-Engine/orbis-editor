import 'dart:io';

/// Handing a file or a folder to whatever somebody writes code in.
///
/// The engine has no text editor of its own and is not going to grow one.
/// Scripts are ordinary files in an ordinary folder, so the useful thing the
/// editor can do is get out of the way quickly: open the project where the
/// person already has their extensions, their keybindings and their terminal.
class CodeEditor {
  const CodeEditor._();

  /// Editors worth trying, best first.
  ///
  /// Command first because a command respects `--goto`, opens into the
  /// existing window, and returns immediately. The bundle is the fallback for
  /// the very common case of somebody who installed VS Code but never ran
  /// "Install 'code' command in PATH".
  static const _candidates = <_Editor>[
    _Editor('code', 'Visual Studio Code', 'com.microsoft.VSCode'),
    _Editor('cursor', 'Cursor', 'com.todesktop.230313mzl4w4u92'),
    _Editor('code-insiders', 'Visual Studio Code - Insiders',
        'com.microsoft.VSCodeInsiders'),
    _Editor('subl', 'Sublime Text', 'com.sublimetext.4'),
    _Editor('zed', 'Zed', 'dev.zed.Zed'),
  ];

  /// What is installed, as a name to show on the menu, or null.
  ///
  /// Cached, because it is asked for on every rebuild of the menu bar and the
  /// answer only changes when somebody installs an editor mid-session.
  static String? _found;
  static bool _looked = false;

  static String? get available {
    if (_looked) return _found;
    _looked = true;
    for (final editor in _candidates) {
      if (_onPath(editor.command) || _installed(editor)) {
        _found = editor.label;
        return _found;
      }
    }
    return null;
  }

  /// Forgets what was found. For tests, and for after an install.
  static void forget() {
    _looked = false;
    _found = null;
  }

  /// Opens a folder, and optionally puts the cursor in one file inside it.
  ///
  /// Returns what went wrong, or null. Opening the folder rather than the
  /// file is deliberate even when a file is named: an editor with the project
  /// root open can find the rest of the scripts, the type definitions and the
  /// stylesheet next to it.
  static String? open(String folder, {String? file}) {
    if (!Directory(folder).existsSync()) {
      return 'That folder is not there any more.';
    }

    for (final editor in _candidates) {
      if (_onPath(editor.command)) {
        final arguments = <String>[
          folder,
          if (file != null) ...['--goto', file],
        ];
        if (_run(editor.command, arguments)) return null;
      }
    }

    // No command on the PATH. On macOS the app can still be opened by bundle
    // identifier, which is how most people have it installed.
    if (Platform.isMacOS) {
      for (final editor in _candidates) {
        if (!_installed(editor)) continue;
        final arguments = <String>[
          '-b', editor.bundle,
          folder,
          ?file,
        ];
        if (_run('open', arguments)) return null;
      }
    }

    return 'No code editor found. Install VS Code, or its "code" command '
        'from the command palette.';
  }

  /// Shows the folder in Finder, Explorer or whatever the desktop uses.
  ///
  /// The fallback for somebody with no editor installed, and useful on its
  /// own: a project is a folder, and sometimes the answer is to look at it.
  static String? reveal(String path) {
    if (!Directory(path).existsSync() && !File(path).existsSync()) {
      return 'That is not there any more.';
    }
    final command = Platform.isMacOS
        ? 'open'
        : (Platform.isWindows ? 'explorer' : 'xdg-open');
    return _run(command, [path]) ? null : 'Could not open $path.';
  }

  static bool _run(String command, List<String> arguments) {
    try {
      // Detached: the editor outlives this process, and waiting on one that
      // does not fork would hang the frame.
      Process.start(
        command,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on ProcessException {
      return false;
    }
  }

  static bool _onPath(String command) {
    try {
      final which = Platform.isWindows ? 'where' : 'which';
      return Process.runSync(which, [command]).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static bool _installed(_Editor editor) {
    if (!Platform.isMacOS) return false;
    try {
      // -b names the bundle without launching it, so this answers "is it
      // there" without a window appearing.
      final found = Process.runSync(
        'open',
        ['-Ra', editor.label],
      );
      return found.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

class _Editor {
  const _Editor(this.command, this.label, this.bundle);

  final String command;
  final String label;
  final String bundle;
}
