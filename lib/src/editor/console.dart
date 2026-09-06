import 'dart:collection';

import 'package:flutter/foundation.dart';

/// How much somebody needs to care.
enum LogLevel {
  /// Something happened. A file was written, a script was built.
  info('Info'),

  /// Something is not as it should be but the editor carried on.
  warning('Warnings'),

  /// Something did not happen. A build failed, a file could not be read.
  error('Errors');

  const LogLevel(this.label);

  final String label;
}

/// One thing worth saying.
class LogEntry {
  LogEntry({
    required this.level,
    required this.message,
    required this.at,
    this.detail = '',
    this.source = '',
  });

  final LogLevel level;

  /// One line. What the status bar would have said.
  final String message;

  /// Everything else — a compiler's output, a stack trace. Shown when the
  /// entry is opened, because most of the time the first line is enough and a
  /// console that prints forty lines per entry is a console nobody reads.
  final String detail;

  /// Where it came from: 'build', 'scene', 'flutter'. For filtering later, and
  /// for saying which part of the editor is complaining.
  final String source;

  final DateTime at;

  /// How many times in a row this exact thing has been said.
  ///
  /// A message that arrives once a frame — a missing file named by an object
  /// being dragged — would otherwise fill the console in two seconds and push
  /// everything else off the top.
  int repeats = 1;

  bool sameAs(LogEntry other) =>
      other.level == level &&
      other.message == message &&
      other.detail == detail;
}

/// What the editor has to say for itself.
///
/// Everything that would have gone past in a status bar and been missed. A
/// message that appears for four seconds and then is gone is a message that
/// only helps somebody who happened to be looking at the right corner of the
/// screen — which, while they are reading a compiler error, they are not.
class EditorLog extends ChangeNotifier {
  EditorLog({this.limit = 500});

  /// How many to keep. Old ones fall off the top: a console that grows without
  /// bound is a leak that looks like a feature.
  final int limit;

  final Queue<LogEntry> _entries = Queue();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  int countOf(LogLevel level) =>
      _entries.where((entry) => entry.level == level).length;

  bool get hasErrors => _entries.any((e) => e.level == LogLevel.error);

  void say(
    String message, {
    LogLevel level = LogLevel.info,
    String detail = '',
    String source = '',
  }) {
    final entry = LogEntry(
      level: level,
      message: message,
      detail: detail,
      source: source,
      at: DateTime.now(),
    );

    // Folded rather than repeated. The same complaint arriving every frame is
    // one problem, not four hundred.
    if (_entries.isNotEmpty && _entries.last.sameAs(entry)) {
      _entries.last.repeats++;
      notifyListeners();
      return;
    }

    _entries.add(entry);
    while (_entries.length > limit) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void info(String message, {String detail = '', String source = ''}) =>
      say(message, detail: detail, source: source);

  void warn(String message, {String detail = '', String source = ''}) => say(
        message,
        level: LogLevel.warning,
        detail: detail,
        source: source,
      );

  void error(String message, {String detail = '', String source = ''}) => say(
        message,
        level: LogLevel.error,
        detail: detail,
        source: source,
      );

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Sends everything Flutter would have printed here as well.
  ///
  /// A widget that throws prints a red box and a wall of text to a terminal
  /// nobody running the editor is watching. Returns a function that puts the
  /// previous handlers back, which a test must call or the next test inherits
  /// this one's log.
  VoidCallback catchFlutterErrors() {
    final previousError = FlutterError.onError;
    final previousZone = PlatformDispatcher.instance.onError;

    FlutterError.onError = (details) {
      error(
        details.summary.toString(),
        detail: details.toString(),
        source: 'flutter',
      );
      previousError?.call(details);
    };

    PlatformDispatcher.instance.onError = (thrown, stack) {
      error('$thrown', detail: '$stack', source: 'flutter');
      return previousZone?.call(thrown, stack) ?? true;
    };

    return () {
      FlutterError.onError = previousError;
      PlatformDispatcher.instance.onError = previousZone;
    };
  }
}
