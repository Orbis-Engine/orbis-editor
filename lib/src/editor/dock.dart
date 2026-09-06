import 'dart:convert';

import 'package:flutter/material.dart';

/// What a panel shows.
///
/// A kind rather than a widget, because the layout is data: it is saved to a
/// file, sent through an undo, and compared in a test, and a widget is none of
/// those things. What builds one is the shell's business.
enum PanelKind {
  outliner('Hierarchy', Icons.account_tree_outlined),
  inspector('Inspector', Icons.tune),
  viewport('Scene', Icons.videocam_outlined),
  game('Game', Icons.sports_esports_outlined),
  project('Project', Icons.folder_outlined),
  console('Console', Icons.terminal);

  const PanelKind(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Whether more than one of these makes sense.
  ///
  /// Four scene views onto one world is the reason this whole thing exists.
  /// Four inspectors is four copies of the same fields.
  bool get repeatable => this == PanelKind.viewport;

  static PanelKind? named(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One panel in the layout.
///
/// The id is what a drag carries and what per-panel state is filed under — two
/// scene views are two cameras, and without an id of its own the second would
/// be looking wherever the first was.
class DockPanel {
  const DockPanel({required this.id, required this.kind, this.title});

  final String id;
  final PanelKind kind;

  /// What the tab says, when it is not just the kind's name. For telling four
  /// scene views apart.
  final String? title;

  String get label => title ?? kind.label;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        if (title != null) 'title': title,
      };

  static DockPanel? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    final kind = PanelKind.named(map['kind']);
    final id = map['id'];
    if (kind == null || id is! String || id.isEmpty) return null;
    return DockPanel(
      id: id,
      kind: kind,
      title: map['title'] is String ? map['title']! as String : null,
    );
  }
}

/// A panel being dragged.
///
/// A type of its own rather than the bare id, because an asset path and an
/// object id are strings too, and the viewport, the outliner and the project
/// browser all take drops. With one type for all of them a tab dragged over
/// the viewport looks exactly like a mesh being dropped into the scene.
class PanelDrag {
  const PanelDrag(this.panel);

  final DockPanel panel;

  String get id => panel.id;
}

/// Where a dropped panel goes relative to what it was dropped on.
enum DockSide { left, right, top, bottom, centre }

/// A place in the layout: either a stack of tabs or a row or column of places.
sealed class DockNode {
  const DockNode({required this.id});

  /// Stable across edits, so a drop can name what it landed on and per-panel
  /// state can be filed under something that does not move.
  final String id;

  Map<String, Object?> toJson();

  static DockNode? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    return map['split'] is String
        ? DockSplit.fromJson(map)
        : DockGroup.fromJson(map);
  }
}

/// Panels sharing one space, one showing at a time.
class DockGroup extends DockNode {
  const DockGroup({
    required super.id,
    required this.panels,
    this.active = 0,
  });

  final List<DockPanel> panels;

  /// Which one is showing. Clamped on read rather than on write, because a
  /// panel closing can take the active one with it and a layout mid-edit is
  /// allowed to be briefly out of step.
  final int active;

  int get showing =>
      panels.isEmpty ? 0 : active.clamp(0, panels.length - 1);

  DockPanel? get current => panels.isEmpty ? null : panels[showing];

  DockGroup copyWith({List<DockPanel>? panels, int? active}) => DockGroup(
        id: id,
        panels: panels ?? this.panels,
        active: active ?? this.active,
      );

  @override
  Map<String, Object?> toJson() => {
        'id': id,
        'active': active,
        'panels': [for (final panel in panels) panel.toJson()],
      };

  static DockGroup? fromJson(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;
    final raw = map['panels'];
    return DockGroup(
      id: id,
      active: map['active'] is int ? map['active']! as int : 0,
      panels: [
        if (raw is List)
          for (final entry in raw) ?DockPanel.fromJson(entry),
      ],
    );
  }
}

/// Places side by side, or one above another.
class DockSplit extends DockNode {
  const DockSplit({
    required super.id,
    required this.axis,
    required this.children,
    required this.weights,
  });

  final Axis axis;
  final List<DockNode> children;

  /// How the space is shared, one per child. Kept as fractions so a window
  /// that is resized keeps the proportions somebody chose rather than the
  /// pixels they happened to drag to.
  final List<double> weights;

