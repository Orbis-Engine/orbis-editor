import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/ui_canvas.dart';
import 'package:orbis_editor/src/editor/ui_editor.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_editor/src/widgets/controls.dart';
import 'package:orbis_ui/orbis_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('orbis_ui_wide'));
  tearDown(() => root.deleteSync(recursive: true));

  /// A canvas whose one row is a column until there is room for a row. The
  /// smallest interface that is actually two layouts.
  const menu = UiDocument(
    name: 'Main menu',
    canvas: UiCanvas(fit: CanvasFit.responsive),
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
          type: 'box',
          classes: 'col md:row gap-2',
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
    Size? previewSize,
    bool showColumns = false,
    void Function(List<int>, Offset)? onMove,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: Scaffold(
        body: UiCanvasView(
          document: menu,
          previewSize: previewSize,
          showColumns: showColumns,
          onMove: onMove,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('a responsive canvas', () {
    testWidgets('lays out at the device being previewed, not the panel',
        (tester) async {
      // The whole reason to preview at all. The panel is 1400 wide either
      // way; what changes is which screen the interface thinks it is on.
      await showCanvas(tester, previewSize: const Size(390, 844));
      expect(
        find.descendant(of: find.byType(UiCanvasView), matching:
            find.byType(Row)),
        findsNothing,
      );

      await showCanvas(tester, previewSize: const Size(1440, 900));
      expect(
        find.descendant(of: find.byType(UiCanvasView), matching:
            find.byType(Row)),
        findsWidgets,
      );
    });

    testWidgets('text grows with the screen and stops growing', (tester) async {
      double sizeOfTitle() =>
          tester.widget<Text>(find.text('Orbis')).style!.fontSize!;

      await showCanvas(tester, previewSize: const Size(390, 844));
      final onPhone = sizeOfTitle();

      await showCanvas(tester, previewSize: const Size(1920, 1080));
      final onDesktop = sizeOfTitle();

      await showCanvas(tester, previewSize: const Size(7680, 4320));
      final onEverythingElse = sizeOfTitle();

      expect(onPhone, lessThan(onDesktop));
      expect(onEverythingElse, greaterThan(onDesktop));
      // Clamped. A wall-sized screen shows more of the interface, not four
      // times the type size.
      expect(onEverythingElse, onDesktop * 1.5);
    });

    testWidgets('a fixed canvas is still one layout, scaled', (tester) async {
      const fixed = UiDocument(
        canvas: UiCanvas(width: 1920, height: 1080),
        root: UiNode(
          type: 'stack',
          children: [UiNode(type: 'text', classes: 'md:text-3xl', text: 'Hi')],
        ),
      );

      Future<double> at(Size screen) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
          theme: orbisTheme(),
          home: Scaffold(
            body: UiCanvasView(document: fixed, previewSize: screen),
          ),
        ));
        await tester.pumpAndSettle();
        return tester.widget<Text>(find.text('Hi')).style!.fontSize!;
      }

      // Same layout at both, because the reference size is what it is laid
      // out at and the fit magnifies the result. Previewing a phone shows the
      // bars, not a second design.
      expect(await at(const Size(390, 844)), await at(const Size(1920, 1080)));
    });
  });

  group('the column grid', () {
    testWidgets('a drag never stops inside a column edge', (tester) async {
      final moves = <double>[];
      await showCanvas(
        tester,
        showColumns: true,
        onMove: (path, to) => moves.add(to.dx),
      );

      final title = find.descendant(
        of: find.byType(UiCanvasView),
        matching: find.text('Orbis'),
      );
      final pointer = await tester.startGesture(tester.getCenter(title));
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 0; i < 24; i++) {
        await pointer.moveBy(const Offset(14, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pointer.up();
      await tester.pumpAndSettle();

      expect(moves, isNotEmpty);

      // The invariant, rather than a position picked out of the arithmetic:
      // anything close enough to an edge to be pulled onto it is on it.
      const canvas = UiCanvas(fit: CanvasFit.responsive);
      for (final left in moves) {
        final nearest = canvas.snapAcross(left, 1920);
        expect(nearest == null || nearest == left, isTrue,
            reason: '$left is beside a column edge without being on it');
      }
      // And it crossed some on the way, so the invariant was tested.
      expect(
        moves.where((left) => canvas.snapAcross(left, 1920) == left),
        isNotEmpty,
      );
    });

    testWidgets('nothing snaps while the grid is down', (tester) async {
      final moves = <double>[];
      await showCanvas(tester, onMove: (path, to) => moves.add(to.dx));

      final title = find.descendant(
        of: find.byType(UiCanvasView),
        matching: find.text('Orbis'),
      );
      final pointer = await tester.startGesture(tester.getCenter(title));
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 0; i < 24; i++) {
        await pointer.moveBy(const Offset(14, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pointer.up();
      await tester.pumpAndSettle();

      // Every step is the pointer's own distance, so a position deliberately
      // put between two columns stays where it was put.
      const canvas = UiCanvas(fit: CanvasFit.responsive);
      expect(
        moves.where((left) => canvas.snapAcross(left, 1920) == left).length,
        lessThan(moves.length),
      );
    });
  });

  group('the editor', () {
    Future<String> open(WidgetTester tester, {UiDocument? document}) async {
      final path = p.join(root.path, 'menu.oui');
      final held = document ?? menu;
      File(path).writeAsStringSync(held.toText());

      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(MaterialApp(
        theme: orbisTheme(),
        home: UiEditor(path: path, document: held),
      ));
      await tester.pumpAndSettle();
      return path;
    }

    Future<void> press(WidgetTester tester, String label) async {
      final target = find.widgetWithText(Container, label).first;
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    UiDocument saved(WidgetTester tester, String path) {
      final read = UiDocument.read(File(path).readAsStringSync());
      expect(read, isNotNull);
      return read!;
    }

    bool gridIsUp(WidgetTester tester) =>
        tester
            .widget<OrbisButton>(
                find.widgetWithText(OrbisButton, 'Column grid'))
            .tone ==
        ButtonTone.primary;

    testWidgets('the toolbar says what the layout is answering to',
        (tester) async {
      await open(tester);

      // The one thing a responsive canvas has to say out loud, because a
      // prefixed class that appears to do nothing is somebody's afternoon.
      // Twice: the toolbar, and the canvas-size chip it agrees with.
      expect(find.text('1920 × 1080'), findsWidgets);
      expect(find.text('xl'), findsOneWidget);

      await press(tester, 'Phone');
      expect(find.text('390 × 844'), findsWidgets);
      expect(find.text('base'), findsOneWidget);
    });

    testWidgets('adding a column puts the grid up', (tester) async {
      await open(tester);
      expect(gridIsUp(tester), isFalse);

      await press(tester, 'Column');

      // Putting a container in and being shown nothing to line it up against
      // is where somebody goes looking for the setting.
      expect(gridIsUp(tester), isTrue);
    });

    testWidgets('adding a button leaves the grid alone', (tester) async {
      await open(tester);
      await press(tester, 'Button');
      expect(gridIsUp(tester), isFalse);
    });

    testWidgets('splitting makes a row of equal columns', (tester) async {
      final path = await open(tester);

      // The root is selected to begin with, so this splits the canvas.
      await press(tester, '3');
      await press(tester, 'Save');

      final root = saved(tester, path).root;
      expect(root.type, 'row');
      expect(root.children, hasLength(3));
      expect(root.children.every((child) => child.type == 'column'), isTrue);
      expect(
        root.children.every((child) => child.classes.contains('md:flex-1')),
        isTrue,
      );
      // Stacked until there is room: equal widths only where they are widths.
      expect(root.classes, contains('md:row'));
    });

    testWidgets('what was in it goes into the first column, without its place',
        (tester) async {
      final path = await open(tester);
      await press(tester, '2');
      await press(tester, 'Save');

      final root = saved(tester, path).root;
      expect(root.children.first.children, hasLength(2));
      expect(root.children.last.children, isEmpty);

      // Stripped of `left` and `top` on the way in. A Positioned that is no
      // longer in a stack does not lay out badly, it throws.
      for (final child in root.children.first.children) {
        expect(child.placed, isNull);
      }
    });

    testWidgets('a split row still shows what is in its columns',
        (tester) async {
      // The exact path somebody took: add a row to the canvas, split it into
      // four, put a button in the third column. It rendered nothing, because
      // four flexible columns inside a row with no width is not a layout
      // Flutter can do — it throws, and abandons the rest of the frame.
      await open(tester);

      await press(tester, 'Row');
      await press(tester, '4');

      await tester.tap(find.text('column').at(2));
      await tester.pumpAndSettle();
      await press(tester, 'Button');

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(UiCanvasView),
          matching: find.text('Button'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('splitting something placed on a stack gives it a width',
        (tester) async {
      final path = await open(tester);

      await press(tester, 'Row');
      await press(tester, '2');
      await press(tester, 'Save');

      // Reaching the far edge is the honest reading of "split this into
      // columns", and without it the columns have nothing to divide.
      final row = saved(tester, path).root.children.last;
      expect(row.css, contains('right: 0'));
    });

    testWidgets('columns stack on a phone and sit side by side on a laptop',
        (tester) async {
      await open(tester);
      await press(tester, 'Row');
      await press(tester, '3');

      Finder rowsOnCanvas() => find.descendant(
            of: find.byType(UiCanvasView),
            matching: find.byType(Row),
          );

      await press(tester, 'Laptop');
      expect(rowsOnCanvas(), findsWidgets);

      await press(tester, 'Phone');
      // Three columns across a phone are three columns nobody can read.
      expect(rowsOnCanvas(), findsNothing);
    });

    testWidgets('a device can be held sideways', (tester) async {
      await open(tester);

      await press(tester, 'Phone');
      expect(find.text('390 × 844'), findsWidgets);

      await press(tester, 'Landscape');
      expect(find.text('844 × 390'), findsWidgets);

      // The orientation is kept when the device changes, so turning a phone
      // over and then picking a tablet gives a tablet on its side.
      await press(tester, 'Tablet');
      expect(find.text('1112 × 834'), findsWidgets);
    });

    testWidgets('the grid says when it is drawing fewer columns than authored',
        (tester) async {
      await open(tester);
      expect(find.text('12 across this screen'), findsOneWidget);

      await press(tester, 'Phone');
      // Not twelve seven-pixel slivers, and it says so rather than leaving
      // somebody to count them and wonder what happened to their split.
      expect(find.text('4 across this screen — 12 is too fine here'),
          findsOneWidget);
    });

    testWidgets('the split can be undone', (tester) async {
      await open(tester);
      await press(tester, '2');
      expect(find.text('row'), findsWidgets);

      await press(tester, 'Undo');
      expect(find.text('stack'), findsWidgets);
    });
  });
}
