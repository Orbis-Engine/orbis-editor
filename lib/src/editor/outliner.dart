import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';
import 'scene.dart';

/// What is in the scene, as a tree.
class Outliner extends StatelessWidget {
  const Outliner({
    super.key,
    required this.scene,
    required this.selected,
    required this.onSelect,
  });

  final EditorScene scene;
  final String selected;
  final ValueChanged<String> onSelect;

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
              itemCount: scene.objects.length,
              itemBuilder: (context, index) {
                final object = scene.objects[index];
                return _OutlinerRow(
                  object: object,
                  // Everything hangs off the scene root until parenting is a
                  // thing the document can express.
                  depth: object.kind == ObjectKind.scene ? 0 : 1,
                  selected: object.name == selected,
                  onTap: () => onSelect(object.name),
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
    required this.object,
    required this.depth,
    required this.selected,
    required this.onTap,
  });

  final SceneObject object;
  final int depth;
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
            left: Space.md + widget.depth * 14.0,
            right: Space.md,
          ),
          color: widget.selected
              ? OrbisColors.emberWash
              : (_hovering ? OrbisColors.raised : Colors.transparent),
          child: Row(
            children: [
              Icon(widget.object.icon, size: 14, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  widget.object.name,
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
