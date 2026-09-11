import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/platform/command_shortcuts.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('commandIsMeta', () {
    test('true on macOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(commandIsMeta, isTrue);
    });

    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      test('false on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(commandIsMeta, isFalse);
      });
    }
  });

  group('commandShortcut', () {
    // SingleActivator has no value equality, so its fields are checked
    // individually rather than comparing whole instances.
    test('binds Meta on macOS, not Control', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final activator = commandShortcut(LogicalKeyboardKey.keyS);
      expect(activator.trigger, LogicalKeyboardKey.keyS);
      expect(activator.meta, isTrue);
      expect(activator.control, isFalse);
    });

    test('binds Control on Windows, not Meta', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final activator = commandShortcut(LogicalKeyboardKey.keyS);
      expect(activator.trigger, LogicalKeyboardKey.keyS);
      expect(activator.control, isTrue);
      expect(activator.meta, isFalse);
    });

    test('binds Control on Linux', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final activator = commandShortcut(LogicalKeyboardKey.keyS);
      expect(activator.control, isTrue);
      expect(activator.meta, isFalse);
    });

    test('carries shift and alt through, on top of the platform modifier',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final activator = commandShortcut(
        LogicalKeyboardKey.keyS,
        shift: true,
        alt: true,
      );
      expect(activator.control, isTrue);
      expect(activator.shift, isTrue);
      expect(activator.alt, isTrue);
    });
  });

  group('commandKeyLabel', () {
    test('the ⌘ glyph on macOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(commandKeyLabel, '⌘');
    });

    test('"Ctrl" on Windows and Linux', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(commandKeyLabel, 'Ctrl');
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(commandKeyLabel, 'Ctrl');
    });
  });

  group('commandShortcutLabel', () {
    test('macOS: the key alone, or shift immediately before it', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(commandShortcutLabel('S'), '⌘S');
      expect(commandShortcutLabel('S', shift: true), '⇧⌘S');
    });

    test('off macOS: "Ctrl+" and, with shift, "Ctrl+Shift+"', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(commandShortcutLabel('S'), 'Ctrl+S');
      expect(commandShortcutLabel('S', shift: true), 'Ctrl+Shift+S');
    });
  });

  group('isCommandModifierPressed', () {
    // testWidgets, not test: simulating a held key needs a live binding, and
    // the platform override has to be set and cleared with try/finally
    // around the test body — flutter_test checks that a test left every
    // debug-only flag the way it found it before either addTearDown or this
    // group's own tearDown above would get the chance to.
    testWidgets('reads Meta on macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(const SizedBox());
        expect(isCommandModifierPressed, isFalse);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        expect(isCommandModifierPressed, isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

        // Control is not Command on macOS.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(isCommandModifierPressed, isFalse);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('reads Control off macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(const SizedBox());
        expect(isCommandModifierPressed, isFalse);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(isCommandModifierPressed, isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // Meta is not Command on Windows.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        expect(isCommandModifierPressed, isFalse);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
