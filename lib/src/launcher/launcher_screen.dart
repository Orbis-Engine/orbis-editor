import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'create_view.dart';
import 'examples_view.dart';
import 'project.dart';
import 'projects_view.dart';

/// How long ago, in the shortest form that is still true.
String ago(DateTime then) {
  final elapsed = DateTime.now().difference(then);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  if (elapsed.inDays < 30) return '${elapsed.inDays}d ago';
  return '${(elapsed.inDays / 30).floor()}mo ago';
}

/// What the launcher is currently showing.
enum _View { projects, create, examples }

/// The first thing the editor shows.
///
/// A launcher rather than an empty editor, because an editor with no project
/// open has nothing true to display: every panel would be an empty state, and
/// a screen full of empty states is worse than a screen that asks one question.
class LauncherScreen extends StatefulWidget {
  const LauncherScreen({super.key, required this.onOpen});

  /// Called once a project is chosen or created. The shell takes it from here.
  final ValueChanged<Project> onOpen;

  @override
  State<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends State<LauncherScreen> {
  /// Whether an example has asked for the whole window.
  ///
  /// The rail goes with it. A full view of a scene with a navigation rail
  /// down the side of it is not a full view, and the way back is the button
  /// the example view puts where a project puts its own.
  bool _full = false;

  final ProjectStore _store = ProjectStore();
  _View _view = _View.projects;
  List<Project> _recents = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final recents = await _store.recents();
    if (!mounted) return;
    setState(() {
      _recents = recents;
      _loading = false;
    });
  }

  Future<void> _openFolder() async {
    final directory = await getDirectoryPath(confirmButtonText: 'Open');
    if (directory == null) return;

    final project = _store.open(directory);
    if (project == null) {
      if (!mounted) return;
      _complain('No Orbis project there',
          'That folder has no $projectFileName in it.');
      return;
    }
    await _store.remember(project);
    widget.onOpen(project);
  }

  void _complain(String title, String detail) {
    showDialog<void>(
      context: context,
      builder: (context) => _Complaint(title: title, detail: detail),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_full)
            _Rail(
              view: _view,
              onView: (view) => setState(() => _view = view),
              onOpenFolder: _openFolder,
            ),
          Expanded(
            child: Container(
              color: OrbisColors.ground,
              child: switch (_view) {
                _View.projects => ProjectsView(
                    loading: _loading,
                    projects: _recents,
                    onOpen: (project) async {
                      if (!project.exists) {
                        _complain('That folder has moved',
                            '${project.displayPath} no longer holds a project.');
                        return;
                      }
                      await _store.remember(project);
                      widget.onOpen(project);
                    },
                    onForget: (project) async {
                      await _store.forget(project);
                      await _load();
                    },
                    onCreate: () => setState(() => _view = _View.create),
                  ),
                _View.create => CreateView(
                    store: _store,
                    onCancel: () => setState(() => _view = _View.projects),
                    onCreated: widget.onOpen,
                    onFailed: _complain,
                  ),
                // Kept alive behind the other two, so switching away and back
                // does not restart whatever was running — an example with a
                // day cycle in it is worth leaving where it was.
                _View.examples => ExamplesView(
                    onFull: (full) => setState(() => _full = full),
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The left rail: identity, then the two things a launcher can do.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.view,
    required this.onView,
    required this.onOpenFolder,
  });

  final _View view;
  final ValueChanged<_View> onView;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.xxl, Space.lg, Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _Mark(),
              const SizedBox(width: Space.md),
              // Constrained rather than left to its natural width: the rail is
              // a fixed size and the version string is not, so an unbounded
              // column here overflows the moment either changes.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Orbis',
                        style: OrbisText.title, overflow: TextOverflow.ellipsis),
                    Text(
                      'Engine 0.1.0 · pre-alpha',
                      style: OrbisText.caption.copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xl),
          _RailItem(
            label: 'Projects',
            icon: Icons.folder_outlined,
            selected: view == _View.projects,
            onTap: () => onView(_View.projects),
          ),
          _RailItem(
            label: 'New project',
            icon: Icons.add_box_outlined,
            selected: view == _View.create,
            onTap: () => onView(_View.create),
          ),
          _RailItem(
            label: 'Examples',
            icon: Icons.auto_stories_outlined,
            selected: view == _View.examples,
            onTap: () => onView(_View.examples),
          ),
          const Spacer(),
          OrbisButton(
            label: 'Open a folder…',
            icon: Icons.folder_open_outlined,
            tone: ButtonTone.quiet,
            expand: true,
            onPressed: onOpenFolder,
          ),
        ],
      ),
    );
  }
}

/// The mark. A cube seen corner-on, which is both what the engine draws first
/// and the shape an orbit is drawn around.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [OrbisColors.ember, OrbisColors.emberDeep],
        ),
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: const Center(
        child: Icon(Icons.view_in_ar_outlined, size: 18, color: Color(0xFF1A1206)),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colour = widget.selected
        ? OrbisColors.ember
        : (_hovering ? OrbisColors.ink : OrbisColors.inkMid);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.only(bottom: Space.xs),
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          decoration: BoxDecoration(
            // Selection is a wash rather than a fill: the rail should read as
            // one surface with something marked on it, not as stacked buttons.
            color: widget.selected
                ? OrbisColors.emberWash
                : (_hovering ? OrbisColors.raised : Colors.transparent),
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: colour),
              const SizedBox(width: Space.md),
              Text(
                widget.label,
                style: OrbisText.label.copyWith(
                  color: colour,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Complaint extends StatelessWidget {
  const _Complaint({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: OrbisPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: OrbisText.title),
              const SizedBox(height: Space.sm),
              Text(detail, style: OrbisText.body),
              const SizedBox(height: Space.lg),
              Align(
                alignment: Alignment.centerRight,
                child: OrbisButton(
                  label: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
