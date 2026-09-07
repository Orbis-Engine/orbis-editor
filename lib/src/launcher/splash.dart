import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/orbis_theme.dart';

/// The mark, held for a moment before the editor arrives.
///
/// The thing every engine does on the way in, and the reason is not vanity:
/// something has to be on screen while the window, the renderer and the
/// project list are all still starting, and a blank frame reads as an
/// application that failed to open.
///
/// What it is not is a fixed delay. It is shown until the work behind it is
/// done *or* a short minimum has passed, whichever is later — so on a fast
/// machine it is a beat rather than a wait, and it never adds time that was
/// not already being spent.
class OrbisSplash extends StatefulWidget {
  const OrbisSplash({
    super.key,
    required this.child,
    this.hold = const Duration(milliseconds: 1100),
    this.ready,
  });

  /// What is being waited for.
  final Widget child;

  /// The least time the mark stays up, once it has faded in.
  ///
  /// Long enough to be read and short enough not to be in the way. Unity's is
  /// about two seconds and is the part of Unity people mention.
  final Duration hold;

  /// Anything else that has to finish first. Null waits only for [hold].
  final Future<void>? ready;

  @override
  State<OrbisSplash> createState() => _OrbisSplashState();
}

class _OrbisSplashState extends State<OrbisSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 340),
    value: 0,
  );

  bool _done = false;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _run();
  }

  Future<void> _run() async {
    await Future.wait([
      Future<void>.delayed(widget.hold),
      if (widget.ready != null) widget.ready!.catchError((Object _) {}),
    ]);
    await _leave();
  }

  Future<void> _leave() async {
    if (_done || !mounted) return;
    _done = true;
    await _fade.reverse();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Gone entirely once it has faded, rather than kept at zero opacity: a
    // transparent thing over the editor still eats clicks, and an editor that
    // ignores the first click is worse than one that took a moment to open.
    if (_done && _fade.isDismissed) return widget.child;

    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned.fill(
          child: FadeTransition(
            opacity: _fade,
            child: _Mark(onSkip: _leave),
          ),
        ),
      ],
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.onSkip});

  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        onSkip();
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        // Dismissable, unlike the one everybody complains about. Somebody who
        // has seen it four hundred times should not have to see it again.
        onTap: onSkip,
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          color: OrbisColors.ground,
          child: Stack(
            children: [
              // A wash behind the mark, in the engine's own colour, so the
              // logo sits on something rather than floating on flat black.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.9,
                      colors: [Color(0x14E5893F), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  // Bounded rather than a fraction of the window: the mark
                  // has a size it looks right at, and a splash on a large
                  // display should not be a billboard.
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Padding(
                    padding: const EdgeInsets.all(Space.xxl),
                    child: Image.asset(
                      'assets/brand/orbis-logo-full.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      // If the asset is missing the editor should still open.
                      errorBuilder: (context, error, stack) => Text(
                        'ORBIS',
                        style: OrbisText.display,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: Space.xxl,
                child: Center(
                  child: Text(
                    'Engine 0.1.0 · pre-alpha',
                    style: OrbisText.caption.copyWith(fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
