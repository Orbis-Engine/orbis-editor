import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:path/path.dart' as p;

import '../theme/orbis_theme.dart';
import '../widgets/controls.dart';
import 'inspector.dart' show FieldRow, SliderRow;
import 'ui_canvas.dart';

/// The elements somebody can put on a canvas.
///
/// A short list on purpose. Every one of these is a real Flutter widget with
/// real layout behind it, and a palette of forty things that mostly wrap each
/// other is a palette nobody reads to the end of.
enum UiElement {
  column('Column', Icons.view_agenda_outlined, 'column', 'gap-2'),
  row('Row', Icons.view_column_outlined, 'row', 'gap-2 items-center'),
  stack('Stack', Icons.layers_outlined, 'stack', ''),
  box('Box', Icons.crop_square, 'box', 'p-4 bg-slate-800 rounded-lg'),
  text('Text', Icons.text_fields, 'text', 'text-base text-slate-100'),
  button('Button', Icons.smart_button_outlined, 'button',
      'px-4 py-2 bg-ember-500 text-white rounded'),
  field('Field', Icons.input, 'field', 'px-3 py-2 bg-slate-900 rounded'),
  image('Image', Icons.image_outlined, 'image', 'w-32 h-32'),
  spacer('Spacer', Icons.expand, 'spacer', '');

  const UiElement(this.label, this.icon, this.type, this.classes);

  final String label;
  final IconData icon;
  final String type;

  /// What it looks like the moment it is added.
  ///
  /// Not nothing: an element with no styling is an invisible element, and an
  /// invisible element added to a canvas reads as a button that did not work.
  final String classes;

  UiNode make() => UiNode(
        type: type,
        classes: classes,
        text: switch (this) {
          UiElement.text => 'Text',
          UiElement.button => 'Button',
          UiElement.field => '',
          _ => null,
        },
      );
}

/// Laying out an interface.
///
/// A screen rather than a panel in the shell. A canvas wants the whole window
/// — it is a design surface at a fixed size, and squeezing one into the space
/// left over beside a 3D viewport gives a view too small to lay anything out
/// in and a viewport nobody is looking at.
class UiEditor extends StatefulWidget {
  const UiEditor({
    super.key,
    required this.path,
    required this.document,
    this.onProblem,
  });

  /// Where the `.oui` lives.
  final String path;

  final UiDocument document;

  final ValueChanged<String>? onProblem;

  @override
  State<UiEditor> createState() => _UiEditorState();
}

class _UiEditorState extends State<UiEditor> {
  late UiDocument _document = widget.document;

  /// Whole documents, one per step.
  ///
  /// A tree is immutable and an edit shares every subtree it did not touch, so
  /// a step costs the spine of one edit rather than a copy of the interface.
  /// That is what makes "keep the last hundred" the simple answer here and a
  /// per-field command the complicated one.
  final List<UiDocument> _done = [];
  final List<UiDocument> _undone = [];

  List<int>? _selected = const [];
  List<int>? _hovered;

  bool _previewing = false;
  bool _outlines = true;
  bool _guides = true;
  bool _dirty = false;

  /// The document as a drag started, so a whole drag is one undo step rather
  /// than one per frame of it.
  UiDocument? _before;

  UiNode? get _element =>
      _selected == null ? null : _document.root.at(_selected!);

  void _change(UiDocument next, {List<int>? select}) {
    setState(() {
      _done.add(_document);
      if (_done.length > 200) _done.removeAt(0);
      _undone.clear();
      _document = next;
      _dirty = true;
      if (select != null) _selected = select;
      // The selection can be left pointing at something that has gone.
      if (_selected != null && _document.root.at(_selected!) == null) {
        _selected = const [];
      }
    });
  }

  void _undo() {
    if (_done.isEmpty) return;
    setState(() {
      _undone.add(_document);
      _document = _done.removeLast();
      _dirty = true;
      if (_selected != null && _document.root.at(_selected!) == null) {
        _selected = const [];
      }
    });
  }

