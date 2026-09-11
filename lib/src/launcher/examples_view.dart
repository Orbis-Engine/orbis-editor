import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_examples/orbis_examples.dart';
import 'package:orbis_filament/orbis_filament.dart';

import '../platform/renderer_support.dart';
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
  const ExamplesView({super.key, this.onFull, this.examples});

  /// Told when the view wants the whole window, so whatever is around it can
  /// get out of the way.
  final ValueChanged<bool>? onFull;

  /// The examples to show, for a test that needs one in a known state.
  ///
  /// Null everywhere else, and then the view asks the package — which is the
  /// point of the list living there. A test that typed its own copy would
  /// pass for an example nobody can reach.
  @visibleForTesting
  final List<Example>? examples;

  @override
  State<ExamplesView> createState() => _ExamplesViewState();
}

class _ExamplesViewState extends State<ExamplesView>
    with SingleTickerProviderStateMixin {
  late final List<Example> _examples = widget.examples ?? engineExamples();
  late Example _showing = _examples.first;
  late GalleryCamera _camera = GalleryCamera.from(_showing.viewpoint);

  Ticker? _clock;
  Duration _startedAt = Duration.zero;
  bool _restarting = true;
  double _seconds = 0;
  Offset? _dragging;

  /// Which of the two side panels are open.
  ///
  /// An example is a scene to be looked at, and the list of the others and the
  /// page of settings are both in front of it. Shutting them is not a tidying
  /// preference — it is the difference between a picture with a window round
  /// it and the thing itself.
  bool _listing = true;
  bool _settings = true;

  /// Nothing but the scene, and the way back.
  ///
  /// The launcher's own rail goes as well, which is why this is reported
  /// outward rather than kept here: a full view with a navigation rail down
  /// the side of it is not a full view.
  bool _full = false;

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
    final drawable = rendererAvailable;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_listing && !_full)
          _List(
            examples: _examples,
            showing: _showing,
            onShow: _show,
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Title(
                example: _showing,
                full: _full,
                listing: _listing,
                settings: _settings,
                onFull: _setFull,
                onListing: (open) => setState(() => _listing = open),
                onSettings: (open) => setState(() => _settings = open),
              ),
              Expanded(
                child: Padding(
                  // Edge to edge when it is the only thing on screen. A
                  // margin and a rounded corner say "this is a panel among
                  // others", which is the opposite of what a full view means.
                  padding: _full
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(0, 0, Space.lg, Space.lg),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      _full ? 0 : Radii.panel,
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: drawable
                              ? _stage()
                              : const _RendererUnavailable(),
                        ),
                        // Whatever an example draws over its scene, which for
                        // most of them is nothing.
                        if (_showing.overlay(context, _changed)
                            case final over?)
                          Positioned.fill(child: over),
                        // What the renderer could not do, over the thing it
                        // could not do it to. In the corner rather than the
                        // middle: the scene is still worth looking at, and
                        // this is a footnote to it rather than a failure
                        // page in front of it.
                        if (_showing.note case final saying?)
                          Positioned(
                            left: Space.md,
                            bottom: Space.md,
                            right: Space.md,
                            child: _Note(
                              saying: saying,
                              needs: _showing.needs,
                              fetching: _fetching,
                              progress: _progress,
                              onFetch: _fetch,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_settings && !_full)
          _Panel(example: _showing, onChanged: _changed),
      ],
    );
  }

  void _setFull(bool full) {
    setState(() => _full = full);
    widget.onFull?.call(full);
  }

  void _changed() => setState(() {});

  /// Whether a download is running, and the last thing it said.
  bool _fetching = false;
  String _progress = '';

  /// Runs the command an example says will fetch what it is missing.
  ///
  /// The example describes; this decides. An example that ran a download
  /// itself would be one that cannot be shown on a machine where downloading
  /// is somebody else's call — and seven hundred megabytes is exactly the
  /// kind of thing somebody should be asked about rather than told.
  Future<void> _fetch(Downloadable needs) async {
    if (_fetching) return;
    setState(() {
      _fetching = true;
      _progress = 'starting';
    });

    try {
      // The engine repository, which is where the fetch scripts live and what
      // their paths are relative to. Beside this one, in the same way the
      // examples already find their assets.
      final root = Directory('${Directory.current.path}/../orbis');
      if (!root.existsSync()) {
        setState(() => _progress = 'no engine repository beside this one');
        return;
      }

      final running = await Process.start(
        needs.command.first,
        needs.command.skip(1).toList(),
        workingDirectory: root.path,
      );

      // Shown as it arrives rather than at the end. A download of this size
      // with no sign of life is one somebody kills.
      running.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        if (mounted && line.trim().isNotEmpty) {
          setState(() => _progress = line.trim());
        }
      });
      running.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        if (mounted && line.trim().isNotEmpty) {
          setState(() => _progress = line.trim());
        }
      });

      final code = await running.exitCode;
      if (!mounted) return;
      setState(() {
        _progress = code == 0 ? 'done' : 'the fetch failed ($code)';
        // Cleared so the scene is asked for again: the renderer remembers a
        // file it could not read, and the note goes when the file arrives.
        if (code == 0) _showing.note = null;
      });
    } on ProcessException catch (problem) {
      if (mounted) setState(() => _progress = problem.message);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

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
            // Any of them, not one of them. Whether the renderer has
            // something to say about a scene is not a property of which
            // example it is, and the example that never expected a note is
            // the one whose silence is least helpful — a Bistro whose files
            // were never downloaded drew a grey placeholder and explained
            // nothing.
            setState(() {
              _showing.note = notes.isEmpty ? null : notes.values.first;
            });
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
  const _Title({
    required this.example,
    required this.full,
    required this.listing,
    required this.settings,
    required this.onFull,
    required this.onListing,
    required this.onSettings,
  });

  final Example example;
  final bool full;
  final bool listing;
  final bool settings;
  final ValueChanged<bool> onFull;
  final ValueChanged<bool> onListing;
  final ValueChanged<bool> onSettings;

  @override
  Widget build(BuildContext context) {
    // Thin and dark when the scene has the window, so the row of controls
    // reads as a strip over the picture rather than as a page heading with a
    // picture under it.
    return Container(
      color: full ? OrbisColors.surface : null,
      padding: full
          ? const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.sm, Space.sm)
          : const EdgeInsets.fromLTRB(0, Space.xxl, Space.lg, Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (full) ...[
            // The way back, where a window puts it and where a project puts
            // it: top left, first thing, before what it is a view of.
            IconButton(
              iconSize: 18,
              tooltip: 'Back to the examples',
              onPressed: () => onFull(false),
              icon: const Icon(Icons.arrow_back, color: OrbisColors.ink),
            ),
            const SizedBox(width: Space.xs),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  example.name,
                  style: full ? OrbisText.label : OrbisText.title,
                ),
                if (!full) ...[
                  const SizedBox(height: 2),
                  Text(example.blurb, style: OrbisText.caption),
                ],
              ],
            ),
          ),
          if (!full) ...[
            _Sider(
              open: listing,
              tooltip: listing ? 'Hide the list' : 'Show the list',
              icon: Icons.view_sidebar_outlined,
              onTap: () => onListing(!listing),
            ),
            _Sider(
              open: settings,
              tooltip: settings ? 'Hide the settings' : 'Show the settings',
              // The same glyph turned over, because it is the same control
              // for the other side and two unrelated icons would suggest two
              // unrelated things.
              icon: Icons.view_sidebar_outlined,
              flipped: true,
              onTap: () => onSettings(!settings),
            ),
          ],
          _Sider(
            open: full,
            tooltip: full ? 'Leave the full view' : 'Fill the window',
            icon: full ? Icons.close_fullscreen : Icons.open_in_full,
            onTap: () => onFull(!full),
          ),
        ],
      ),
    );
  }
}

