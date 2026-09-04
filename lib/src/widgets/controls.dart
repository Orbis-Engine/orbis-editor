import 'package:flutter/material.dart';

import '../theme/orbis_theme.dart';

/// How much weight a button carries.
enum ButtonTone {
  /// The one thing this screen is for. At most one per view.
  primary,

  /// A real action, but not the point of the screen.
  normal,

  /// Available without asking to be noticed.
  quiet,
}

/// A button, sized and coloured for a tool rather than for a phone.
///
/// Material's defaults are built for touch: tall, rounded, with a ripple. An
/// editor is used with a mouse for hours, so these are shorter, squarer, and
/// respond by changing colour rather than by animating.
class OrbisButton extends StatefulWidget {
  const OrbisButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.tone = ButtonTone.normal,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ButtonTone tone;

  /// Fills its parent's width, for a stacked column of actions.
  final bool expand;

  @override
  State<OrbisButton> createState() => _OrbisButtonState();
}

class _OrbisButtonState extends State<OrbisButton> {
  bool _hovering = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  Color get _background {
    if (!_enabled) return OrbisColors.raised.withValues(alpha: 0.5);
    return switch (widget.tone) {
      ButtonTone.primary =>
        _pressed ? OrbisColors.emberDeep : OrbisColors.ember,
      ButtonTone.normal => _hovering ? OrbisColors.hover : OrbisColors.raised,
      ButtonTone.quiet =>
        _hovering ? OrbisColors.raised : Colors.transparent,
    };
  }

  Color get _foreground {
    if (!_enabled) return OrbisColors.inkDim;
    return switch (widget.tone) {
      // Near-black on ember rather than white: the accent is bright enough
      // that white text on it is the lower-contrast choice, not the higher.
      ButtonTone.primary => const Color(0xFF1A1206),
      ButtonTone.normal => OrbisColors.ink,
      ButtonTone.quiet => _hovering ? OrbisColors.ink : OrbisColors.inkMid,
    };
  }

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment:
          widget.expand ? MainAxisAlignment.start : MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 15, color: _foreground),
          const SizedBox(width: Space.sm),
        ],
        // Flexible when it fills its parent, since a label long enough to
        // overflow is a translation away rather than a hypothetical.
        if (widget.expand)
          Flexible(
            child: Text(
              widget.label,
              overflow: TextOverflow.ellipsis,
              style: OrbisText.label.copyWith(
                color: _foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          )
        else
          Text(
            widget.label,
            style: OrbisText.label.copyWith(
              color: _foreground,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );

    return MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          decoration: BoxDecoration(
            color: _background,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(
              color: widget.tone == ButtonTone.primary
                  ? Colors.transparent
                  : (_hovering && _enabled
                      ? OrbisColors.line
                      : OrbisColors.lineSoft),
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// A titled region.
class OrbisPanel extends StatelessWidget {
  const OrbisPanel({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(Space.lg),
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrbisColors.surface,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: OrbisColors.lineSoft),
                ),
              ),
              child: Row(
                children: [
                  Text(title!.toUpperCase(), style: OrbisText.section),
                  const Spacer(),
                  ?trailing,
                ],
              ),
            ),
          Flexible(child: Padding(padding: padding, child: child)),
        ],
      ),
    );
  }
}

/// A single-line text input.
class OrbisField extends StatelessWidget {
  const OrbisField({
    super.key,
    required this.controller,
    this.hint,
    this.mono = false,
    this.autofocus = false,
    this.onSubmitted,
    this.suffix,
  });

  final TextEditingController controller;
  final String? hint;

  /// For paths and identifiers, where proportional spacing costs more than it
  /// gives.
  final bool mono;

  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? OrbisText.monoValue
        : OrbisText.body.copyWith(color: OrbisColors.ink, fontSize: 13);

    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: OrbisColors.ground,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: OrbisColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              onSubmitted: onSubmitted,
              style: style,
              cursorColor: OrbisColors.ember,
              cursorWidth: 1.5,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.sm,
                ),
                hintText: hint,
                hintStyle: style.copyWith(color: OrbisColors.inkDim),
              ),
            ),
          ),
          if (suffix != null)
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: suffix,
            ),
        ],
      ),
    );
  }
}

/// A heading inside a panel.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding});

  final String text;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(bottom: Space.sm),
      child: Text(text.toUpperCase(), style: OrbisText.section),
    );
  }
}

/// Asks for a single name, and returns it trimmed, or null if cancelled.
///
/// A widget rather than a controller made at the call site, because a
/// controller disposed as soon as `showDialog` returns is still being read by
/// the dialog's own exit animation — which throws, once, in a place that has
/// nothing to do with where it was created.
Future<String?> promptForName(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  String action = 'OK',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NamePrompt(
      title: title,
      initial: initial,
      hint: hint,
      action: action,
    ),
  );
}

class _NamePrompt extends StatefulWidget {
  const _NamePrompt({
    required this.title,
    required this.initial,
    required this.hint,
    required this.action,
  });

  final String title;
  final String initial;
  final String? hint;
  final String action;

  @override
  State<_NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<_NamePrompt> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _accept() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OrbisColors.surface,
      title: Text(widget.title, style: OrbisText.title),
      content: SizedBox(
        // Bounded on both axes: an AlertDialog gives its content whatever room
        // it asks for, and a Column that asks for infinity gets it.
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              style: OrbisText.body,
              cursorColor: OrbisColors.ember,
              onSubmitted: (_) => _accept(),
            ),
            if (widget.hint != null) ...[
              const SizedBox(height: Space.sm),
              Text(widget.hint!, style: OrbisText.caption),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _accept, child: Text(widget.action)),
      ],
    );
  }
}
