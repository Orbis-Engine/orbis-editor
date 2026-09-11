import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/platform/renderer_support.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the renderer is available on macOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(rendererAvailable, isTrue);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.fuchsia,
  ]) {
    test('the renderer is not available on $platform', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(rendererAvailable, isFalse);
    });
  }

  test('the placeholder reads as "not yet", not as something broken', () {
    final saying = rendererUnavailableMessage.toLowerCase();
    expect(saying, contains('not available'));
    expect(saying, contains('yet'));
    expect(saying, isNot(contains('error')));
    expect(saying, isNot(contains('fail')));
  });
}
