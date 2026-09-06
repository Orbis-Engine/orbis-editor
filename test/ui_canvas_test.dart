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
      type: 'column',
      classes: 'w-full h-full p-8 gap-4',
      children: [
        UiNode(type: 'text', classes: 'text-3xl', text: 'Orbis'),
        UiNode(
          type: 'row',
          classes: 'gap-2',
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

      // The innermost element, not the column it is three levels inside.
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
