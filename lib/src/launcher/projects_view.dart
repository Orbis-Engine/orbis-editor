import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'launcher_screen.dart' show ago;
import 'project.dart';

/// The list of projects the editor has opened.
class ProjectsView extends StatelessWidget {
  const ProjectsView({
    super.key,
    required this.loading,
    required this.projects,
    required this.onOpen,
    required this.onForget,
    required this.onCreate,
  });

  final bool loading;
  final List<Project> projects;
  final ValueChanged<Project> onOpen;
  final ValueChanged<Project> onForget;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xxl, Space.xxl, Space.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Projects', style: OrbisText.display),
                  const SizedBox(height: Space.xs),
                  Text(
                    projects.isEmpty
                        ? 'Nothing here yet.'
                        : '${projects.length} recent',
                    style: OrbisText.caption,
                  ),
                ],
              ),
              const Spacer(),
              OrbisButton(
                label: 'New project',
                icon: Icons.add,
                tone: ButtonTone.primary,
                onPressed: onCreate,
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const SizedBox.shrink()
              : projects.isEmpty
                  ? _Empty(onCreate: onCreate)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                          Space.xxl, 0, Space.xxl, Space.xxl),
                      itemCount: projects.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Space.sm),
                      itemBuilder: (context, index) => ProjectRow(
                        project: projects[index],
                        onOpen: () => onOpen(projects[index]),
                        onForget: () => onForget(projects[index]),
                      ),
                    ),
        ),
      ],
    );
  }
}

/// One project in the list.
class ProjectRow extends StatefulWidget {
  const ProjectRow({
    super.key,
    required this.project,
    required this.onOpen,
    required this.onForget,
  });

  final Project project;
  final VoidCallback onOpen;
  final VoidCallback onForget;

  @override
  State<ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<ProjectRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // A project whose folder has gone is shown rather than hidden, so somebody
    // who moved a directory sees why it will not open instead of wondering
    // where their work went.
    final missing = !widget.project.exists;

    return MouseRegion(
      cursor: missing ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: _hovering ? OrbisColors.raised : OrbisColors.surface,
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(
              color: _hovering ? OrbisColors.line : OrbisColors.lineSoft,
            ),
          ),
          child: Row(
            children: [
              _Thumbnail(missing: missing),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.project.name,
                            overflow: TextOverflow.ellipsis,
                            style: OrbisText.title.copyWith(
                              fontSize: 14,
                              color: missing
                                  ? OrbisColors.inkDim
                                  : OrbisColors.ink,
                            ),
                          ),
                        ),
                        if (missing) ...[
                          const SizedBox(width: Space.sm),
                          const _Tag('moved', tone: OrbisColors.warn),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.project.displayPath,
                      overflow: TextOverflow.ellipsis,
                      style: OrbisText.mono,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              Text(ago(widget.project.lastOpened), style: OrbisText.caption),
              SizedBox(
                width: 34,
                child: _hovering
                    ? _IconAction(
                        icon: Icons.close,
                        tooltip: 'Remove from this list',
                        onTap: widget.onForget,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stands in for a scene thumbnail until scenes can render one.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.missing});

  final bool missing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Icon(
        missing ? Icons.link_off : Icons.view_in_ar_outlined,
        size: 19,
        color: missing ? OrbisColors.inkDim : OrbisColors.emberDeep,
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: tone.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: OrbisText.caption.copyWith(fontSize: 10, color: tone),
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          // Stops the row's own tap from firing and opening the project.
          onTap: () => widget.onTap(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovering ? OrbisColors.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hovering ? OrbisColors.ink : OrbisColors.inkDim,
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: OrbisColors.surface,
                borderRadius: BorderRadius.circular(Radii.panel),
                border: Border.all(color: OrbisColors.lineSoft),
              ),
              child: const Icon(Icons.view_in_ar_outlined,
                  size: 28, color: OrbisColors.inkDim),
            ),
            const SizedBox(height: Space.lg),
            Text('No projects yet', style: OrbisText.title),
            const SizedBox(height: Space.sm),
            Text(
              'Make one, or open a folder that already has an '
              '$projectFileName in it.',
              textAlign: TextAlign.center,
              style: OrbisText.body,
            ),
            const SizedBox(height: Space.xl),
            OrbisButton(
              label: 'New project',
              icon: Icons.add,
              tone: ButtonTone.primary,
              onPressed: onCreate,
            ),
          ],
        ),
      ),
    );
  }
}