/// One of the little toggles along the title row.
class _Sider extends StatelessWidget {
  const _Sider({
    required this.open,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.flipped = false,
  });

  final bool open;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool flipped;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      icon,
      size: 17,
      color: open ? OrbisColors.ink : OrbisColors.inkDim,
    );

    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      icon: flipped
          ? Transform.flip(flipX: true, child: glyph)
          : glyph,
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
class _RendererUnavailable extends StatelessWidget {
  const _RendererUnavailable();

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
                '$rendererUnavailableMessage\n'
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

/// Something the renderer could not do, said over the scene.
class _Note extends StatelessWidget {
  const _Note({
    required this.saying,
    required this.needs,
    required this.fetching,
    required this.progress,
    required this.onFetch,
  });

  final String saying;
  final Downloadable? needs;
  final bool fetching;
  final String progress;
  final ValueChanged<Downloadable> onFetch;

  @override
  Widget build(BuildContext context) {
    final wanted = needs;

    return Align(
      alignment: Alignment.bottomLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        decoration: BoxDecoration(
          color: const Color(0xE0161A21),
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: OrbisColors.ember.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 15,
                  color: OrbisColors.ember,
                ),
                const SizedBox(width: Space.sm),
                Flexible(
                  child: Text(
                    saying,
                    style: OrbisText.body.copyWith(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (wanted != null) ...[
              const SizedBox(height: Space.sm),
              // What it is and what it costs, before the button rather than
              // after it. A download button that does not say what it fetches,
              // how big it is, or whose it is, is one nobody should press.
              Text(
                '${wanted.what} — ${wanted.size}\n'
                '${wanted.from} · ${wanted.licence}',
                style: OrbisText.caption.copyWith(fontSize: 11, height: 1.4),
              ),
              const SizedBox(height: Space.sm),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed: fetching ? null : () => onFetch(wanted),
                    icon: Icon(
                      fetching ? Icons.hourglass_top : Icons.download,
                      size: 16,
                    ),
                    label: Text(fetching ? 'Fetching' : 'Download'),
                  ),
                  if (progress.isNotEmpty) ...[
                    const SizedBox(width: Space.md),
                    Flexible(
                      child: Text(
                        progress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OrbisText.caption.copyWith(fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
