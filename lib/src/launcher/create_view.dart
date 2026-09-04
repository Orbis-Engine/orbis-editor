import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'project.dart';

/// Making a new project.
class CreateView extends StatefulWidget {
  const CreateView({
    super.key,
    required this.store,
    required this.onCancel,
    required this.onCreated,
    required this.onFailed,
  });

  final ProjectStore store;
  final VoidCallback onCancel;
  final ValueChanged<Project> onCreated;
  final void Function(String title, String detail) onFailed;

  @override
  State<CreateView> createState() => _CreateViewState();
}

class _CreateViewState extends State<CreateView> {
  final TextEditingController _name =
      TextEditingController(text: 'Untitled Project');
  late final TextEditingController _location = TextEditingController(
    // Defaults somewhere real rather than empty, so the common case is one
    // click. Documents rather than home: a project is a document.
    text: p.join(
      Platform.environment['HOME'] ?? Directory.current.path,
      'Documents',
      'Orbis',
    ),
  );

  ProjectTemplate _template = ProjectTemplate.scene;
  bool _creating = false;

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    super.dispose();
  }

  /// Where the folder will actually land, shown before it is made so nobody is
  /// surprised by where their project went.
  String get _destination {
    final slug = _name.text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return p.join(_location.text, slug.isEmpty ? 'orbis-project' : slug);
  }

  Future<void> _browse() async {
    final directory = await getDirectoryPath(confirmButtonText: 'Choose');
    if (directory == null) return;
    setState(() => _location.text = directory);
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      widget.onFailed('A project needs a name', 'Give it one and try again.');
      return;
    }

    setState(() => _creating = true);
    try {
      final project = await widget.store.create(
        name: _name.text.trim(),
        parentDirectory: _location.text,
        template: _template,
      );
      widget.onCreated(project);
    } on StateError catch (error) {
      if (mounted) setState(() => _creating = false);
      widget.onFailed('Could not create it', error.message);
    } on FileSystemException catch (error) {
      if (mounted) setState(() => _creating = false);
      widget.onFailed('Could not write there', error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.xxl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New project', style: OrbisText.display),
            const SizedBox(height: Space.xs),
            Text('A folder, a scene, and somewhere to put assets.',
                style: OrbisText.caption),
            const SizedBox(height: Space.xl),

            const SectionLabel('Name'),
            OrbisField(
              controller: _name,
              autofocus: true,
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: Space.lg),

            const SectionLabel('Location'),
            OrbisField(
              controller: _location,
              mono: true,
              suffix: OrbisButton(
                label: 'Browse',
                tone: ButtonTone.quiet,
                onPressed: _browse,
              ),
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right,
                    size: 13, color: OrbisColors.inkDim),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_name, _location]),
                    builder: (context, _) => Text(
                      _destination,
                      overflow: TextOverflow.ellipsis,
                      style: OrbisText.mono,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.xl),

            const SectionLabel('Start from'),
            for (final template in ProjectTemplate.values)
              _TemplateCard(
                template: template,
                selected: _template == template,
                onTap: () => setState(() => _template = template),
              ),
            const SizedBox(height: Space.xl),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OrbisButton(
                  label: 'Cancel',
                  tone: ButtonTone.quiet,
                  onPressed: _creating ? null : widget.onCancel,
                ),
                const SizedBox(width: Space.sm),
                OrbisButton(
                  label: _creating ? 'Creating…' : 'Create project',
                  icon: Icons.check,
                  tone: ButtonTone.primary,
                  onPressed: _creating ? null : _create,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateCard extends StatefulWidget {
  const _TemplateCard({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final ProjectTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends State<_TemplateCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          margin: const EdgeInsets.only(bottom: Space.sm),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: widget.selected
                ? OrbisColors.emberWash
                : (_hovering ? OrbisColors.raised : OrbisColors.surface),
            borderRadius: BorderRadius.circular(Radii.panel),
            border: Border.all(
              color: widget.selected
                  ? OrbisColors.ember
                  : (_hovering ? OrbisColors.line : OrbisColors.lineSoft),
            ),
          ),
          child: Row(
            children: [
              // A radio rather than a tick: these are exclusive, and the
              // control should say so before it is read.
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.selected
                        ? OrbisColors.ember
                        : OrbisColors.line,
                    width: 1.5,
                  ),
                ),
                child: widget.selected
                    ? Center(
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: OrbisColors.ember,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.template.label,
                      style: OrbisText.label.copyWith(
                        color: OrbisColors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(widget.template.description,
                        style: OrbisText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