  void _redo() {
    if (_undone.isEmpty) return;
    setState(() {
      _done.add(_document);
      _document = _undone.removeLast();
      _dirty = true;
      if (_selected != null && _document.root.at(_selected!) == null) {
        _selected = const [];
      }
    });
  }

  void _save() {
    try {
      File(widget.path).writeAsStringSync(_document.toText());
    } on FileSystemException catch (error) {
      widget.onProblem?.call(
        'Could not save ${p.basename(widget.path)}: '
        '${error.osError?.message ?? error.message}',
      );
      return;
    }
    setState(() => _dirty = false);
  }

  void _add(UiElement what) {
    // Inside the selection, which is what "add" means when something is
    // selected and there is nowhere else it could sensibly go.
    final into = _selected ?? const <int>[];
    final parent = _document.root.at(into);
    if (parent == null) return;

    var made = what.make();
    // Placed rather than dropped at the origin when its parent does not lay
    // it out: everything added to a stack landing in the same corner and on
    // top of the last one is not an interface, it is a pile.
    if (parent.type == 'stack') {
      final at = 48.0 + parent.children.length * 24;
      made = made.placeAt(at, at);
    }

    _change(
      _document.copyWith(
        root: _document.root.insertAt(into, parent.children.length, made),
      ),
      select: [...into, parent.children.length],
    );
  }

  /// Moves an element while it is being dragged.
  ///
  /// The whole drag is one step. Without this an undo would walk back through
  /// every frame of the movement, which is a hundred presses to put something
  /// back where it was.
  void _move(List<int> path, Offset to) {
    final element = _document.root.at(path);
    if (element == null) return;

    // The fraction is kept while the pointer is down. Rounding every frame
    // throws away a fraction of a pixel each time, and a slow drag ends up
    // behind the pointer by however long somebody took over it.
    final next = _document.copyWith(
      root: _document.root
          .replaceAt(path, element.placeAt(to.dx, to.dy, round: false)),
    );

    if (_before == null) {
      _before = _document;
      _change(next);
    } else {
      // Already recorded: replace the document without pushing another step.
      setState(() {
        _document = next;
        _dirty = true;
      });
    }
  }

  /// Lands the dragged element on a whole pixel.
  ///
  /// A file full of positions to fourteen decimal places is a file whose diff
  /// is unreadable, and the difference is not visible on any screen.
  void _moveDone() {
    _before = null;

    final path = _selected;
    final element = path == null ? null : _document.root.at(path);
    final at = element?.placed;
    if (path == null || element == null || at == null) return;
    if (at.left == at.left.roundToDouble() &&
        at.top == at.top.roundToDouble()) {
      return;
    }

    setState(() {
      _document = _document.copyWith(
        root: _document.root.replaceAt(path, element.placeAt(at.left, at.top)),
      );
    });
  }

  void _remove(List<int> path) {
    if (path.isEmpty) return;
    _change(
      _document.copyWith(root: _document.root.removeAt(path)),
      select: path.sublist(0, path.length - 1),
    );
  }

  void _edit(UiNode Function(UiNode) change) {
    final path = _selected;
    final element = path == null ? null : _document.root.at(path);
    if (path == null || element == null) return;
    _change(
      _document.copyWith(root: _document.root.replaceAt(path, change(element))),
    );
  }

