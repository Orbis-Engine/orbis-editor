import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/orbis_theme.dart';
import 'assets.dart';

/// The project's files, along the bottom.
///
/// Along the bottom rather than beside the outliner, because the two answer
/// different questions — what is *in* this scene, against what this project
/// *has* — and stacking them in one column makes each look like part of the
/// other.
class AssetBrowser extends StatefulWidget {
  const AssetBrowser({super.key, required this.tree, required this.height});

  final AssetTree tree;
  final double height;

  @override
  State<AssetBrowser> createState() => _AssetBrowserState();
}

class _AssetBrowserState extends State<AssetBrowser> {
  late String _directory = widget.tree.root;
  String? _selected;

  /// Bumped to force a re-read. The list is a snapshot of a folder somebody
  /// else can change, so refreshing is explicit rather than pretended.
  int _revision = 0;

  @override
  void didUpdateWidget(AssetBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree.root != widget.tree.root) {
      _directory = widget.tree.root;
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Read once per build rather than per row.
    final entries = widget.tree.read(_directory);
    final folders = widget.tree.folders();

    return SizedBox(
      height: widget.height,
      child: Container(
        decoration: const BoxDecoration(
          color: OrbisColors.surface,
          border: Border(top: BorderSide(color: OrbisColors.lineSoft)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              crumb: widget.tree.relative(_directory),
              count: entries.length,
              canGoUp: !p.equals(_directory, widget.tree.root),
              onUp: () => setState(() {
                _directory = p.dirname(_directory);
                _selected = null;
              }),
              onRefresh: () => setState(() => _revision++),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FolderTree(
                    key: ValueKey(_revision),
                    tree: widget.tree,
                    folders: folders,
                    current: _directory,
                    onOpen: (path) => setState(() {
                      _directory = path;
                      _selected = null;
                    }),
                  ),
                  Expanded(
                    child: _Grid(
                      key: ValueKey('$_directory/$_revision'),
                      entries: entries,
                      selected: _selected,
                      onSelect: (asset) =>
                          setState(() => _selected = asset.path),
                      onOpen: (asset) {
                        if (!asset.isFolder) return;
                        setState(() {
                          _directory = asset.path;
                          _selected = null;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.crumb,
    required this.count,
    required this.canGoUp,
    required this.onUp,
    required this.onRefresh,
  });

  final String crumb;
  final int count;
  final bool canGoUp;
  final VoidCallback onUp;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          _IconAction(
            icon: Icons.arrow_upward,
            tooltip: 'Up one folder',
            enabled: canGoUp,
            onTap: onUp,
          ),
          const SizedBox(width: Space.sm),
          Text('PROJECT', style: OrbisText.section),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              crumb.isEmpty ? '/' : crumb,
              overflow: TextOverflow.ellipsis,
              style: OrbisText.mono.copyWith(fontSize: 11),
            ),
          ),
          const Spacer(),
          Text(
            '$count item${count == 1 ? '' : 's'}',
            style: OrbisText.caption.copyWith(fontSize: 11),
          ),
          const SizedBox(width: Space.xs),
          _IconAction(
            icon: Icons.refresh,
            tooltip: 'Read the folder again',
            enabled: true,
            onTap: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              icon,
              size: 14,
              color: enabled ? OrbisColors.inkMid : OrbisColors.lineSoft,
            ),
          ),
        ),
      ),
    );
  }
}

/// The folders, down the left.
class _FolderTree extends StatelessWidget {
  const _FolderTree({
    super.key,
    required this.tree,
    required this.folders,
    required this.current,
    required this.onOpen,
  });

  final AssetTree tree;
  final List<({String path, int depth})> folders;
  final String current;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 176,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        children: [
          _FolderRow(
            name: 'Project',
            depth: 0,
            icon: Icons.home_outlined,
            selected: p.equals(current, tree.root),
            onTap: () => onOpen(tree.root),
          ),
          for (final folder in folders)
            _FolderRow(
              name: p.basename(folder.path),
              depth: folder.depth + 1,
              icon: Icons.folder_outlined,
              selected: p.equals(current, folder.path),
              onTap: () => onOpen(folder.path),
            ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    required this.name,
    required this.depth,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final int depth;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
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
          height: 24,
          padding: EdgeInsets.only(
            left: Space.sm + widget.depth * 12.0,
            right: Space.sm,
          ),
          color: widget.selected
              ? OrbisColors.emberWash
              : (_hovering ? OrbisColors.raised : Colors.transparent),
          child: Row(
            children: [
              Icon(widget.icon, size: 13, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: OrbisText.label.copyWith(fontSize: 11.5, color: colour),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The files in the current folder.
class _Grid extends StatelessWidget {
  const _Grid({
    super.key,
    required this.entries,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final List<Asset> entries;
  final String? selected;
  final ValueChanged<Asset> onSelect;
  final ValueChanged<Asset> onOpen;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Text('This folder is empty.', style: OrbisText.caption),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(Space.sm),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 96,
        mainAxisExtent: 84,
        crossAxisSpacing: Space.xs,
        mainAxisSpacing: Space.xs,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final asset = entries[index];
        return _Tile(
          asset: asset,
          selected: asset.path == selected,
          onTap: () => onSelect(asset),
          onDoubleTap: () => onOpen(asset),
        );
      },
    );
  }
}

class _Tile extends StatefulWidget {
  const _Tile({
    required this.asset,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
  });

  final Asset asset;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;

    return Tooltip(
      message: '${asset.name}\n${asset.kind.label}'
          '${asset.bytes == null ? '' : ' · ${asset.size}'}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            decoration: BoxDecoration(
              color: widget.selected
                  ? OrbisColors.emberWash
                  : (_hovering ? OrbisColors.raised : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(
                color: widget.selected
                    ? OrbisColors.ember
                    : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  asset.kind.icon,
                  size: 26,
                  color: asset.isFolder
                      ? OrbisColors.inkMid
                      : (widget.selected
                          ? OrbisColors.ember
                          : OrbisColors.inkDim),
                ),
                const SizedBox(height: Space.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    asset.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: OrbisText.label.copyWith(
                      fontSize: 11,
                      color: widget.selected
                          ? OrbisColors.ink
                          : OrbisColors.inkMid,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
