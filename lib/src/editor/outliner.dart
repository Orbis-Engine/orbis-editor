import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';

/// One thing in the scene.
class SceneEntry {
  const SceneEntry(this.name, this.icon, {this.depth = 0});

  final String name;
  final IconData icon;
  final int depth;
}

/// What is in the scene, as a tree.
class Outliner extends StatelessWidget {
  const Outliner({super.key, required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  // Standing in for a loaded scene until the document format exists.
  static const _entries = [
    SceneEntry('Scene', Icons.public, depth: 0),
    SceneEntry('Sun', Icons.wb_sunny_outlined, depth: 1),
    SceneEntry('Ground', Icons.grid_on, depth: 1),
    SceneEntry('Cube', Icons.view_in_ar_outlined, depth: 1),
    SceneEntry('Camera', Icons.videocam_outlined, depth: 1),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Text('OUTLINER', style: OrbisText.section),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return _OutlinerRow(
                  entry: entry,
                  selected: entry.name == selected,
                  onTap: () => onSelect(entry.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OutlinerRow extends StatefulWidget {
  const _OutlinerRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final SceneEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_OutlinerRow> createState() => _OutlinerRowState();
}

class _OutlinerRowState extends State<_OutlinerRow> {
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
          height: 26,
          padding: EdgeInsets.only(
            left: Space.md + widget.entry.depth * 14.0,
            right: Space.md,
          ),
          color: widget.selected
              ? OrbisColors.emberWash
              : (_hovering ? OrbisColors.raised : Colors.transparent),
          child: Row(
            children: [
              Icon(widget.entry.icon, size: 14, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  widget.entry.name,
                  overflow: TextOverflow.ellipsis,
                  style: OrbisText.label.copyWith(
                    color: colour,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
