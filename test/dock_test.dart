import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/dock.dart';

void main() {
  /// The ids of the panels in a group, for reading assertions easily.
  List<String> panelsIn(DockNode node, String groupId) {
    DockGroup? find(DockNode at) {
      if (at is DockGroup) return at.id == groupId ? at : null;
      if (at is DockSplit) {
        for (final child in at.children) {
          final found = find(child);
          if (found != null) return found;
        }
      }
      return null;
    }

    return [for (final panel in find(node)?.panels ?? const []) panel.id];
  }

  int splitsIn(DockNode node) {
    if (node is DockSplit) {
      return 1 + node.children.fold(0, (sum, c) => sum + splitsIn(c));
    }
    return 0;
  }

  group('the standard arrangement', () {
    test('holds the panels the editor opens with', () {
      final layout = DockLayout.standard();
      final ids = [for (final panel in layout.panels) panel.id];

      expect(ids, containsAll(['outliner', 'scene', 'inspector', 'project']));
      expect(layout.holds('console'), isTrue);
    });

    test('the scene and the game share one space', () {
      expect(panelsIn(DockLayout.standard().root, 'centre'),
          ['scene', 'game']);
    });

    test('four views is four scene panels', () {
      final layout = DockLayout.fourViews();
      final viewports = layout.panels
          .where((panel) => panel.kind == PanelKind.viewport)
          .toList();

      expect(viewports, hasLength(4));
      // Ids of their own, or the second would be looking wherever the first
      // was: a camera is filed under the panel it belongs to.
      expect({for (final v in viewports) v.id}, hasLength(4));
    });
  });

  group('docking', () {
    test('onto a side makes a split', () {
      final was = DockLayout.standard();
      final now = was.dock('inspector', 'left', DockSide.bottom);

      expect(splitsIn(now.root), greaterThan(splitsIn(was.root)));
      expect(now.holds('inspector'), isTrue);
      // Out of its old group and into a new one under the outliner.
      expect(panelsIn(now.root, 'right'), isEmpty);
    });

    test('onto the centre makes it another tab', () {
      final now =
          DockLayout.standard().dock('inspector', 'left', DockSide.centre);

      expect(panelsIn(now.root, 'left'), ['outliner', 'inspector']);
      // And the one just dropped is the one showing.
      expect(splitsIn(now.root), splitsIn(DockLayout.standard().root));
    });

    test('a group left empty collapses, and so does the split around it', () {
      final was = DockLayout.standard();
      // The inspector is the only panel in its group.
      final now = was.dock('inspector', 'left', DockSide.centre);

      expect(panelsIn(now.root, 'right'), isEmpty);
      // The middle split had three children and now has two, rather than
      // keeping an empty column.
      final middle = now.root as DockSplit;
      final inner = middle.children.first as DockSplit;
      expect(inner.children, hasLength(2));
    });

    test('a split left with one child is replaced by that child', () {
      var layout = DockLayout.standard();
      layout = layout.dock('inspector', 'left', DockSide.centre);
      layout = layout.dock('scene', 'left', DockSide.centre);
      layout = layout.dock('game', 'left', DockSide.centre);

      // Everything ended up in one group, so the row that held three columns
      // is gone rather than being a row of one.
      final root = layout.root as DockSplit;
      expect(root.children.first, isA<DockGroup>());
    });

    test('dropping a panel on its own group does nothing', () {
      final was = DockLayout.standard();
      final now = was.dock('scene', 'centre', DockSide.centre);

      expect(panelsIn(now.root, 'centre'), ['scene', 'game']);
      expect(splitsIn(now.root), splitsIn(was.root));
    });

    test('dropping the only panel of a group onto itself keeps it', () {
      final was = DockLayout.standard();
      final now = was.dock('outliner', 'left', DockSide.right);

      expect(now.holds('outliner'), isTrue);
      expect(now.panels, hasLength(was.panels.length));
    });

    test('a locked layout refuses to be rearranged', () {
      final locked = DockLayout.standard().copyWith(locked: true);
      final after = locked.dock('inspector', 'left', DockSide.bottom);

      expect(panelsIn(after.root, 'right'), ['inspector']);
      expect(identical(after.root, locked.root), isTrue);
    });

    test('nothing is lost, whatever is dragged where', () {
      var layout = DockLayout.standard();
      final before = layout.panels.length;

      for (final side in DockSide.values) {
        for (final panel in ['outliner', 'inspector', 'console', 'scene']) {
          layout = layout.dock(panel, 'centre', side);
          expect(layout.panels.length, before, reason: '$panel to $side');
        }
      }
    });
  });

  group('closing', () {
    test('takes the panel out and collapses what it leaves', () {
      final now = DockLayout.standard().close('inspector');

      expect(now.holds('inspector'), isFalse);
      final middle = (now.root as DockSplit).children.first as DockSplit;
      expect(middle.children, hasLength(2));
    });

    test('a tab beside others leaves the others alone', () {
      final now = DockLayout.standard().close('game');

      expect(panelsIn(now.root, 'centre'), ['scene']);
    });

    test('closing everything leaves something to open into', () {
      var layout = DockLayout.standard();
      for (final panel in [...layout.panels]) {
        layout = layout.close(panel.id);
      }
      expect(layout.panels, isNotEmpty);
    });
  });

  group('opening', () {
    test('a panel already there is shown rather than added twice', () {
      final was = DockLayout.standard();
      final now = was.add(
        const DockPanel(id: 'console', kind: PanelKind.console),
      );

      expect(now.panels.where((p) => p.id == 'console'), hasLength(1));
    });

    test('one that is not there is added', () {
      final now = DockLayout.standard().close('console').add(
            const DockPanel(id: 'console', kind: PanelKind.console),
          );
      expect(now.holds('console'), isTrue);
    });
  });

  group('sharing the space', () {
    test('weights are read as fractions that add up', () {
      const split = DockSplit(
        id: 's',
        axis: Axis.horizontal,
        children: [
          DockGroup(id: 'a', panels: []),
          DockGroup(id: 'b', panels: []),
        ],
        weights: [3, 1],
      );

      expect(split.shares, [0.75, 0.25]);
    });

    test('weights that do not match the children are evened out', () {
      const split = DockSplit(
        id: 's',
        axis: Axis.horizontal,
        children: [
          DockGroup(id: 'a', panels: []),
          DockGroup(id: 'b', panels: []),
        ],
        weights: [1],
      );

      // A file from an older build is allowed to be wrong; refusing to open
      // is worse than evening it out.
      expect(split.shares, [0.5, 0.5]);
    });

    test('dragging a divider only moves the two either side of it', () {
      final was = DockLayout.fourViews();
      final now = was.resize('viewsTop', 0, 0.7);

      DockSplit find(DockNode node, String id) {
        if (node is DockSplit) {
          if (node.id == id) return node;
          for (final child in node.children) {
            try {
              return find(child, id);
            } on StateError {
              continue;
            }
          }
        }
        throw StateError('no $id');
      }

      expect(find(now.root, 'viewsTop').shares.first, closeTo(0.7, 1e-9));
      // The split above them is untouched.
      expect(find(now.root, 'views').shares, find(was.root, 'views').shares);
    });

    test('a divider cannot be dragged off the edge', () {
      final now = DockLayout.fourViews().resize('viewsTop', 0, 5);
      expect(now.panels, hasLength(DockLayout.fourViews().panels.length));
    });

    test('a locked layout refuses to be resized', () {
      final locked = DockLayout.fourViews().copyWith(locked: true);
      expect(identical(locked.resize('viewsTop', 0, 0.9).root, locked.root),
          isTrue);
    });
  });

  group('the file', () {
    test('survives a round trip', () {
      final was = DockLayout.fourViews().copyWith(locked: true);
      final now = DockLayout.read(was.toText())!;

      expect(now.locked, isTrue);
      expect([for (final p in now.panels) p.id],
          [for (final p in was.panels) p.id]);
      expect(splitsIn(now.root), splitsIn(was.root));
    });

    test('the titles come back, so four views stay told apart', () {
      final now = DockLayout.read(DockLayout.fourViews().toText())!;
      final titles = [for (final panel in now.panels) panel.label];
      expect(titles, containsAll(['Scene', 'Scene 2', 'Scene 4']));
    });

    test('is not read from something that is not one', () {
      expect(DockLayout.read('nonsense'), isNull);
      expect(DockLayout.read('{"kind":"orbis.ui"}'), isNull);
      expect(DockLayout.read('{"kind":"orbis.layout"}'), isNull);
    });

    test('a panel kind it does not know is left out rather than guessed', () {
      final layout = DockLayout.read('''
{"kind":"orbis.layout","root":{"id":"g","panels":[
  {"id":"a","kind":"outliner"},
  {"id":"b","kind":"holodeck"}
]}}''')!;

      expect([for (final p in layout.panels) p.id], ['a']);
    });
  });
}
