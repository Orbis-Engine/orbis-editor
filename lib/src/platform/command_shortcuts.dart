import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the platform's "Command" modifier is macOS's Meta (⌘) key.
///
/// False means Control: Windows and Linux both bind what macOS puts on
/// Command to Control instead, and there is no supported platform where the
/// answer is anything else.
bool get commandIsMeta => defaultTargetPlatform == TargetPlatform.macOS;

/// The label for the platform's Command modifier, for menus and tooltips —
/// the ⌘ glyph on macOS, "Ctrl" everywhere else.
String get commandKeyLabel => commandIsMeta ? '⌘' : 'Ctrl';

/// A keyboard shortcut on the platform's Command modifier — Meta on macOS,
/// Control everywhere else — with whichever of [shift] and [alt] are asked
/// for besides.
///
/// The one place that decides what "Command" means on this platform, so
/// nothing else needs to change when another platform joins macOS, Windows
/// and Linux.
SingleActivator commandShortcut(
  LogicalKeyboardKey trigger, {
  bool shift = false,
  bool alt = false,
}) {
  return SingleActivator(
    trigger,
    meta: commandIsMeta,
    control: !commandIsMeta,
    shift: shift,
    alt: alt,
  );
}

/// The text for a Command-modified shortcut, matched to what
/// [commandShortcut] actually binds — "⇧⌘S" on macOS (Apple's own ordering:
/// Shift immediately before Command), "Ctrl+Shift+S" elsewhere.
String commandShortcutLabel(String key, {bool shift = false}) {
  if (commandIsMeta) return '${shift ? '⇧' : ''}$commandKeyLabel$key';
  return '$commandKeyLabel+${shift ? 'Shift+' : ''}$key';
}

/// Whether the platform's Command modifier is held right now.
///
/// For the places that read the keyboard directly — a click that adds to the
/// selection rather than replacing it — instead of going through a
/// [SingleActivator]. Command/Shift-click on macOS is Ctrl/Shift-click
/// everywhere else, on the same reasoning as [commandShortcut].
bool get isCommandModifierPressed => commandIsMeta
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;
