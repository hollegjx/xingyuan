import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import 'sparkle.dart';

/// One entrance shown by [XyEntryBubbles].
class XyEntry {
  const XyEntry({
    required this.label,
    required this.tint,
    required this.onTap,
    this.icon,
    this.glyph,
    this.hint,
    this.key,
  }) : assert(icon != null || glyph != null);

  final String label;
  final Color tint;

  /// Null shows the bubble dimmed and ignores taps.
  final VoidCallback? onTap;

  /// Drawn in [tint] inside the bubble, unless [glyph] is given.
  final IconData? icon;
  final Widget? glyph;

  /// Read by VoiceOver after the label.
  final String? hint;

  /// Put on the tappable tile, so tests can tap it by key.
  final Key? key;
}

/// The four 今天 entrances: 打卡, 随手记, 写日记, 新目标.
List<XyEntry> todayEntries(
  BuildContext context, {
  required VoidCallback? onCheckIn,
  required VoidCallback? onQuickNote,
  required VoidCallback? onDiary,
  required VoidCallback? onNewGoal,
}) {
  // One accent for every entrance; only the star keeps its gold.
  final tint = Theme.of(context).colorScheme.primary;
  return [
    XyEntry(
      key: const ValueKey('entry-check-in'),
      label: '打卡',
      hint: '跳到今天的目标',
      tint: tint,
      glyph: const StarMark(lit: true, size: 24, glow: false),
      onTap: onCheckIn,
    ),
    XyEntry(
      key: const ValueKey('entry-quick-note'),
      label: '随手记',
      hint: '写一条随手记',
      tint: tint,
      icon: CupertinoIcons.square_pencil_fill,
      onTap: onQuickNote,
    ),
    XyEntry(
      key: const ValueKey('entry-diary'),
      label: '写日记',
      hint: '打开今天的日记',
      tint: tint,
      icon: CupertinoIcons.book_fill,
      onTap: onDiary,
    ),
    XyEntry(
      key: const ValueKey('entry-new-goal'),
      label: '新目标',
      hint: '新建一个目标',
      tint: tint,
      icon: CupertinoIcons.flag_fill,
      onTap: onNewGoal,
    ),
  ];
}

/// A row of round, softly tinted bubbles. Tapping one presses it in, springs
/// it back and scatters a few star motes around it.
///
/// At large text sizes the row becomes a two-column (or one-column) list of
/// tiles so labels never truncate.
class XyEntryBubbles extends StatelessWidget {
  const XyEntryBubbles({required this.entries, super.key});

  final List<XyEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (scale <= 1.35 && width / entries.length >= 72) {
          // One quiet card of shortcuts rather than a row of loud bubbles.
          return DecoratedBox(
            decoration: BoxDecoration(
              color: context.xy.card,
              borderRadius: BorderRadius.circular(xyCardRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in entries)
                    Expanded(
                      child: _EntryBubble(key: entry.key, entry: entry),
                    ),
                ],
              ),
            ),
          );
        }
        final tileWidth = 78 + 3.2 * 15 * scale;
        final columns = width >= tileWidth * 2 + 10 ? 2 : 1;
        final rows = <Widget>[];
        for (var i = 0; i < entries.length; i += columns) {
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: 10),
                  Expanded(
                    child: i + c < entries.length
                        ? _EntryBubble(
                            key: entries[i + c].key,
                            entry: entries[i + c],
                            tile: true,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

class _EntryBubble extends StatefulWidget {
  const _EntryBubble({required this.entry, this.tile = false, super.key});

  final XyEntry entry;

  /// Bubble and label side by side on a card, for large text.
  final bool tile;

  @override
  State<_EntryBubble> createState() => _EntryBubbleState();
}

class _EntryBubbleState extends State<_EntryBubble>
    with TickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);
  late final _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );

  bool get _enabled => widget.entry.onTap != null;

  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void dispose() {
    _scale.dispose();
    _burst.dispose();
    super.dispose();
  }

  void _down() {
    if (!_enabled || _still) return;
    _scale.animateTo(
      0.9,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
    );
  }

  void _up() {
    if (_still) return;
    _scale.animateTo(
      1,
      duration: const Duration(milliseconds: 560),
      curve: Curves.elasticOut,
    );
  }

  void _tap() {
    final onTap = widget.entry.onTap;
    if (onTap == null) return;
    HapticFeedback.lightImpact().ignore();
    if (!_still) _burst.forward(from: 0);
    _up();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final entry = widget.entry;
    final diameter = widget.tile ? 36.0 : 30.0;
    final bubble = ScaleTransition(
      scale: _scale,
      child: _Bubble(entry: entry, diameter: diameter),
    );
    final burst = Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _BurstPainter(
              progress: _burst,
              tint: entry.tint,
              star: xy.star,
              radius: diameter / 2,
            ),
          ),
        ),
      ),
    );
    final mark = SizedBox.square(
      dimension: diameter,
      child: Stack(clipBehavior: Clip.none, children: [bubble, burst]),
    );
    final label = Text(
      entry.label,
      textAlign: widget.tile ? TextAlign.start : TextAlign.center,
      style:
          (widget.tile ? theme.textTheme.bodyLarge : theme.textTheme.bodySmall)
              ?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
              ),
    );
    final Widget content = widget.tile
        ? Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            decoration: BoxDecoration(
              color: xy.card,
              borderRadius: BorderRadius.circular(xyCardRadius),
            ),
            child: Row(
              children: [
                mark,
                const SizedBox(width: 10),
                Expanded(child: label),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [mark, const SizedBox(height: 6), label],
            ),
          );
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _enabled,
        hint: entry.hint,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => _down() : null,
          onTapCancel: _enabled ? _up : null,
          onTap: _enabled ? _tap : null,
          child: AnimatedOpacity(
            opacity: _enabled ? 1 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The entry's mark: its icon in the entry tint, flat on the card.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.entry, required this.diameter});

  final XyEntry entry;
  final double diameter;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: diameter,
      child: Center(
        child: entry.glyph ?? Icon(entry.icon, size: 24, color: entry.tint),
      ),
    ),
  );
}

/// A ring that widens and fades, and eight motes — sparkles and dots —
/// drifting outward from the bubble's rim.
class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.progress,
    required this.tint,
    required this.star,
    required this.radius,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color tint;
  final Color star;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) return;
    final center = size.center(Offset.zero);
    final travel = Curves.easeOutCubic.transform(t);
    final fade = 1 - Curves.easeInQuad.transform(t);
    canvas.drawCircle(
      center,
      radius + 12 * travel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6 + 1.4 * fade
        ..color = tint.withValues(alpha: 0.4 * fade),
    );
    for (var i = 0; i < 8; i++) {
      final sparkle = i.isEven;
      final angle = -math.pi / 2 + i * math.pi / 4 + (sparkle ? 0.2 : -0.14);
      final reach = radius + 3 + (sparkle ? 20 : 13) * travel;
      final at = center + Offset(math.cos(angle), math.sin(angle)) * reach;
      final color = (i % 4 == 0 ? star : tint).withValues(alpha: fade);
      final side = (sparkle ? 8.0 : 4.0) * (1 - 0.45 * t);
      if (sparkle) {
        canvas.drawPath(
          sparklePath(Rect.fromCenter(center: at, width: side, height: side)),
          Paint()..color = color,
        );
      } else {
        canvas.drawCircle(at, side / 2, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.progress != progress ||
      old.tint != tint ||
      old.star != star ||
      old.radius != radius;
}
