import 'package:flutter/foundation.dart';

/// Whether the 3D renderer can run on this platform.
///
/// The renderer — Filament, reached through `orbis_filament` — is being
/// ported to Linux and Windows alongside the rest of the editor, and has not
/// landed yet; every panel that would otherwise show a viewport needs to know
/// not to try. One flag rather than each place spelling out the check for
/// itself, so the day the port reaches a second platform there is exactly one
/// line to change.
bool get rendererAvailable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// What to say instead of a viewport, while [rendererAvailable] is false.
///
/// Deliberately not phrased as a failure — nothing is broken, the port simply
/// has not reached this platform yet — because a placeholder that reads like
/// an error is the kind of thing somebody screenshots and files a bug about.
const String rendererUnavailableMessage =
    'The 3D viewport is not available on this platform yet.';
