import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/inspector.dart' show FieldRow;
import 'package:orbis_editor/src/editor/ui_canvas.dart';
import 'package:orbis_editor/src/editor/ui_editor.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('orbis_ui'));
  tearDown(() => root.deleteSync(recursive: true));

  const menu = UiDocument(
    name: 'Main menu',
    root: UiNode(
      type: 'stack',
      classes: 'w-full h-full',
      children: [
        UiNode(
          type: 'text',
          classes: 'text-3xl',
          css: 'left: 80px; top: 60px',
          text: 'Orbis',
        ),
        UiNode(
          type: 'row',
          classes: 'gap-2',
          css: 'left: 80px; top: 160px',
          children: [
            UiNode(type: 'button', text: 'Play'),
            UiNode(type: 'button', text: 'Quit'),
          ],
        ),
      ],
    ),
  );

  Future<void> showCanvas(
    WidgetTester tester, {
    bool designing = true,
    List<int>? selected,
    ValueChanged<List<int>>? onSelect,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: Scaffold(
        body: UiCanvasView(
          document: menu,
          designing: designing,
          selected: selected,
          onSelect: onSelect,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('the canvas', () {
    testWidgets('shows the interface itself', (tester) async {
      await showCanvas(tester);

      expect(find.text('Orbis'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('draws its bounds while designing', (tester) async {
      await showCanvas(tester);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('the game gets the interface and no canvas', (tester) async {
      await showCanvas(tester, designing: false);

      // The words are there. The guides are not — and not hidden: with no
      // decorator the chrome was never built.
      expect(find.text('Orbis'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null),
        findsNothing,
      );
    });

    testWidgets('nothing is wrapped when it is not being designed',
        (tester) async {
      await showCanvas(tester, designing: false);

      // No hover regions and no hit targets over the elements: exactly the
      // widget tree a game builds.
      final designing = find.byType(MouseRegion);
      final before = tester.widgetList(designing).length;

      await showCanvas(tester);
      expect(tester.widgetList(find.byType(MouseRegion)).length,
          greaterThan(before));
    });

    testWidgets('clicking an element selects the one under the pointer',
        (tester) async {
      List<int>? picked;
      await showCanvas(tester, onSelect: (path) => picked = path);

      await tester.tap(find.text('Quit'));
      await tester.pumpAndSettle();

      // The innermost element, not the row it sits in or the stack under it.
      expect(picked, [1, 1]);
    });

    testWidgets('a click in the game does not select anything',
        (tester) async {
      List<int>? picked;
      await showCanvas(tester, designing: false, onSelect: (path) => picked = path);

      await tester.tap(find.text('Quit'));
      await tester.pumpAndSettle();

      expect(picked, isNull);
    });

    testWidgets('the interface is laid out at the size it was authored at',
        (tester) async {
      await showCanvas(tester);

      // Scaled to fit, not reflowed: a canvas that relaid itself into the
      // panel would be showing a different interface from the game.
      expect(find.byType(FittedBox), findsWidgets);
    });
  });

  group('laying one out', () {
    /// Text on the canvas rather than in the element tree, which names
    /// elements by their words and so carries the same strings.
    Finder onCanvas(String text) => find.descendant(
          of: find.byType(UiCanvasView),
          matching: find.text(text),
        );

    /// Drags something by an exact amount.
    ///
    /// Not tester.drag: that pads the movement to clear the drag slop, so the
    /// pointer does not travel the distance it was asked to and a test that
    /// checks the thing followed it measures the padding instead.
    Future<void> dragBy(
      WidgetTester tester,
      Finder what,
      Offset by, {
      int steps = 12,
    }) async {
      final pointer = await tester.startGesture(tester.getCenter(what));
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 0; i < steps; i++) {
        await pointer.moveBy(by / steps.toDouble());
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pointer.up();
      await tester.pumpAndSettle();
    }

    Future<UiEditor> open(WidgetTester tester, {UiDocument? document}) async {
      final path = p.join(root.path, 'menu.oui');
      final held = document ?? menu;
      File(path).writeAsStringSync(held.toText());

      await tester.binding.setSurfaceSize(const Size(1600, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final editor = UiEditor(path: path, document: held);
      await tester.pumpWidget(MaterialApp(theme: orbisTheme(), home: editor));
      await tester.pumpAndSettle();
      return editor;
    }

    testWidgets('the elements are listed as a tree', (tester) async {
      await open(tester);

      expect(find.text('ELEMENTS'), findsOneWidget);
      // Named by their words where they have any, since "Play" says more
      // about which button it is than "button" does.
      expect(find.text('Play'), findsWidgets);
    });

    testWidgets('adding puts an element inside the selection', (tester) async {
      await open(tester);

      // The root is selected to begin with.
      await tester.tap(find.widgetWithText(Container, 'Box').first);
      await tester.pumpAndSettle();

      expect(find.text('box'), findsWidgets);
    });

    testWidgets('a change can be undone', (tester) async {
      await open(tester);
      await tester.tap(find.widgetWithText(Container, 'Box').first);
      await tester.pumpAndSettle();
      expect(find.text('box'), findsWidgets);

      await tester.tap(find.widgetWithText(Container, 'Undo').first);
      await tester.pumpAndSettle();

      expect(find.text('box'), findsNothing);
    });

    testWidgets('saving writes a file that opens again', (tester) async {
      await open(tester);
      await tester.tap(find.widgetWithText(Container, 'Box').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Container, 'Save').first);
      await tester.pumpAndSettle();

      final written =
          UiDocument.read(File(p.join(root.path, 'menu.oui')).readAsStringSync());
      expect(written, isNotNull);
      expect(written!.root.children.last.type, 'box');
    });

    testWidgets('previewing takes the chrome away', (tester) async {
      await open(tester);

      final guides =
          find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null);
      expect(guides, findsWidgets);

      await tester.tap(find.widgetWithText(Container, 'Preview').first);
      await tester.pumpAndSettle();

      expect(guides, findsNothing);
      // And the interface is still there, which is the point of the toggle.
      expect(onCanvas('Orbis'), findsOneWidget);
    });

    int outlinesOn(WidgetTester tester) => tester
        .widgetList<DecoratedBox>(find.descendant(
          of: find.byType(UiCanvasView),
          matching: find.byType(DecoratedBox),
        ))
        .length;

    Finder guides() =>
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null);

    testWidgets('turning element outlines off leaves only the selection',
        (tester) async {
      await open(tester);
      expect(outlinesOn(tester), greaterThan(1));

      await tester.tap(find.widgetWithText(Container, 'Element outlines').first);
      await tester.pumpAndSettle();

      // One left: the selected element keeps its mark, because taking away
      // the thing that answers "what am I editing" is a lost selection rather
      // than a view mode.
      expect(outlinesOn(tester), 1);
    });

    testWidgets('the canvas guides have a toggle of their own', (tester) async {
      await open(tester);
      expect(guides(), findsWidgets);

      await tester.tap(find.widgetWithText(Container, 'Canvas guides').first);
      await tester.pumpAndSettle();

      expect(guides(), findsNothing);
      // And the elements are still outlined: two controls, two things.
      expect(outlinesOn(tester), greaterThan(1));
    });

    testWidgets('an element on a stack stays under the pointer',
        (tester) async {
      await open(tester);

      final pointer =
          await tester.startGesture(tester.getCenter(onCanvas('Orbis')));
      await tester.pump(const Duration(milliseconds: 40));

      // Past the slop first. Flutter does not call a drag a drag until the
      // pointer has moved far enough to mean it, and that first bit of
      // movement is swallowed — in the editor as much as in this test.
      for (var i = 0; i < 6; i++) {
        await pointer.moveBy(const Offset(8, 4));
        await tester.pump(const Duration(milliseconds: 16));
      }

      final wasAt = tester.getTopLeft(onCanvas('Orbis'));
      for (var i = 0; i < 10; i++) {
        await pointer.moveBy(const Offset(12, 6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final nowAt = tester.getTopLeft(onCanvas('Orbis'));
      await pointer.up();
      await tester.pumpAndSettle();

      // On screen, not in canvas units. The canvas is zoomed to fit the panel,
      // so an element that moved by the drag in canvas units would lag the
      // pointer by exactly the zoom. What it has to do is stay under it.
      expect(nowAt.dx - wasAt.dx, closeTo(120, 1));
      expect(nowAt.dy - wasAt.dy, closeTo(60, 1));
    });

    testWidgets('where it was dragged to is what gets saved', (tester) async {
      await open(tester);

      final before = menu.root.children.first.placed!;
      await dragBy(tester, onCanvas('Orbis'), const Offset(120, 60));
      await tester.tap(find.widgetWithText(Container, 'Save').first);
      await tester.pumpAndSettle();

      final written = UiDocument.read(
        File(p.join(root.path, 'menu.oui')).readAsStringSync(),
      )!;
      final after = written.root.children.first.placed!;

      // Further than the drag in canvas units, because the canvas is scaled
      // down to fit: a hundred and twenty pixels of pointer is more than a
      // hundred and twenty pixels of a 1920-wide canvas shown in less.
      expect(after.left, greaterThan(before.left + 120));
      expect(after.top, greaterThan(before.top + 60));
    });

    testWidgets('a whole drag is one undo step', (tester) async {
      await open(tester);

      await dragBy(tester, onCanvas('Orbis'), const Offset(80, 0));
      await tester.tap(find.widgetWithText(Container, 'Undo').first);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(Container, 'Save').first);
      await tester.pumpAndSettle();
      final written = UiDocument.read(
        File(p.join(root.path, 'menu.oui')).readAsStringSync(),
      )!;

      // One press put it back, not eighty.
      expect(
        written.root.children.first.placed!.left,
        menu.root.children.first.placed!.left,
      );
    });

    testWidgets('an element a column lays out is not draggable',
        (tester) async {
      const flowed = UiDocument(
        root: UiNode(
          type: 'column',
          classes: 'w-full h-full p-8',
          children: [UiNode(type: 'text', text: 'Row one')],
        ),
      );
      await open(tester, document: flowed);

      await dragBy(tester, onCanvas('Row one'), const Offset(100, 100));

      // Nothing to save: a position its parent throws away on the next layout
      // is not a move, it is a lie.
      expect(find.widgetWithText(Container, 'Save •'), findsNothing);
      expect(onCanvas('Row one'), findsOneWidget);
    });

    testWidgets('the canvas size can be changed', (tester) async {
      await open(tester);

      await tester.tap(find.text('390 × 844'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Container, 'Save').first);
      await tester.pumpAndSettle();

      final written =
          UiDocument.read(File(p.join(root.path, 'menu.oui')).readAsStringSync());
      expect(written!.canvas.width, 390);
      expect(written.canvas.height, 844);
    });

    testWidgets('editing an element reaches the canvas', (tester) async {
      await open(tester);

      // Select the title on the canvas, then retype it.
      await tester.tap(onCanvas('Orbis'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.widgetWithText(FieldRow, 'Words'),
          matching: find.byType(TextField),
        ),
        'Orbis Engine',
      );
      await tester.pumpAndSettle();

      // Typed into the panel, changed on the canvas.
      expect(onCanvas('Orbis Engine'), findsOneWidget);
    });
  });
}
