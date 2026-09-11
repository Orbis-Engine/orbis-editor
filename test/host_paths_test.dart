import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/platform/host_paths.dart';

void main() {
  test('HOME, as macOS and Linux set it', () {
    expect(homeDirectory({'HOME': '/Users/robin'}), '/Users/robin');
  });

  test('USERPROFILE, where HOME is not set', () {
    expect(
      homeDirectory({'USERPROFILE': r'C:\Users\Robin'}),
      r'C:\Users\Robin',
    );
  });

  test('HOMEDRIVE and HOMEPATH together, where neither of the above is set', () {
    expect(
      homeDirectory({'HOMEDRIVE': r'C:', 'HOMEPATH': r'\Users\Robin'}),
      r'C:\Users\Robin',
    );
  });

  test('HOME wins when more than one is set', () {
    expect(
      homeDirectory({
        'HOME': '/Users/robin',
        'USERPROFILE': r'C:\Users\Robin',
        'HOMEDRIVE': r'C:',
        'HOMEPATH': r'\Users\Robin',
      }),
      '/Users/robin',
    );
  });

  test('USERPROFILE wins over HOMEDRIVE/HOMEPATH', () {
    expect(
      homeDirectory({
        'USERPROFILE': r'C:\Users\Robin',
        'HOMEDRIVE': r'C:',
        'HOMEPATH': r'\Someone\Else',
      }),
      r'C:\Users\Robin',
    );
  });

  test('null when nothing says where home is', () {
    expect(homeDirectory({}), isNull);
  });

  test('an empty HOME does not count as set', () {
    // Seen on some CI runners and restricted shells, where the variable
    // exists but was cleared rather than removed.
    expect(homeDirectory({'HOME': '', 'USERPROFILE': r'C:\Users\Robin'}),
        r'C:\Users\Robin');
  });

  test('HOMEDRIVE without HOMEPATH is not enough', () {
    expect(homeDirectory({'HOMEDRIVE': r'C:'}), isNull);
  });
}
