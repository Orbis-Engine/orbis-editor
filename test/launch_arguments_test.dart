import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/main.dart' show projectPathIn;

/// Opening a project by naming it, which is how `blender file.blend` and
/// `code .` work and the only way to reach the editor without clicking.
///
/// It had never worked. On macOS a Flutter app is started by LaunchServices
/// and the embedder hands the Dart entrypoint nothing unless the runner is
/// told to, so `main`'s arguments were always empty — the editor opened its
/// launcher and said nothing, which reads as the path being wrong rather than
/// as never having been looked at. The runner passes them now; this is the
/// half that decides which of them is a path.
void main() {
  group('the folder named on the command line', () {
    test('is the first thing that is not a switch', () {
      expect(projectPathIn(['/Users/me/Projects/Thing']),
          '/Users/me/Projects/Thing');
      expect(projectPathIn([]), isNull);
    });

    test("macOS's own switches are not projects", () {
      // What Xcode adds to a debug run. Taking the first non-dash argument
      // naively opens a project called YES, and reports it missing.
      expect(
        projectPathIn(['-NSDocumentRevisionsDebugMode', 'YES']),
        isNull,
        reason: 'YES is the value of a switch, not a folder',
      );
      expect(
        projectPathIn([
          '-NSDocumentRevisionsDebugMode',
          'YES',
          '/Users/me/Projects/Thing',
        ]),
        '/Users/me/Projects/Thing',
      );
    });

    test('a switch is assumed to take a value, which is the limit of this', () {
      // Nothing in an argument list says whether a switch takes a value, and
      // the two readings disagree: `-NSDocumentRevisionsDebugMode YES` needs
      // the YES skipped, and a valueless switch before a path would need it
      // kept. This takes the first reading, because the editor defines no
      // switches of its own — every dash argument it ever sees is one of
      // macOS's key/value pairs.
      //
      // Written down rather than left to be discovered: if the editor ever
      // does take a flag of its own, this is what will need to change.
      expect(projectPathIn(['-flag', '/tmp/p']), isNull);
      expect(projectPathIn(['/tmp/p', '-flag']), '/tmp/p');
    });
  });
}
