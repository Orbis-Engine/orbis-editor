import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/console.dart';

void main() {
  late EditorLog log;

  setUp(() => log = EditorLog(limit: 5));
  tearDown(() => log.dispose());

  group('keeping what was said', () {
    test('an entry keeps its level and its detail', () {
      log.error('It did not build', detail: 'line 4: expected ;');

      final entry = log.entries.single;
      expect(entry.level, LogLevel.error);
      expect(entry.message, 'It did not build');
      expect(entry.detail, contains('line 4'));
    });

    test('the same thing said twice is one entry that says twice', () {
      log.warn('A mesh is missing');
      log.warn('A mesh is missing');
      log.warn('A mesh is missing');

      expect(log.entries, hasLength(1));
      expect(log.entries.single.repeats, 3);
    });

    test('something else in between breaks the run', () {
      log.warn('A mesh is missing');
      log.info('Saved');
      log.warn('A mesh is missing');

      expect(log.entries, hasLength(3));
    });

    test('a message that arrives every frame does not fill it', () {
      for (var i = 0; i < 400; i++) {
        log.warn('crate.glb is not there');
      }
      expect(log.entries, hasLength(1));
      expect(log.entries.single.repeats, 400);
    });

    test('old entries fall off rather than growing without bound', () {
      for (var i = 0; i < 12; i++) {
        log.info('Step $i');
      }

      expect(log.entries, hasLength(5));
      expect(log.entries.first.message, 'Step 7');
      expect(log.entries.last.message, 'Step 11');
    });

    test('it counts each level, for the badge on the tab', () {
      log.info('One');
      log.warn('Two');
      log.error('Three');
      log.error('Four');

      expect(log.countOf(LogLevel.info), 1);
      expect(log.countOf(LogLevel.warning), 1);
      expect(log.countOf(LogLevel.error), 2);
      expect(log.hasErrors, isTrue);
    });

    test('clearing empties it', () {
      log.error('Something');
      log.clear();
      expect(log.entries, isEmpty);
      expect(log.hasErrors, isFalse);
    });

    test('anything listening hears about a new entry', () {
      var told = 0;
      log.addListener(() => told++);

      log.info('One');
      log.info('One');

      // Twice: the second folded into the first, and something showing the
      // count still has to redraw.
      expect(told, 2);
    });
  });

  group('what Flutter throws', () {
    test('lands in the console rather than only in a terminal', () {
      final stop = log.catchFlutterErrors();
      addTearDown(stop);

      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('a widget went wrong'),
        library: 'orbis test',
      ));

      final entry = log.entries.single;
      expect(entry.level, LogLevel.error);
      expect(entry.detail, contains('a widget went wrong'));
      expect(entry.source, 'flutter');
    });

    test('disposing gives Flutter its error handler back', () {
      // What happened: the handler outlived the log it wrote into. It called
      // `notifyListeners` on a disposed notifier, which threw, and that throw
      // was itself an unhandled error — dispatched straight back to the same
      // handler, which threw again. One real exception became eight hundred
      // and forty lines, and the real one was the first, off the top.
      final before = FlutterError.onError;

      final closing = EditorLog();
      closing.catchFlutterErrors();
      expect(FlutterError.onError, isNot(same(before)));

      closing.dispose();

      expect(
        FlutterError.onError,
        same(before),
        reason: 'a handler still pointing at a disposed log is the loop',
      );
    });

    test('a closed log quietly drops what it is told', () {
      // Belt as well as braces: even with the handler still installed — a
      // caller that disposed in the wrong order, say — saying something to a
      // closed log is a no-op rather than a throw.
      final closing = EditorLog();
      closing.dispose();

      expect(() => closing.error('too late'), returnsNormally);
      expect(closing.entries, isEmpty);
    });

    test('putting the handler back stops it', () {
      log.catchFlutterErrors()();

      // Whatever was there before is back, so nothing more arrives here.
      final before = log.entries.length;
      final quiet = FlutterError.onError;
      FlutterError.onError = (_) {};
      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('after'),
        library: 'orbis test',
      ));
      FlutterError.onError = quiet;

      expect(log.entries, hasLength(before));
    });
  });
}
