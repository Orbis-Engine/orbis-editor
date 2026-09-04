import 'package:flutter/material.dart';

import '../launcher/project.dart';
import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart';
import 'outliner.dart';
import 'scene.dart';
import 'viewport.dart';

/// The editor, once a project is open.
///
/// Regions rather than free-floating windows: a fixed rail, an outliner, the
/// viewport, an inspector and a status bar. Docking comes later, and it comes
/// more easily to a layout that already knows what its regions are.
class EditorShell extends StatefulWidget {
  const EditorShell({
    super.key,
    required this.project,
    required this.onClose,
  });

  final Project project;

  /// Back to the launcher.
  final VoidCallback onClose;

  @override
  State<EditorShell> createState() => _EditorShellState();
}

class _EditorShellState extends State<EditorShell> {
  final EditorScene _scene = EditorScene.starter();
  String _selected = 'Cube';
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OrbisColors.ground,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            project: widget.project,
            playing: _playing,
            onPlay: () => setState(() => _playing = !_playing),
            onClose: widget.onClose,
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Outliner(
                  scene: _scene,
                  selected: _selected,
                  onSelect: (name) => setState(() => _selected = name),
                ),
                Expanded(child: SceneViewport(scene: _scene)),
                Inspector(
                  object: _scene.byName(_selected),
                  // The scene is edited in place, so the rebuild is what
                  // carries the change to the outliner and the renderer.
                  onChanged: () => setState(() {}),
                ),
              ],
            ),
          ),
          _StatusBar(objects: _scene.objects.length),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.project,
    required this.playing,
    required this.onPlay,
    required this.onClose,
  });

  final Project project;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          OrbisButton(
            label: project.name,
            icon: Icons.chevron_left,
            tone: ButtonTone.quiet,
            onPressed: onClose,
          ),
          const Spacer(),
          // Transport in the centre, where it is in every editor that has one,
          // because muscle memory is worth more than novelty here.
          _TransportButton(
            icon: playing ? Icons.pause : Icons.play_arrow,
            tooltip: playing ? 'Pause' : 'Play',
            active: playing,
            onTap: onPlay,
          ),
          const SizedBox(width: Space.xs),
          _TransportButton(
            icon: Icons.stop,
            tooltip: 'Stop',
            active: false,
            onTap: () {},
          ),
          const Spacer(),
          Text('pre-alpha', style: OrbisText.caption),
        ],
      ),
    );
  }
}

class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
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
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? OrbisColors.emberWash
                  : (_hovering ? OrbisColors.raised : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: widget.active
                  ? OrbisColors.ember
                  : (_hovering ? OrbisColors.ink : OrbisColors.inkMid),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.objects});

  final int objects;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(top: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          Text('Ready', style: OrbisText.caption.copyWith(fontSize: 11)),
          const Spacer(),
          Text('$objects objects', style: OrbisText.mono.copyWith(fontSize: 11)),
          const SizedBox(width: Space.lg),
          Text('— fps', style: OrbisText.mono.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}
