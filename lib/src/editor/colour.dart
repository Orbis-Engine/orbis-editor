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

/// A colour from `#RRGGBB`, for the places a value arrives as text.
///
/// Data objects and prefabs write hex because a person reading the file should
/// see something they recognise, and a number is not that.
Color colourFromHex(String hex, {Color fallback = const Color(0xFFD9634F)}) {
  final digits = hex.startsWith('#') ? hex.substring(1) : hex;
  if (digits.length != 6 && digits.length != 8) return fallback;
  final value = int.tryParse(digits, radix: 16);
  if (value == null) return fallback;
  return Color(digits.length == 6 ? 0xFF000000 | value : value);
}

/// And back, in the same shape.
String hexFromColour(Color colour) {
  String pair(double channel) =>
      (channel * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${pair(colour.r)}${pair(colour.g)}${pair(colour.b)}'.toUpperCase();
}
