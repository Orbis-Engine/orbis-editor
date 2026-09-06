import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/orbis_theme.dart';
import 'console.dart';

/// What the editor has said, in the order it said it.
///
/// A panel rather than a status bar, because the status bar is where a message
/// goes to be missed: it shows one line for four seconds, and the four seconds
/// somebody spends reading a compiler error are the four seconds it takes for
/// the next message to replace it.
class ConsolePanel extends StatefulWidget {
  const ConsolePanel({super.key, required this.log, this.height});

  final EditorLog log;
  /// How tall to be, or null to fill whatever it is put in.
  ///
  /// Null is the ordinary case now that panels are docked: a panel in a
  /// layout is given its space by the layout, and one that insisted on a
  /// height would fight whatever it was docked beside.
  final double? height;

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  /// Which levels are shown. All of them, until somebody says otherwise.
  final Set<LogLevel> _showing = {...LogLevel.values};

  /// The entry whose detail is open, by position from the end.
  ///
  /// From the end rather than the start, because entries fall off the top once
  /// there are five hundred of them and an index from the start would quietly
  /// start pointing at a different message.
  int? _opened;

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_changed);
  }

  @override
  void didUpdateWidget(ConsolePanel old) {
    super.didUpdateWidget(old);
    if (old.log != widget.log) {
      old.log.removeListener(_changed);
      widget.log.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.log.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final entry in widget.log.entries)
        if (_showing.contains(entry.level)) entry,
    ].reversed.toList();

    final panel = Container(
        decoration: const BoxDecoration(color: OrbisColors.surface),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        widget.log.entries.isEmpty
                            ? 'Nothing to report.'
                            : 'Nothing at these levels.',
                        style: OrbisText.caption,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: Space.xs),
                      itemCount: shown.length,
                      itemBuilder: (context, index) => _Row(
                        entry: shown[index],
                        open: _opened == index,
                        onTap: () => setState(
                          () => _opened = _opened == index ? null : index,
                        ),
                      ),
                    ),
            ),
          ],
        ),
    );

    return widget.height == null
        ? panel
        : SizedBox(height: widget.height, child: panel);
  }

  Widget _header() {
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OrbisColors.lineSoft)),
      ),
      child: Row(
        children: [
          for (final level in LogLevel.values) ...[
            _Filter(
              level: level,
              count: widget.log.countOf(level),
              on: _showing.contains(level),
              onTap: () => setState(() {
                if (!_showing.remove(level)) _showing.add(level);
              }),
            ),
            const SizedBox(width: Space.xs),
          ],
          const Spacer(),
          _Action(
            icon: Icons.content_copy,
            tooltip: 'Copy everything shown',
            onTap: () {
              final text = [
                for (final entry in widget.log.entries)
                  if (_showing.contains(entry.level))
                    '[${entry.level.name}] ${entry.message}'
                    '${entry.detail.isEmpty ? '' : '\n${entry.detail}'}',
              ].join('\n');
              Clipboard.setData(ClipboardData(text: text));
            },
          ),
          _Action(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Clear',
            onTap: widget.log.clear,
          ),
        ],
      ),
    );
  }
}

/// A level, with how many there are and whether it is being shown.
class _Filter extends StatelessWidget {
  const _Filter({
    required this.level,
    required this.count,
    required this.on,
    required this.onTap,
  });

  final LogLevel level;
  final int count;
  final bool on;
  final VoidCallback onTap;

  static Color colourOf(LogLevel level) => switch (level) {
        LogLevel.info => OrbisColors.inkMid,
        LogLevel.warning => OrbisColors.warn,
        LogLevel.error => OrbisColors.bad,
      };

  static IconData iconOf(LogLevel level) => switch (level) {
        LogLevel.info => Icons.info_outline,
        LogLevel.warning => Icons.warning_amber_outlined,
        LogLevel.error => Icons.error_outline,
      };

  @override
  Widget build(BuildContext context) {
    final colour = on ? colourOf(level) : OrbisColors.inkDim;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
          decoration: BoxDecoration(
            color: on ? OrbisColors.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(
              color: on ? OrbisColors.line : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconOf(level), size: 12, color: colour),
              const SizedBox(width: 5),
              Text(
                '${level.label} $count',
                style: OrbisText.caption.copyWith(fontSize: 11, color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.xs),
            child: Icon(icon, size: 14, color: OrbisColors.inkDim),
          ),
        ),
      ),
    );
  }
}

/// One line, with its detail folded under it.
class _Row extends StatefulWidget {
  const _Row({required this.entry, required this.open, required this.onTap});

  final LogEntry entry;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovering = false;

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colour = _Filter.colourOf(entry.level);
    final hasDetail = entry.detail.trim().isNotEmpty;

    return MouseRegion(
      cursor: hasDetail ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: hasDetail ? widget.onTap : null,
        child: Container(
          color: _hovering ? OrbisColors.raised : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: 3,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      hasDetail
                          ? (widget.open
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right)
                          : _Filter.iconOf(entry.level),
                      size: 13,
                      color: colour,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      entry.message,
                      style: OrbisText.body.copyWith(
                        fontSize: 12,
                        color: entry.level == LogLevel.info
                            ? OrbisColors.inkMid
                            : colour,
                      ),
                    ),
                  ),
                  // Said again rather than said twice.
                  if (entry.repeats > 1) ...[
                    const SizedBox(width: Space.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: OrbisColors.raised,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '×${entry.repeats}',
                        style: OrbisText.caption.copyWith(fontSize: 10),
                      ),
                    ),
                  ],
                  const SizedBox(width: Space.sm),
                  Text(
                    _clock(entry.at),
                    style: OrbisText.mono.copyWith(
                      fontSize: 10,
                      color: OrbisColors.inkDim,
                    ),
                  ),
                ],
              ),
              if (widget.open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(21, Space.xs, 0, Space.sm),
                  child: SelectableText(
                    entry.detail,
                    style: OrbisText.mono.copyWith(
                      fontSize: 11,
                      color: OrbisColors.inkMid,
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
