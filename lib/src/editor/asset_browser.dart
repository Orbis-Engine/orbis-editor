import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'assets.dart';
import 'scene.dart';

/// The project's files, along the bottom.
///
/// Along the bottom rather than beside the outliner, because the two answer
/// different questions — what is *in* this scene, against what this project
/// *has* — and stacking them in one column makes each look like part of the
/// other.
class AssetBrowser extends StatefulWidget {
  const AssetBrowser({
    super.key,
    required this.tree,
    required this.height,
    this.onOpenAsset,
    this.onProblem,
    this.onMakePrefab,
  });

  final AssetTree tree;
  final double height;

  /// Called when somebody drags an object out of the scene and drops it here.
  ///
  /// The browser knows where it was dropped; the shell knows what the object
  /// is. This is where the two meet.
  final void Function(ObjectDrag object, String directory)? onMakePrefab;

  /// Called when somebody opens a file, rather than a folder.
  final ValueChanged<Asset>? onOpenAsset;

  /// Called when a file operation fails, so the shell can say so.
  final ValueChanged<String>? onProblem;

  @override
  State<AssetBrowser> createState() => _AssetBrowserState();
}

class _AssetBrowserState extends State<AssetBrowser> {
  late String _directory = widget.tree.root;
  String? _selected;

  /// Bumped to force a re-read, by the watcher or by the button.
  int _revision = 0;

  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _changes?.cancel();
    _changes = widget.tree.changes.listen((_) {
      if (mounted) setState(() => _revision++);
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(AssetBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree.root != widget.tree.root) {
      _directory = widget.tree.root;
      _selected = null;
      _listen();
    }
  }

  Future<void> _confirmDelete(Asset asset) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Delete ${asset.name}?', style: OrbisText.title),
        content: Text(
          asset.isFolder
              ? 'This deletes the folder and everything in it. It does not go '
                  'to the Trash, and undo does not cover files.'
              : 'This does not go to the Trash, and undo does not cover files.',
          style: OrbisText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (agreed != true) return;

    final problem = widget.tree.delete(asset.path);
    if (problem != null) {
      widget.onProblem?.call('Could not delete ${asset.name}: $problem');
      return;
    }
    if (mounted) {
      setState(() {
        _revision++;
        if (_selected == asset.path) _selected = null;
      });
    }
  }

  /// Makes a new folder or file in the folder being looked at.
  ///
  /// The name box opens with a suggestion already in it and the stem
  /// selected, so the common case is type-and-return. What comes out is
  /// opened straight away when it is a file: nobody asks for a new script in
  /// order to look at its icon.
  Future<void> _promptCreate(NewAsset what) async {
    final name = await promptForName(
      context,
      title: 'New ${what.label.toLowerCase()}',
      initial: what.suggested,
      hint: what.isFolder ? null : 'Adds ${what.extension} for you',
      action: 'Create',
    );
    if (name == null || !mounted) return;

    final made = widget.tree.create(_directory, what, name);
    if (made.problem != null) {
      widget.onProblem?.call('Could not create it: ${made.problem}');
      return;
    }

    setState(() {
      _revision++;
      _selected = made.path;
    });

    if (!what.isFolder && made.path != null) {
      widget.onOpenAsset?.call(widget.tree.describe(made.path!));
    }
  }

  Future<void> _promptRename(Asset asset) async {
    final name = await promptForName(
      context,
      title: 'Rename',
      initial: asset.name,
      action: 'Rename',
    );
    if (name == null || !mounted) return;

    final problem = widget.tree.rename(asset.path, name);
    if (problem != null) {
      widget.onProblem?.call('Could not rename ${asset.name}: $problem');
      return;
    }
    if (mounted) setState(() => _revision++);
  }

  @override
  Widget build(BuildContext context) {
    // Read once per build rather than per row.
    final entries = widget.tree.read(_directory);
    final folders = widget.tree.folders();

    return SizedBox(
      height: widget.height,
      // One menu for the whole panel: the header button, the empty space
      // between tiles and every file in the grid all open the same one,
      // rather than a menu controller per file in the project.
      child: AssetMenu(
        onCreate: _promptCreate,
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
                      onDropObject: widget.onMakePrefab,
                    ),
                    Expanded(
                      child: _Grid(
                        key: ValueKey('$_directory/$_revision'),
                        entries: entries,
                        selected: _selected,
                        onSelect: (asset) =>
                            setState(() => _selected = asset.path),
                        onDelete: _confirmDelete,
                        onRename: _promptRename,
                        onDropObject: widget.onMakePrefab == null
                            ? null
                            : (object) =>
                                widget.onMakePrefab!(object, _directory),
                        onOpen: (asset) {
                          if (!asset.isFolder) {
                            widget.onOpenAsset?.call(asset);
                            return;
                          }
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
          // The same menu the right-click opens. Here as well, because a
          // menu nobody knows to right-click for is a menu nobody has.
          Builder(
            builder: (context) => _IconAction(
              icon: Icons.add,
              tooltip: 'New folder or file',
              enabled: true,
              onTap: () {
                final box = context.findRenderObject()! as RenderBox;
                AssetMenu.open(
                  context,
                  box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                );
              },
            ),
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
    this.onDropObject,
  });

  final AssetTree tree;
  final List<({String path, int depth})> folders;
  final String current;
  final ValueChanged<String> onOpen;

  /// Called with the object dropped and the folder it landed on.
  final void Function(ObjectDrag object, String directory)? onDropObject;

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
            onDropObject: onDropObject == null
                ? null
                : (object) => onDropObject!(object, tree.root),
          ),
          for (final folder in folders)
            _FolderRow(
              name: p.basename(folder.path),
              depth: folder.depth + 1,
              icon: Icons.folder_outlined,
              selected: p.equals(current, folder.path),
              onTap: () => onOpen(folder.path),
              onDropObject: onDropObject == null
                  ? null
                  : (object) => onDropObject!(object, folder.path),
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
    this.onDropObject,
  });

  final String name;
  final int depth;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// Dropping an object on a folder makes a prefab there, without having to
  /// open the folder first.
  final ValueChanged<ObjectDrag>? onDropObject;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hovering = false;

  /// Whether something is being held over this row, which is worth showing:
  /// the rows are 24 pixels apart and dropping on the wrong one is easy.
  bool _catching = false;

  @override
  Widget build(BuildContext context) {
    final colour = widget.selected || _catching
        ? OrbisColors.ember
        : (_hovering ? OrbisColors.ink : OrbisColors.inkMid);

    final row = MouseRegion(
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
          color: widget.selected || _catching
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

    if (widget.onDropObject == null) return row;

    return DragTarget<ObjectDrag>(
      onWillAcceptWithDetails: (_) {
        setState(() => _catching = true);
        return true;
      },
      onLeave: (_) => setState(() => _catching = false),
      onAcceptWithDetails: (details) {
        setState(() => _catching = false);
        widget.onDropObject!(details.data);
      },
      builder: (context, candidate, _) => row,
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
    required this.onDelete,
    required this.onRename,
    this.onDropObject,
  });

  final List<Asset> entries;
  final String? selected;
  final ValueChanged<Asset> onSelect;
  final ValueChanged<Asset> onOpen;
  final ValueChanged<Asset> onDelete;
  final ValueChanged<Asset> onRename;
  final ValueChanged<ObjectDrag>? onDropObject;

  @override
  Widget build(BuildContext context) {
    final grid = entries.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('This folder is empty.', style: OrbisText.caption),
                const SizedBox(height: Space.xs),
                Text('Right-click to add something.',
                    style: OrbisText.caption),
              ],
            ),
          )
        : _grid();

    // Opaque so the right-click lands on the gaps between tiles and on the
    // empty folder, which is exactly where somebody reaches for "new".
    final catching = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) =>
          AssetMenu.open(context, details.globalPosition),
      child: grid,
    );

