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
      for (final example in expected) {
        expect(find.text(example.name), findsWidgets,
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
}
