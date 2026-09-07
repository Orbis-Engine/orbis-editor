import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// How fast the editor is actually drawing.
///
/// Measured from Flutter's own frame timings rather than counted in a ticker.
/// A ticker says how often something asked to be drawn; this says how long
/// each frame took to build and raster, which is the number that means
/// anything when the answer is "it feels slow".
///
/// Both halves are kept apart on purpose. Build time is the editor's own
/// Dart work — a painter rebuilding geometry, a panel laying out — and raster
/// time is the GPU. Which of the two is the slow one decides where to look,
/// and a single frames-per-second figure hides it.
class FrameRate extends ChangeNotifier {
  /// How many frames are averaged over. A second's worth at sixty, so the
  /// number is steady enough to read and still moves when something changes.
  static const int window = 60;

  /// How often the reading is published.
  ///
  /// Not every frame: the thing showing it is a widget, and rebuilding a
  /// status bar sixty times a second to say how fast things are is its own
  /// answer to the question.
  static const Duration every = Duration(milliseconds: 400);

  final List<double> _spans = [];
  double _build = 0;
  double _raster = 0;
  DateTime _said = DateTime.fromMillisecondsSinceEpoch(0);
  bool _listening = false;

  /// Frames a second, or null before there is anything to say.
  ///
  /// Worked out from how long a frame *takes*, not from how often one
  /// arrives — so it is headroom rather than an observed rate. That is the
  /// more useful of the two here: an editor sitting still draws nothing at
  /// all, and a number that fell to zero every time somebody stopped moving
  /// the mouse would say nothing about whether the editor is fast.
  double? get fps {
    if (_spans.isEmpty) return null;
    final total = _spans.reduce((a, b) => a + b);
    return total <= 0 ? null : _spans.length * 1000 / total;
  }

  /// How long the slowest part of an average frame takes, in milliseconds.
  double get buildMs => _build;
  double get rasterMs => _raster;

  /// Whether the GPU is the one holding things up.
  bool get gpuBound => _raster > _build;

  void start() {
    if (_listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback(_took);
  }

  void stop() {
    if (!_listening) return;
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_took);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Hands it a set of timings directly.
  ///
  /// The only way to test this: the real ones come from the engine, and a
  /// test has no engine drawing frames at a rate anybody chose.
  @visibleForTesting
  void reportForTest(List<FrameTiming> timings) => _took(timings);

  void _took(List<FrameTiming> timings) {
    for (final timing in timings) {
      _spans.add(timing.totalSpan.inMicroseconds / 1000);
      _build += (timing.buildDuration.inMicroseconds / 1000 - _build) / window;
      _raster +=
          (timing.rasterDuration.inMicroseconds / 1000 - _raster) / window;
    }
    while (_spans.length > window) {
      _spans.removeAt(0);
    }

    final now = DateTime.now();
    if (now.difference(_said) < every) return;
    _said = now;
    notifyListeners();
  }
}
