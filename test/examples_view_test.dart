import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/launcher/examples_view.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_examples/orbis_examples.dart';

void main() {
  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: const Scaffold(body: ExamplesView()),
    ));
    await tester.pump();
  }

  group('the examples view', () {
    testWidgets('it lists what the package offers, in its order', (tester) async {
      // Against the package rather than a list typed out here: a copy is how
      // a test ends up passing for an example nobody can reach.
      await show(tester);

      final expected = engineExamples();
      expect(expected, isNotEmpty);
      // Scrolled to, not merely looked for. The list builds rows lazily, so
      // an example below the fold is not in the tree until it is scrolled
      // into view — and asserting on it without scrolling would fail for
      // exactly the examples most recently added.
      // Scoped to the list. The example on show is named twice — once in
      // the list and once as the title over the viewport — and scrolling to
      // a finder that matches both is a "too many elements" rather than a
      // scroll.
      final list = find.byType(ListView).first;
      for (final example in expected) {
        final inList = find.descendant(
          of: list,
          matching: find.text(example.name),
        );
        await tester.scrollUntilVisible(inList, 120,
            scrollable: find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            ));
        expect(inList, findsOneWidget,
            reason: '${example.name} is missing from the list');
      }
    });

    testWidgets('it opens on the first one', (tester) async {
      await show(tester);
      // Twice: once in the list, once as the title over the viewport.
      expect(find.text(engineExamples().first.name), findsNWidgets(2));
    });

    testWidgets('choosing another shows it instead', (tester) async {
      await show(tester);
      final second = engineExamples()[1];

      await tester.tap(find.text(second.name).first);
      await tester.pump();

      expect(find.text(second.name), findsNWidgets(2));
      expect(find.text(second.blurb), findsWidgets);
    });

    testWidgets('the lines that do it are shown, and can be copied',
        (tester) async {
      // Selectable rather than plain text: an example somebody cannot copy
      // out of is an example they retype with a mistake in it.
      await show(tester);
      expect(find.byType(SelectableText), findsOneWidget);

      final code = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(code.data, isNotEmpty);
      expect(code.data, engineExamples().first.code.trim());
    });

    testWidgets('off macOS it says so and still shows the code',
        (tester) async {
      // The renderer draws on macOS only so far; a blank panel would read as
      // a broken editor rather than an unsupported platform.
      await show(tester);

      expect(find.textContaining('macOS only'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('each example brings its own settings', (tester) async {
      await show(tester);
      expect(find.text('SETTINGS'), findsOneWidget);
      expect(find.text('HOW'), findsOneWidget);
    });
  });

  group('the launcher', () {
    testWidgets('two views do not share an example instance', (tester) async {
      // An example owns its settings. Two windows showing the same one should
      // not be moving each other's sliders.
      final one = engineExamples();
      final two = engineExamples();
      expect(identical(one.first, two.first), isFalse);
      expect(one.first.name, two.first.name);
    });
  });

  group('the example view fills the window', () {
    testWidgets('the sides can be shut, one at a time', (tester) async {
      await show(tester);

      final examples = engineExamples();
      // The list is there to begin with: every example is named in it.
      expect(find.text(examples[1].name), findsWidgets);

      await tester.tap(find.byTooltip('Hide the list'));
      await tester.pump();
      expect(
        find.text(examples[1].name),
        findsNothing,
        reason: 'the list of the others should have gone',
      );

      // The settings panel is the other side, and shuts on its own.
      expect(find.byTooltip('Hide the settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide the settings'));
      await tester.pump();
      expect(find.byTooltip('Show the settings'), findsOneWidget);
      expect(find.byTooltip('Show the list'), findsOneWidget);
    });

    testWidgets('filling the window leaves a way back', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var full = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ExamplesView(onFull: (value) => full = value),
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('Fill the window'));
      await tester.pump();

      expect(full, isTrue, reason: 'whatever is around it has to be told');
      // Both sides go with it, and the way back is where a project puts it.
      expect(find.byTooltip('Hide the list'), findsNothing);
      expect(find.byTooltip('Back to the examples'), findsOneWidget);

      await tester.tap(find.byTooltip('Back to the examples'));
      await tester.pump();

      expect(full, isFalse);
      expect(find.byTooltip('Hide the list'), findsOneWidget);
    });
  });
}
