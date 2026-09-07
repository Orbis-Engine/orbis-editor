import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/frame_rate.dart';

void main() {
  FrameTiming timingOf({
    required int buildUs,
    required int rasterUs,
    required int startUs,
  }) =>
      FrameTiming(
        vsyncStart: startUs,
        buildStart: startUs,
        buildFinish: startUs + buildUs,
        rasterStart: startUs + buildUs,
        rasterFinish: startUs + buildUs + rasterUs,
        rasterFinishWallTime: startUs + buildUs + rasterUs,
      );

  test('it says nothing until there is something to say', () {
    expect(FrameRate().fps, isNull,
        reason: 'a number invented before the first frame is a lie');
  });

  testWidgets('it measures what the frames actually took', (tester) async {
    final rate = FrameRate()..start();
    addTearDown(rate.dispose);

    // Ten milliseconds of work a frame, so a hundred a second's worth of
    // headroom — whatever rate they actually arrived at.
    for (var i = 0; i < FrameRate.window; i++) {
      rate.reportForTest([
        timingOf(buildUs: 4000, rasterUs: 6000, startUs: i * 16667),
      ]);
    }

    expect(rate.fps, closeTo(100, 1));
    expect(rate.buildMs, greaterThan(0));
    expect(rate.rasterMs, greaterThan(rate.buildMs),
        reason: 'the raster half was the longer one here');
    expect(rate.gpuBound, isTrue);
  });

  testWidgets('a slow build says the processor, not the card', (tester) async {
    final rate = FrameRate()..start();
    addTearDown(rate.dispose);

    for (var i = 0; i < FrameRate.window; i++) {
      rate.reportForTest([
        timingOf(buildUs: 20000, rasterUs: 2000, startUs: i * 33000),
      ]);
    }

    expect(rate.gpuBound, isFalse,
        reason: '"slow" and "slow at what" are different questions');
    // Twenty-two milliseconds of work is under fifty a second.
    expect(rate.fps, lessThan(50));
  });

  testWidgets('it only speaks a few times a second', (tester) async {
    final rate = FrameRate()..start();
    addTearDown(rate.dispose);

    var said = 0;
    rate.addListener(() => said++);
    for (var i = 0; i < 120; i++) {
      rate.reportForTest([
        timingOf(buildUs: 1000, rasterUs: 1000, startUs: i * 16667),
      ]);
    }

    // A status bar rebuilt sixty times a second to say how fast things are
    // would be its own answer to the question.
    expect(said, lessThan(4));
  });

  testWidgets('it forgets frames older than its window', (tester) async {
    final rate = FrameRate()..start();
    addTearDown(rate.dispose);

    for (var i = 0; i < FrameRate.window * 3; i++) {
      rate.reportForTest([
        timingOf(buildUs: 1000, rasterUs: 1000, startUs: i * 16667),
      ]);
    }
    // Then a run of slow ones, enough to fill the window.
    for (var i = 0; i < FrameRate.window; i++) {
      rate.reportForTest([
        timingOf(buildUs: 40000, rasterUs: 10000, startUs: i * 50000),
      ]);
    }

    // Fifty milliseconds of work a frame: twenty a second.
    expect(rate.fps, closeTo(20, 1),
        reason: 'what it is doing now, not what it did a minute ago');
  });

  test('stopping twice is not an error, and neither is starting twice', () {
    final rate = FrameRate()
      ..start()
      ..start()
      ..stop()
      ..stop();
    expect(rate.fps, isNull);
  });
}