  Future<void> _leave() async {
    if (!_dirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OrbisColors.surface,
        title: Text('Save ${p.basename(widget.path)}?', style: OrbisText.title),
        content: Text(
          'It has changes that are not on disk.',
          style: OrbisText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (!mounted || answer == 'cancel' || answer == null) return;
    if (answer == 'save') _save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): _SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            _RedoIntent(),
        SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
        SingleActivator(LogicalKeyboardKey.backspace): _DeleteIntent(),
      },
      child: Actions(
        actions: {
          _SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) {
            _save();
            return null;
          }),
          _UndoIntent: CallbackAction<_UndoIntent>(onInvoke: (_) {
            _undo();
            return null;
          }),
          _RedoIntent: CallbackAction<_RedoIntent>(onInvoke: (_) {
            _redo();
            return null;
          }),
          _DeleteIntent: CallbackAction<_DeleteIntent>(onInvoke: (_) {
            if (_selected != null) _remove(_selected!);
            return null;
          }),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: OrbisColors.ground,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _toolbar(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Tree(
                        root: _document.root,
                        selected: _selected,
                        hovered: _hovered,
                        onSelect: (path) => setState(() => _selected = path),
                        onHover: (path) => setState(() => _hovered = path),
                        onRemove: _remove,
                      ),
                      Expanded(
                        child: UiCanvasView(
                          document: _document,
                          selected: _previewing ? null : _selected,
                          hovered: _previewing ? null : _hovered,
                          designing: !_previewing,
                          showOutlines: _outlines,
                          showGuides: _guides,
                          onSelect: (path) =>
                              setState(() => _selected = path),
                          onHover: (path) => setState(() => _hovered = path),
                          onMove: _move,
                          onMoved: _moveDone,
                        ),
                      ),
                      _Side(
                        document: _document,
                        element: _element,
                        onCanvas: (canvas) =>
                            _change(_document.copyWith(canvas: canvas)),
                        onElement: _edit,
                        onAdd: _add,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(bottom: BorderSide(color: OrbisColors.line)),
      ),
      child: Row(
        children: [
          OrbisButton(
            label: p.basename(widget.path) + (_dirty ? ' •' : ''),
            icon: Icons.chevron_left,
            tone: ButtonTone.quiet,
            onPressed: _leave,
          ),
          const SizedBox(width: Space.md),
          OrbisButton(
            label: 'Save',
            icon: Icons.save_outlined,
            tone: ButtonTone.quiet,
            onPressed: _dirty ? _save : null,
          ),
          const SizedBox(width: Space.xs),
          OrbisButton(
            label: 'Undo',
            icon: Icons.undo,
            tone: ButtonTone.quiet,
            onPressed: _done.isEmpty ? null : _undo,
          ),
          OrbisButton(
            label: 'Redo',
            icon: Icons.redo,
            tone: ButtonTone.quiet,
            onPressed: _undone.isEmpty ? null : _redo,
          ),
          const Spacer(),
          // What the game shows, with nothing over it. The one control that
          // answers "is this guide going to be in my screenshot".
          _Toggle(
            label: 'Preview',
            icon: Icons.play_arrow_outlined,
            on: _previewing,
            onChanged: (value) => setState(() => _previewing = value),
          ),
          const SizedBox(width: Space.xs),
          // Named after what they actually take away. "Outlines" that leaves
          // a canvas frame and a safe area on screen reads as a toggle that
          // did nothing.
          _Toggle(
            label: 'Element outlines',
            icon: Icons.select_all,
            on: _outlines && !_previewing,
            onChanged: _previewing
                ? null
                : (value) => setState(() => _outlines = value),
          ),
          const SizedBox(width: Space.xs),
          _Toggle(
            label: 'Canvas guides',
            icon: Icons.crop_free,
            on: _guides && !_previewing,
            onChanged: _previewing
                ? null
                : (value) => setState(() => _guides = value),
          ),
        ],
      ),
    );
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _DeleteIntent extends Intent {
  const _DeleteIntent();
}

/// The elements on the canvas, as a tree.
class _Tree extends StatelessWidget {
  const _Tree({
    required this.root,
    required this.selected,
    required this.hovered,
    required this.onSelect,
    required this.onHover,
    required this.onRemove,
  });

  final UiNode root;
  final List<int>? selected;
  final List<int>? hovered;
  final ValueChanged<List<int>> onSelect;
  final ValueChanged<List<int>?> onHover;
  final ValueChanged<List<int>> onRemove;

  @override
  Widget build(BuildContext context) {
    final rows = root.walk().toList();

    return Container(
      width: 248,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(right: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Text('ELEMENTS', style: OrbisText.section),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return _TreeRow(
                  node: row.node,
                  path: row.path,
                  selected: UiCanvasView.samePath(selected, row.path),
                  hovered: UiCanvasView.samePath(hovered, row.path),
                  onTap: () => onSelect(row.path),
                  onHover: onHover,
                  onRemove: row.path.isEmpty ? null : () => onRemove(row.path),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.node,
    required this.path,
    required this.selected,
    required this.hovered,
    required this.onTap,
    required this.onHover,
    required this.onRemove,
  });

  final UiNode node;
  final List<int> path;
  final bool selected;
  final bool hovered;
  final VoidCallback onTap;
  final ValueChanged<List<int>?> onHover;
  final VoidCallback? onRemove;

  static IconData _iconFor(String type) {
    for (final element in UiElement.values) {
      if (element.type == type) return element.icon;
    }
    return Icons.crop_square;
  }

  @override
  Widget build(BuildContext context) {
    final colour = selected
        ? OrbisColors.ember
        : (hovered ? OrbisColors.ink : OrbisColors.inkMid);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(path),
      onExit: (_) => onHover(null),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 24,
          padding: EdgeInsets.only(
            left: Space.sm + path.length * 13.0,
            right: Space.xs,
          ),
          color: selected
              ? OrbisColors.emberWash
              : (hovered ? OrbisColors.raised : Colors.transparent),
          child: Row(
            children: [
              Icon(_iconFor(node.type), size: 13, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  // The words when it has any, since "Start game" says more
                  // about which button this is than "button" does.
                  node.text?.trim().isNotEmpty ?? false
                      ? node.text!.trim()
                      : node.type,
                  overflow: TextOverflow.ellipsis,
                  style: OrbisText.label.copyWith(fontSize: 11.5, color: colour),
                ),
              ),
              if (hovered && onRemove != null)
                GestureDetector(
                  onTap: onRemove,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Icon(Icons.close, size: 12,
                        color: OrbisColors.inkDim),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The palette, the element's properties and the canvas's.
class _Side extends StatelessWidget {
  const _Side({
    required this.document,
    required this.element,
    required this.onCanvas,
    required this.onElement,
    required this.onAdd,
  });

  final UiDocument document;
  final UiNode? element;
  final ValueChanged<UiCanvas> onCanvas;
  final void Function(UiNode Function(UiNode)) onElement;
  final ValueChanged<UiElement> onAdd;

  /// Sizes worth having one press away. Every one is a real screen somebody
  /// ships to, rather than a round number.
  /// What each fit means, since the name is three words and the behaviour is
  /// the thing somebody is choosing between.
  static const _fitExplains = <CanvasFit, String>{
    CanvasFit.width: 'The width always fills the screen. The bottom of a '
        'taller screen is empty and a shorter one cuts the bottom off.',
    CanvasFit.height: 'The height always fits. A wider screen has space at '
        'the sides and a narrower one cuts them off.',
    CanvasFit.contain: 'All of it fits, with space where the shape does not '
        'match. Nothing is ever cut off.',
    CanvasFit.none: 'Not scaled. Pixels are pixels, however big the screen is.',
  };

  static const _sizes = <String, (double, double)>{
    '1920 × 1080': (1920, 1080),
    '2560 × 1440': (2560, 1440),
    '1280 × 720': (1280, 720),
    '390 × 844': (390, 844),
    '1024 × 768': (1024, 768),
  };

  @override
  Widget build(BuildContext context) {
    final selected = element;

    return Container(
      width: 296,
      decoration: const BoxDecoration(
        color: OrbisColors.surface,
        border: Border(left: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
            ),
            child: Text('INTERFACE', style: OrbisText.section),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              children: [
                _Group(
                  title: 'Add',
                  icon: Icons.add,
                  child: Wrap(
                    spacing: Space.xs,
                    runSpacing: Space.xs,
                    children: [
                      for (final what in UiElement.values)
                        _Chip(
                          label: what.label,
                          icon: what.icon,
                          onTap: () => onAdd(what),
                        ),
                    ],
                  ),
                ),
                if (selected != null) ...[
                  _Group(
                    title: selected.type,
                    icon: _TreeRow._iconFor(selected.type),
                    child: Column(
                      children: [
                        if (selected.text != null ||
                            selected.type == 'text' ||
                            selected.type == 'button')
                          FieldRow(
                            label: 'Words',
                            child: ValueField(
                              value: selected.text ?? '',
                              onChanged: (value) => onElement(
                                (node) => node.copyWith(text: value),
                              ),
                            ),
                          ),
                        FieldRow(
                          label: 'Classes',
                          child: ValueField(
                            value: selected.classes,
                            mono: true,
                            hint: 'p-4 flex-1 bg-slate-800',
                            onChanged: (value) => onElement(
                              (node) => node.copyWith(classes: value),
                            ),
                          ),
                        ),
                        FieldRow(
                          label: 'CSS',
                          child: ValueField(
                            value: selected.css,
                            mono: true,
                            hint: 'padding: 8px 12px',
                            onChanged: (value) =>
                                onElement((node) => node.copyWith(css: value)),
                          ),
                        ),
                        FieldRow(
                          label: 'Handler',
                          child: ValueField(
                            value: '${selected.props['onPressed'] ?? ''}',
                            mono: true,
                            hint: 'what script calls',
                            onChanged: (value) => onElement(
                              (node) => node.copyWith(
                                props: {
                                  ...node.props,
                                  if (value.trim().isNotEmpty)
                                    'onPressed': value.trim()
                                  else
                                    ...{},
                                }..removeWhere((key, _) =>
                                    key == 'onPressed' && value.trim().isEmpty),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                _Group(
                  title: 'Canvas',
                  icon: Icons.aspect_ratio,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: Space.xs,
                        runSpacing: Space.xs,
                        children: [
                          for (final entry in _sizes.entries)
                            _Chip(
                              label: entry.key,
                              selected: document.canvas.width == entry.value.$1 &&
                                  document.canvas.height == entry.value.$2,
                              onTap: () => onCanvas(
                                document.canvas.copyWith(
                                  width: entry.value.$1,
                                  height: entry.value.$2,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      Text('ON SCREEN', style: OrbisText.section),
                      const SizedBox(height: Space.xs),
                      // Chips that wrap rather than four segments sharing one
                      // row: "Match height" does not fit in a quarter of a
                      // 296-wide panel, and a label clipped in half is a
                      // control nobody can read.
                      Wrap(
                        spacing: Space.xs,
                        runSpacing: Space.xs,
                        children: [
                          for (final fit in CanvasFit.values)
                            _Chip(
                              label: fit.label,
                              tooltip: _fitExplains[fit],
                              selected: document.canvas.fit == fit,
                              onTap: () =>
                                  onCanvas(document.canvas.copyWith(fit: fit)),
                            ),
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      SliderRow(
                        label: 'Safe area',
                        value: document.canvas.safeArea * 100,
                        min: 0,
                        max: 20,
                        unit: '%',
                        onChanged: (value) => onCanvas(
                          document.canvas.copyWith(safeArea: value / 100),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                Icon(icon, size: 13, color: OrbisColors.inkDim),
                const SizedBox(width: Space.sm),
                Text(title.toUpperCase(), style: OrbisText.section),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.onTap,
    this.icon,
    this.tooltip,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final String? tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final chip = _chip();
    return tooltip == null
        ? chip
        : Tooltip(
            message: tooltip!,
            waitDuration: const Duration(milliseconds: 400),
            child: chip,
          );
  }

  Widget _chip() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.sm,
            vertical: Space.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? OrbisColors.emberWash : OrbisColors.raised,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(
              color: selected ? OrbisColors.ember : OrbisColors.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: OrbisColors.inkMid),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: OrbisText.label.copyWith(
                  fontSize: 11,
                  color: selected ? OrbisColors.ember : OrbisColors.inkMid,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.icon,
    required this.on,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return OrbisButton(
      label: label,
      icon: icon,
      tone: on ? ButtonTone.primary : ButtonTone.quiet,
      onPressed: onChanged == null ? null : () => onChanged!(!on),
    );
  }
}
