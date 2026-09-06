import 'package:flutter/material.dart' show Color;
import 'package:orbis_light/orbis_light.dart' show Tint;

/// The boundary between a colour somebody picks and a colour the engine holds.
///
/// Everything below the editor states colour as a [Tint], which knows nothing
/// about Flutter — that is what lets weather, lighting and the rest run on a
/// front end that has no widgets in it. The editor is the one place that has
/// both, so the conversion lives here rather than being scattered through
/// every panel that shows a swatch.
extension TintColour on Tint {
  Color get colour => Color.fromARGB(
    255,
    (red * 255).round().clamp(0, 255),
    (green * 255).round().clamp(0, 255),
    (blue * 255).round().clamp(0, 255),
  );
}

extension ColourTint on Color {
  Tint get tint => Tint(r, g, b);
}