    if (onDropObject == null) return catching;

    return DragTarget<ObjectDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDropObject!(details.data),
      builder: (context, candidate, _) => Stack(
        fit: StackFit.expand,
        children: [
          catching,
          // Only while something is over it: an outline drawn all the time
          // would be one more line in a panel that is mostly lines.
          if (candidate.isNotEmpty)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: OrbisColors.emberWash,
                  border: Border.all(color: OrbisColors.ember),
                  borderRadius: BorderRadius.circular(Radii.control),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Drop to make a prefab',
                  style: OrbisText.label.copyWith(color: OrbisColors.ink),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid() {
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
          onDelete: () => onDelete(asset),
          onRename: () => onRename(asset),
        );
      },
    );
  }
}

/// The right-click menu, wherever it is opened from.
///
/// One menu rather than two, because what somebody can make does not depend
/// on whether the pointer happened to be over a file when they asked. What a
/// tile adds is what can be done *to* it, at the top where it reads first.
///
/// Built with [MenuAnchor] rather than `showMenu`, which cannot nest: the
/// list of things to make had grown into a wall of six, and every kind added
/// made it worse.
class AssetMenu extends StatefulWidget {
  const AssetMenu({super.key, required this.onCreate, required this.child});

  final ValueChanged<NewAsset> onCreate;

