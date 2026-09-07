import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_examples/orbis_examples.dart';
import 'package:orbis_filament/orbis_filament.dart';

import '../theme/orbis_theme.dart';

/// The engine's worked examples, in the launcher.
///
/// The same examples the gallery app shows, from the same package — so an
/// example is written once and the two can never drift. What differs is only
/// the chrome around them: this one is dressed as the editor rather than as a
/// gallery, and sits beside the projects rather than in a window of its own.
///
/// Here rather than inside a project, because that is where the question gets
/// asked. "How is a day cycle done" comes up while somebody is deciding what
/// to build, and an answer they have to close their work to reach is an
/// answer they look up somewhere else instead.
class ExamplesView extends StatefulWidget {
  const ExamplesView({super.key});

  @override
  State<ExamplesView> createState() => _ExamplesViewState();
}

class _ExamplesViewState extends State<ExamplesView>
    with SingleTickerProviderStateMixin {
  late final List<Example> _examples = engineExamples();
  late Example _showing = _examples.first;
  late GalleryCamera _camera = GalleryCamera.from(_showing.viewpoint);

  Ticker? _clock;
  Duration _startedAt = Duration.zero;
  bool _restarting = true;
  double _seconds = 0;
  Offset? _dragging;

  @override
  void initState() {
    super.initState();
    _clock = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  /// One clock, and each example told how long *it* has been on screen.
  ///
  /// Not the wall time. A day cycle that began four minutes ago in another
  /// example is not a day cycle anybody asked to watch from the middle.
  void _tick(Duration elapsed) {
    if (_restarting) {
      _startedAt = elapsed;
      _restarting = false;
    }
    setState(() => _seconds = (elapsed - _startedAt).inMicroseconds / 1e6);
  }

  void _show(Example example) {
    setState(() {
      _showing = example;
      _camera = GalleryCamera.from(example.viewpoint);
      _restarting = true;
      _seconds = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final drawable =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _List(
          examples: _examples,
          showing: _showing,
          onShow: _show,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Title(example: _showing),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, Space.lg, Space.lg),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.panel),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: drawable
                              ? _stage()
                              : const _OnlyOnMac(),
                        ),
                        // Whatever an example draws over its scene, which for
                        // most of them is nothing.
                        if (_showing.overlay(context, _changed)
                            case final over?)
                          Positioned.fill(child: over),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _Panel(example: _showing, onChanged: _changed),
      ],
    );
  }

  void _changed() => setState(() {});

  Widget _stage() {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        setState(() => _camera.zoom(event.scrollDelta.dy));
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _dragging = details.localPosition,
        onPanUpdate: (details) {
          final from = _dragging;
          if (from == null) return;
          setState(() => _camera.orbit(details.localPosition - from));
          _dragging = details.localPosition;
        },
        onPanEnd: (_) => _dragging = null,
        child: OrbisView(
          scene: _showing.scene(_camera.toRenderCamera(), _seconds),
          onViewport: (id) {
            // The benchmark asks the renderer what a frame costs, and only
            // the view knows which viewport it is.
            final example = _showing;
            if (example is BenchmarkExample) example.watch(id);
          },
          onSceneNotes: (notes) {
            // One example has something to say about a file it could not
            // load; the rest have nothing to report and nowhere to put it.
            final example = _showing;
            if (example is MeshesExample && notes.isNotEmpty) {
              setState(() => example.note = notes.values.first);
            }
          },
        ),
      ),
    );
  }
}

/// The examples, down the left.
class _List extends StatelessWidget {
  const _List({
    required this.examples,
    required this.showing,
    required this.onShow,
  });

  final List<Example> examples;
  final Example showing;
  final ValueChanged<Example> onShow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      margin: const EdgeInsets.only(right: Space.lg, bottom: Space.lg),
      decoration: BoxDecoration(
        color: OrbisColors.surface,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        itemCount: examples.length,
        itemBuilder: (context, index) {
          final example = examples[index];
          return _Row(
            example: example,
            selected: identical(example, showing),
            onTap: () => onShow(example),
          );
        },
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.example,
    required this.selected,
    required this.onTap,
  });

  final Example example;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colour = widget.selected
        ? OrbisColors.ember
        : (_hovered ? OrbisColors.ink : OrbisColors.inkMid);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          margin: const EdgeInsets.symmetric(
            horizontal: Space.sm,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? OrbisColors.emberWash
                : (_hovered ? OrbisColors.raised : Colors.transparent),
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.example.name,
                style: OrbisText.body.copyWith(
                  color: colour,
                  fontWeight: widget.selected ? FontWeight.w600 : null,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.example.blurb,
                style: OrbisText.caption.copyWith(fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name and the one line about it, over the viewport.
class _Title extends StatelessWidget {
  const _Title({required this.example});

  final Example example;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, Space.xxl, Space.lg, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(example.name, style: OrbisText.title),
          const SizedBox(height: 2),
          Text(example.blurb, style: OrbisText.caption),
        ],
      ),
    );
  }
}

/// The settings and the lines that do it.
class _Panel extends StatelessWidget {
  const _Panel({required this.example, required this.onChanged});

  final Example example;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      margin: const EdgeInsets.only(bottom: Space.lg, right: Space.lg),
      decoration: BoxDecoration(
        color: OrbisColors.surface,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: OrbisColors.lineSoft),
      ),
      child: ListView(
        padding: const EdgeInsets.all(Space.md),
        children: [
          Text('SETTINGS', style: OrbisText.section),
          const SizedBox(height: Space.sm),
          example.settings(context, onChanged),
          const SizedBox(height: Space.xl),
          Text('HOW', style: OrbisText.section),
          const SizedBox(height: Space.sm),
          // The lines that matter, not the whole file. What an example is for
          // is the handful of statements that do the thing.
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: OrbisColors.ground,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: OrbisColors.lineSoft),
            ),
            child: SelectableText(
              example.code.trim(),
              style: OrbisText.mono.copyWith(
                fontSize: 11.5,
                height: 1.5,
                color: OrbisColors.inkMid,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What to say where the renderer cannot run.
class _OnlyOnMac extends StatelessWidget {
  const _OnlyOnMac();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: OrbisColors.ground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.desktop_access_disabled_outlined,
                  size: 26, color: OrbisColors.inkDim),
              const SizedBox(height: Space.md),
              Text(
                'The renderer draws on macOS only so far.\n'
                'The settings and the code are still here.',
                textAlign: TextAlign.center,
                style: OrbisText.caption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