  /// The weights, made to add up to one and to have one per child.
  ///
  /// Read rather than enforced, because a file written by an older build or
  /// edited by hand is allowed to be wrong and a layout that refuses to open
  /// is worse than one that evens itself out.
  List<double> get shares {
    if (weights.length != children.length || children.isEmpty) {
      return [for (var i = 0; i < children.length; i++) 1 / children.length];
    }
    final total = weights.fold<double>(0, (sum, w) => sum + (w <= 0 ? 0 : w));
    if (total <= 0) {
      return [for (var i = 0; i < children.length; i++) 1 / children.length];
    }
    return [for (final w in weights) (w <= 0 ? 0 : w) / total];
  }

  DockSplit copyWith({List<DockNode>? children, List<double>? weights}) =>
      DockSplit(
        id: id,
        axis: axis,
        children: children ?? this.children,
        weights: weights ?? this.weights,
      );

  @override
  Map<String, Object?> toJson() => {
        'id': id,
        'split': axis == Axis.horizontal ? 'row' : 'column',
        'weights': shares,
        'children': [for (final child in children) child.toJson()],
      };

  static DockSplit? fromJson(Map<String, Object?> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;

    final raw = map['children'];
    final children = [
      if (raw is List)
        for (final entry in raw) ?DockNode.fromJson(entry),
    ];
    if (children.isEmpty) return null;

    final rawWeights = map['weights'];
    return DockSplit(
      id: id,
      axis: map['split'] == 'column' ? Axis.vertical : Axis.horizontal,
      children: children,
      weights: [
        if (rawWeights is List)
          for (final w in rawWeights)
            if (w is num) w.toDouble(),
      ],
    );
  }
}


/// The arrangement of the editor's panels.
///
/// Data rather than a widget tree, so it can be saved with the project, put
/// back exactly, compared in a test, and changed by dragging a tab without any
/// of that being a special case. Every operation returns a new layout: an
/// arrangement half-way through being rebuilt is not something anything else
/// should be able to see.
class DockLayout {
  const DockLayout({required this.root, this.locked = false});

  final DockNode root;

  /// Whether the arrangement can be changed by dragging.
  ///
  /// Somebody who has their panels where they want them should be able to say
  /// so. A layout that can always be pulled apart is a layout that eventually
  /// is, by a drag that was meant to be something else.
  final bool locked;

  static const int formatVersion = 1;

  /// The arrangement the editor opens with.
  factory DockLayout.standard() => const DockLayout(
        root: DockSplit(
          id: 'root',
          axis: Axis.vertical,
          weights: [0.74, 0.26],
          children: [
            DockSplit(
              id: 'middle',
              axis: Axis.horizontal,
              weights: [0.19, 0.58, 0.23],
              children: [
                DockGroup(
                  id: 'left',
                  panels: [
                    DockPanel(id: 'outliner', kind: PanelKind.outliner),
                  ],
                ),
                DockGroup(
                  id: 'centre',
                  panels: [
                    DockPanel(id: 'scene', kind: PanelKind.viewport),
                    DockPanel(id: 'game', kind: PanelKind.game),
                  ],
                ),
                DockGroup(
                  id: 'right',
                  panels: [
                    DockPanel(id: 'inspector', kind: PanelKind.inspector),
                  ],
                ),
              ],
            ),
            DockGroup(
              id: 'bottom',
              panels: [
                DockPanel(id: 'project', kind: PanelKind.project),
                DockPanel(id: 'console', kind: PanelKind.console),
              ],
            ),
          ],
        ),
      );