  /// What the menu opens over — the whole browser, so a right-click anywhere
  /// in it opens the menu at the pointer.
  final Widget child;

  /// Opens the menu belonging to the browser this context sits in.
  ///
  /// Static so a tile deep in the grid can open the one menu rather than
  /// carrying its own, which would put a menu controller on every file in
  /// the project.
  static void open(
    BuildContext context,
    Offset at, {
    VoidCallback? onOpen,
    VoidCallback? onRename,
    VoidCallback? onDelete,
  }) {
    context.findAncestorStateOfType<_AssetMenuState>()?.show(
      at,
      onOpen: onOpen,
      onRename: onRename,
      onDelete: onDelete,
    );
  }

  @override
  State<AssetMenu> createState() => _AssetMenuState();
}

class _AssetMenuState extends State<AssetMenu> {
  final MenuController _controller = MenuController();
  final GlobalKey _anchor = GlobalKey();

  VoidCallback? _onOpen;
  VoidCallback? _onRename;
  VoidCallback? _onDelete;

  void show(
    Offset at, {
    VoidCallback? onOpen,
    VoidCallback? onRename,
    VoidCallback? onDelete,
  }) {
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    setState(() {
      _onOpen = onOpen;
      _onRename = onRename;
      _onDelete = onDelete;
    });
    // Reopened rather than moved: a menu already showing somewhere else would
    // otherwise stay where it was and look like the right-click did nothing.
    _controller.close();
    _controller.open(position: box.globalToLocal(at));
  }

  static final MenuStyle _style = MenuStyle(
    backgroundColor: const WidgetStatePropertyAll(OrbisColors.raised),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.panel),
        side: const BorderSide(color: OrbisColors.line),
      ),
    ),
  );

  Widget _item(String label, IconData icon, VoidCallback? onPressed) {
    return MenuItemButton(
      onPressed: onPressed,
      leadingIcon: Icon(icon, size: 14, color: OrbisColors.inkMid),
      child: Text(label, style: OrbisText.label),
    );
  }

  Widget _make(NewAsset what) => MenuItemButton(
    onPressed: () => widget.onCreate(what),
    leadingIcon: Icon(what.icon, size: 14, color: OrbisColors.inkMid),
    child: Row(
      children: [
        Text(what.label, style: OrbisText.label),
        // The extension is what somebody is really choosing between, so
        // it is shown rather than left to be guessed from the name.
        if (what.extension.isNotEmpty) ...[
          const SizedBox(width: Space.md),
          Text(what.extension, style: OrbisText.caption),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final acting = _onOpen != null || _onRename != null || _onDelete != null;

    return MenuAnchor(
      key: _anchor,
      controller: _controller,
      style: _style,
      menuChildren: [
        if (acting) ...[
          _item('Open', Icons.open_in_new, _onOpen),
          _item('Rename', Icons.drive_file_rename_outline, _onRename),
          _item('Delete', Icons.delete_outline, _onDelete),
          const Divider(height: 9, color: OrbisColors.line),
        ],
        _make(NewAsset.folder),
        const Divider(height: 9, color: OrbisColors.line),
        for (final group in NewAssetGroup.values)
          SubmenuButton(
            menuStyle: _style,
            leadingIcon: Icon(group.icon, size: 14, color: OrbisColors.inkMid),
            menuChildren: [for (final what in group.members) _make(what)],
            child: Text(group.label, style: OrbisText.label),
          ),
        const Divider(height: 9, color: OrbisColors.line),
        _make(NewAsset.scene),
      ],
      child: widget.child,
    );
  }
}

class _Tile extends StatefulWidget {
  const _Tile({
    required this.asset,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onDelete,
    required this.onRename,
  });

  final Asset asset;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;

    final tile = Tooltip(
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
          onSecondaryTapUp: (details) => AssetMenu.open(
            context,
            details.globalPosition,
            onOpen: widget.onDoubleTap,
            onRename: widget.onRename,
            onDelete: widget.onDelete,
          ),
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

    // Folders are for navigating, not for dropping into a scene.
    if (asset.isFolder) return tile;

    return Draggable<String>(
      data: asset.path,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragLabel(asset: asset),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }
}

/// What follows the pointer while an asset is dragged.
class _DragLabel extends StatelessWidget {
  const _DragLabel({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          color: OrbisColors.raised,
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: OrbisColors.ember),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(asset.kind.icon, size: 13, color: OrbisColors.ember),
            const SizedBox(width: Space.sm),
            Text(
              asset.name,
              style: OrbisText.label.copyWith(color: OrbisColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}
