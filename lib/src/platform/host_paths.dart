import 'dart:io';

/// The current user's home directory, or null if nothing says where it is.
///
/// `HOME` first, because that is what macOS and Linux both set. Then
/// `USERPROFILE`, which is the equivalent Windows sets directly. Then
/// `HOMEDRIVE` joined with `HOMEPATH` — an older pair Windows also sets, and
/// the one still answered inside some restricted shells and CI runners where
/// `USERPROFILE` has been stripped out but the drive-and-path pair survives.
///
/// [environment] is [Platform.environment] by default; a test passes its own
/// map instead of having to fake the real environment to exercise a
/// particular platform's variables.
String? homeDirectory([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;

  final home = env['HOME'];
  if (home != null && home.isNotEmpty) return home;

  final profile = env['USERPROFILE'];
  if (profile != null && profile.isNotEmpty) return profile;

  final drive = env['HOMEDRIVE'];
  final path = env['HOMEPATH'];
  if (drive != null && drive.isNotEmpty && path != null && path.isNotEmpty) {
    return '$drive$path';
  }

  return null;
}