  /// Four scene views onto the same world, the way a modelling tool arranges
  /// them. The reason the layout is data at all.
  factory DockLayout.fourViews() => DockLayout(
        root: DockSplit(
          id: 'root',
          axis: Axis.vertical,
          weights: const [0.74, 0.26],
          children: [
            DockSplit(
              id: 'middle',
              axis: Axis.horizontal,
              weights: const [0.16, 0.62, 0.22],
              children: [
                const DockGroup(
                  id: 'left',
                  panels: [DockPanel(id: 'outliner', kind: PanelKind.outliner)],
                ),
                DockSplit(
                  id: 'views',
                  axis: Axis.vertical,
                  weights: const [0.5, 0.5],
                  children: [
                    DockSplit(
                      id: 'viewsTop',
                      axis: Axis.horizontal,
                      weights: const [0.5, 0.5],
                      children: [
                        for (final one in const ['scene', 'scene2'])
                          DockGroup(
                            id: 'group_$one',
                            panels: [
                              DockPanel(
                                id: one,
                                kind: PanelKind.viewport,
                                title: one == 'scene' ? 'Scene' : 'Scene 2',
                              ),
                            ],
                          ),
                      ],
                    ),
                    DockSplit(
                      id: 'viewsBottom',
                      axis: Axis.horizontal,
                      weights: const [0.5, 0.5],
                      children: [
                        for (final one in const ['scene3', 'scene4'])
                          DockGroup(
                            id: 'group_$one',
                            panels: [
                              DockPanel(
                                id: one,
                                kind: PanelKind.viewport,
                                title: one == 'scene3' ? 'Scene 3' : 'Scene 4',
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
                const DockGroup(
                  id: 'right',
                  panels: [
                    DockPanel(id: 'inspector', kind: PanelKind.inspector),
                  ],
                ),
              ],
            ),
            const DockGroup(
              id: 'bottom',
              panels: [
                DockPanel(id: 'project', kind: PanelKind.project),
                DockPanel(id: 'console', kind: PanelKind.console),
              ],
            ),
          ],
        ),
      );

  /// Every panel in the layout, in the order it is laid out.
  Iterable<DockPanel> get panels sync* {
    Iterable<DockPanel> walk(DockNode node) sync* {
      if (node is DockGroup) {
        yield* node.panels;
      } else if (node is DockSplit) {
        for (final child in node.children) {
          yield* walk(child);
        }
      }
    }

    yield* walk(root);
  }

  bool holds(String panelId) => panels.any((panel) => panel.id == panelId);

  DockLayout copyWith({DockNode? root, bool? locked}) =>
      DockLayout(root: root ?? this.root, locked: locked ?? this.locked);

  /// Shows a panel, opening its group's tab.
  DockLayout show(String panelId) => copyWith(root: _show(root, panelId));

  static DockNode _show(DockNode node, String panelId) {
    if (node is DockGroup) {
      final at = node.panels.indexWhere((panel) => panel.id == panelId);
      return at < 0 ? node : node.copyWith(active: at);
    }
    if (node is DockSplit) {
      return node.copyWith(
        children: [for (final child in node.children) _show(child, panelId)],
      );
    }
    return node;
  }

  /// Adds a panel next to whatever is showing, or shows it if it is already
  /// somewhere.
  DockLayout add(DockPanel panel, {String? intoGroup}) {
    if (holds(panel.id)) return show(panel.id);

    final target = intoGroup ?? _firstGroup(root)?.id;
    if (target == null) return this;

    return copyWith(root: _intoGroup(root, target, panel));
  }

  static DockNode _intoGroup(DockNode node, String groupId, DockPanel panel) {
    if (node is DockGroup && node.id == groupId) {
      return node.copyWith(
        panels: [...node.panels, panel],
        active: node.panels.length,
      );
    }
    if (node is DockSplit) {
      return node.copyWith(
        children: [
          for (final child in node.children) _intoGroup(child, groupId, panel),
        ],
      );
    }
    return node;
  }

  /// Takes a panel out. Empty groups collapse and a split with one child left
  /// is replaced by that child, so the tree never grows a level that holds
  /// nothing.
  DockLayout close(String panelId) {
    final pruned = _prune(_remove(root, panelId));
    // Never nothing: a layout with no root has nowhere to put the panel
    // somebody opens next.
    return copyWith(root: pruned ?? DockLayout.standard().root);
  }

  static DockNode _remove(DockNode node, String panelId) {
    if (node is DockGroup) {
      final kept = [
        for (final panel in node.panels)
          if (panel.id != panelId) panel,
      ];
      if (kept.length == node.panels.length) return node;
      return node.copyWith(
        panels: kept,
        // Stays on the one before, which is where the eye already is.
        active: node.showing.clamp(0, kept.isEmpty ? 0 : kept.length - 1),
      );
    }
    if (node is DockSplit) {
      return node.copyWith(
        children: [for (final child in node.children) _remove(child, panelId)],
      );
    }
    return node;
  }

  /// Drops empty groups and splits that hold one thing.
  static DockNode? _prune(DockNode node) {
    if (node is DockGroup) return node.panels.isEmpty ? null : node;
    if (node is! DockSplit) return node;

    final kept = <DockNode>[];
    final weights = <double>[];
    final shares = node.shares;
    for (var i = 0; i < node.children.length; i++) {
      final child = _prune(node.children[i]);
      if (child == null) continue;
      kept.add(child);
      weights.add(shares[i]);
    }

    if (kept.isEmpty) return null;
    // A split of one is a level of nothing, and left in place it would collect
    // more of them every time a panel was closed.
    if (kept.length == 1) return kept.single;
    return node.copyWith(children: kept, weights: weights);
  }

  /// Moves a panel onto a side of a group, or into it as another tab.
  ///
  /// The one operation dragging a tab performs. Everything about the shape of
  /// the layout — new splits, collapsed ones, reordered tabs — comes out of
  /// this rather than out of the widget that drew the drag.
  DockLayout dock(String panelId, String ontoGroup, DockSide side) {
    if (locked) return this;

    final panel = panels.where((p) => p.id == panelId).firstOrNull;
    if (panel == null) return this;

    // Onto its own group's centre is a no-op rather than a panel that
    // disappears and comes back somewhere else.
    final home = _groupHolding(root, panelId);
    if (side == DockSide.centre && home?.id == ontoGroup) return this;

    final without = _prune(_remove(root, panelId));
    if (without == null) {
      return copyWith(
        root: DockGroup(id: _freshId('group'), panels: [panel]),
      );
    }

    // The group it was dropped on may have gone with it: the panel was the
    // only one in it, and taking it out collapsed the group. Nowhere to put it
    // means it stays where it was, rather than being dropped on the floor.
    if (!_hasGroup(without, ontoGroup)) return this;

    return copyWith(root: _dockInto(without, ontoGroup, panel, side));
  }

  static DockNode _dockInto(
    DockNode node,
    String groupId,
    DockPanel panel,
    DockSide side,
  ) {
    if (node is DockGroup && node.id == groupId) {
      if (side == DockSide.centre) {
        return node.copyWith(
          panels: [...node.panels, panel],
          active: node.panels.length,
        );
      }

      final fresh = DockGroup(id: _freshId('group'), panels: [panel]);
      final before = side == DockSide.left || side == DockSide.top;
      return DockSplit(
        id: _freshId('split'),
        axis: side == DockSide.left || side == DockSide.right
            ? Axis.horizontal
            : Axis.vertical,
        children: before ? [fresh, node] : [node, fresh],
        // A new panel takes a third, which is enough to be usable and little
        // enough that what was there is still the thing being worked in.
        weights: before ? const [0.34, 0.66] : const [0.66, 0.34],
      );
    }
    if (node is DockSplit) {
      return node.copyWith(
        children: [
          for (final child in node.children)
            _dockInto(child, groupId, panel, side),
        ],
      );
    }
    return node;
  }

  /// Changes how two neighbours in a split share their space.
  DockLayout resize(String splitId, int index, double fraction) {
    if (locked) return this;
    return copyWith(root: _resize(root, splitId, index, fraction));
  }

  static DockNode _resize(
    DockNode node,
    String splitId,
    int index,
    double fraction,
  ) {
    if (node is DockSplit && node.id == splitId) {
      if (index < 0 || index + 1 >= node.children.length) return node;

      final shares = [...node.shares];
      // Only the two either side of the handle move. Everything else keeps
      // what it had, which is what dragging one divider means.
      final pair = shares[index] + shares[index + 1];
      final wanted = fraction.clamp(0.08, 0.92);
      shares[index] = pair * wanted;
      shares[index + 1] = pair * (1 - wanted);
      return node.copyWith(weights: shares);
    }
    if (node is DockSplit) {
      return node.copyWith(
        children: [
          for (final child in node.children)
            _resize(child, splitId, index, fraction),
        ],
      );
    }
    return node;
  }

  static DockGroup? _firstGroup(DockNode node) {
    if (node is DockGroup) return node;
    if (node is DockSplit) {
      for (final child in node.children) {
        final found = _firstGroup(child);
        if (found != null) return found;
      }
    }
    return null;
  }

  static DockGroup? _groupHolding(DockNode node, String panelId) {
    if (node is DockGroup) {
      return node.panels.any((p) => p.id == panelId) ? node : null;
    }
    if (node is DockSplit) {
      for (final child in node.children) {
        final found = _groupHolding(child, panelId);
        if (found != null) return found;
      }
    }
    return null;
  }

  static bool _hasGroup(DockNode node, String groupId) {
    if (node is DockGroup) return node.id == groupId;
    if (node is DockSplit) {
      return node.children.any((child) => _hasGroup(child, groupId));
    }
    return false;
  }

  static int _next = 0;

  static String _freshId(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch}_${_next++}';

  String toText() => '${const JsonEncoder.withIndent('  ').convert({
        'kind': 'orbis.layout',
        'formatVersion': formatVersion,
        'locked': locked,
        'root': root.toJson(),
      })}\n';

  /// Reads one, or null when it is not a layout.
  ///
  /// Null rather than an exception: a layout file written by an older build is
  /// not worth refusing to open the editor over, and the standard arrangement
  /// is always there to fall back to.
  static DockLayout? read(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?> || parsed['kind'] != 'orbis.layout') {
      return null;
    }

    final root = DockNode.fromJson(parsed['root']);
    if (root == null) return null;

    return DockLayout(
      root: root,
      locked: parsed['locked'] == true,
    );
  }
}
