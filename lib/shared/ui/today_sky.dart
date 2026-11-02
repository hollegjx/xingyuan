import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'sparkle.dart';

/// The sky's mood for an hour of the day.
enum SkyMood { dawn, day, dusk, night }

SkyMood skyMoodFor(int hour) => switch (hour) {
  >= 5 && < 10 => SkyMood.dawn,
  >= 10 && < 16 => SkyMood.day,
  >= 16 && < 19 => SkyMood.dusk,
  _ => SkyMood.night,
};

/// Colours of one sky: the gradient, the words on it and its stars.
class SkyPalette {
  const SkyPalette({
    required this.top,
    required this.bottom,
    required this.text,
    required this.textMuted,
    required this.dust,
    required this.dustAlpha,
    required this.dustCount,
    required this.waiting,
    required this.night,
  });

  final Color top;
  final Color bottom;
  final Color text;
  final Color textMuted;

  /// Colour, strength and number of the small background stars.
  final Color dust;
  final double dustAlpha;
  final int dustCount;

  /// Outline of a goal's star that is not lit yet.
  final Color waiting;
  final bool night;

  static SkyPalette of(SkyMood mood, {required bool dark}) {
    const ink = Color(0xFF1E2925);
    const inkMuted = Color(0xFF55615C);
    const moon = Color(0xFFF2F1FA);
    const moonMuted = Color(0xFFB7B9DA);
    if (dark || mood == SkyMood.night) {
      return SkyPalette(
        top: dark ? const Color(0xFF0F1326) : const Color(0xFF1B2140),
        bottom: dark ? const Color(0xFF1C2346) : const Color(0xFF2E3766),
        text: moon,
        textMuted: moonMuted,
        dust: Colors.white,
        dustAlpha: 0.75,
        dustCount: 46,
        waiting: moonMuted.withValues(alpha: 0.7),
        night: true,
      );
    }
    return switch (mood) {
      SkyMood.dawn => const SkyPalette(
        top: Color(0xFFF6E4DA),
        bottom: Color(0xFFE6EEF0),
        text: ink,
        textMuted: inkMuted,
        dust: Color(0xFFC9A56A),
        dustAlpha: 0.45,
        dustCount: 14,
        waiting: Color(0xFF9AA59F),
        night: false,
      ),
      SkyMood.day => const SkyPalette(
        top: Color(0xFFE2EDF1),
        bottom: Color(0xFFF4F6F1),
        text: ink,
        textMuted: inkMuted,
        dust: Color(0xFFB9C7C9),
        dustAlpha: 0.55,
        dustCount: 10,
        waiting: Color(0xFF9AA59F),
        night: false,
      ),
      _ => const SkyPalette(
        top: Color(0xFFF1D6CD),
        bottom: Color(0xFFDCD9EE),
        text: ink,
        textMuted: inkMuted,
        dust: Color(0xFFFFFFFF),
        dustAlpha: 0.7,
        dustCount: 20,
        waiting: Color(0xFF8C8FA8),
        night: false,
      ),
    };
  }
}

/// 今天的星座: a small sky whose colour follows the hour. Every goal of the
/// day is a star; lit ones are joined into the day's constellation. When a
/// goal is finished its star lights with a soft burst and the line reaches
/// out to it.
///
/// The ambient twinkle plays for a few seconds when the sky appears and then
/// rests, so it never keeps the screen busy. Reduced motion shows it still.
class TodaySky extends StatefulWidget {
  const TodaySky({
    required this.done,
    required this.total,
    required this.hour,
    required this.seed,
    required this.builder,
    this.height = 176,
    super.key,
  });

  final int done;
  final int total;
  final int hour;
  final int seed;
  final double height;

  /// The words over the sky, given its palette.
  final Widget Function(BuildContext context, SkyPalette palette) builder;

  @override
  State<TodaySky> createState() => _TodaySkyState();
}

class _TodaySkyState extends State<TodaySky> with TickerProviderStateMixin {
  late final _twinkle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  late final _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    value: 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (!MediaQuery.disableAnimationsOf(context)) _twinkle.forward();
    }
  }

  @override
  void didUpdateWidget(TodaySky old) {
    super.didUpdateWidget(old);
    if (widget.done > old.done && !MediaQuery.disableAnimationsOf(context)) {
      _light.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _twinkle.dispose();
    _light.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      _twinkle.stop();
      _light.stop();
    }
    final palette = SkyPalette.of(skyMoodFor(widget.hour), dark: dark);
    final star = context.xy.star;
    // The words size the sky; it is at least [height] tall and grows with
    // large text, the stars keeping the band above the words.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.top, palette.bottom],
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.height),
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_twinkle, _light]),
                    builder: (context, _) => CustomPaint(
                      painter: _SkyPainter(
                        seed: widget.seed,
                        done: widget.done,
                        total: widget.total,
                        // Reduced motion, even when switched on mid-way,
                        // shows the settled sky at once.
                        twinkle: still ? 1 : _twinkle.value,
                        light: still ? 1 : _light.value,
                        palette: palette,
                        gold: star,
                        band: widget.height,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, widget.height * 0.5, 20, 16),
              child: Align(
                alignment: Alignment.bottomLeft,
                heightFactor: 1,
                child: widget.builder(context, palette),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter({
    required this.seed,
    required this.done,
    required this.total,
    required this.twinkle,
    required this.light,
    required this.palette,
    required this.gold,
    required this.band,
  });

  /// Height of the band the constellation lives in, from the top.
  final double band;
  final int seed;
  final int done;
  final int total;
  final double twinkle;
  final double light;
  final SkyPalette palette;
  final Color gold;

  /// Goal stars live in the upper part of the sky, clear of the words.
  List<Offset> _constellation(Size size) {
    // Every goal is a star, however many there are.
    final count = total;
    if (count == 0) return const [];
    final random = math.Random(seed * 7919 + count);
    // Spread across the sky above the words, each star nudged off a gentle
    // arc so the figure reads as a constellation rather than a chart.
    final left = size.width * (count < 3 ? 0.5 : 0.14);
    final right = size.width * 0.9;
    final points = <Offset>[];
    for (var i = 0; i < count; i++) {
      final f = count == 1 ? 0.5 : i / (count - 1);
      final jitter = (random.nextDouble() - 0.5) * (right - left) / count * 0.6;
      final x = left + (right - left) * f + jitter;
      final arc = math.sin(f * math.pi) * 0.14;
      final y = band * (0.38 - arc + (random.nextDouble() - 0.5) * 0.16);
      points.add(Offset(x, y));
    }
    return points;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    // Background dust: each speck breathes on its own phase while the
    // twinkle runs, then settles at its base brightness.
    final settle = twinkle >= 1 || twinkle == 0 ? 0.0 : 1.0;
    for (var i = 0; i < palette.dustCount; i++) {
      final at = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final phase = random.nextDouble() * math.pi * 2;
      final r = random.nextDouble();
      final radius = r > 0.9 ? 1.4 : (r > 0.55 ? 1.0 : 0.7);
      final breath =
          0.75 + 0.25 * math.sin(twinkle * math.pi * 6 + phase) * settle;
      canvas.drawCircle(
        at,
        radius,
        Paint()
          ..color = palette.dust.withValues(
            alpha: (palette.dustAlpha * (0.45 + 0.55 * r) * breath).clamp(0, 1),
          ),
      );
    }

    final points = _constellation(size);
    if (points.isEmpty) return;
    final lit = math.min(done, points.length);
    final newest = lit - 1;
    final reveal = Curves.easeOutCubic.transform(light);

    // The whole figure, faintly, so the day's shape is visible from the
    // start; lit segments are drawn over it in gold.
    final faint = Paint()
      ..color = palette.waiting.withValues(alpha: 0.28)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < points.length; i++) {
      canvas.drawLine(points[i - 1], points[i], faint);
    }
    final bright = Paint()
      ..color = gold.withValues(alpha: palette.night ? 0.75 : 0.7)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < lit; i++) {
      final from = points[i - 1];
      final to = points[i];
      final end = i == newest ? Offset.lerp(from, to, reveal)! : to;
      canvas.drawLine(from, end, bright);
    }

    for (var i = 0; i < points.length; i++) {
      final at = points[i];
      if (i < lit) {
        final grow = i == newest
            ? Curves.elasticOut.transform(light.clamp(0, 1))
            : 1.0;
        final size = (points.length > 9 ? 11.0 : 15.0) * (0.4 + 0.6 * grow);
        final pulse = i == newest ? (1 - light) : 0.0;
        canvas.drawCircle(
          at,
          size * (0.9 + pulse * 1.6),
          Paint()
            ..color = gold.withValues(alpha: 0.18 + 0.3 * pulse)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.7),
        );
        canvas.drawPath(
          sparklePath(Rect.fromCenter(center: at, width: size, height: size)),
          Paint()..color = gold,
        );
        if (pulse > 0) _burst(canvas, at, light);
      } else {
        canvas.drawPath(
          sparklePath(
            Rect.fromCenter(
              center: at,
              width: points.length > 9 ? 8 : 10,
              height: points.length > 9 ? 8 : 10,
            ),
          ),
          Paint()
            ..color = palette.waiting
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1,
        );
      }
    }
  }

  /// A ring of motes flung out from a star that has just been lit.
  void _burst(Canvas canvas, Offset at, double t) {
    final eased = Curves.easeOutCubic.transform(t);
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4 + 0.3;
      final distance = 8 + 22 * eased;
      final mote = at + Offset(math.cos(angle), math.sin(angle)) * distance;
      canvas.drawCircle(
        mote,
        1.6 * (1 - t) + 0.4,
        Paint()..color = gold.withValues(alpha: (1 - t).clamp(0, 1)),
      );
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.twinkle != twinkle ||
      old.light != light ||
      old.done != done ||
      old.total != total ||
      old.seed != seed ||
      old.palette != palette ||
      old.band != band ||
      old.gold != gold;
}

/// Fades and lifts its child in once, [order] steps after the page appears,
/// so a screen settles into place instead of popping in. Reduced motion shows
/// it at rest.
class RiseIn extends StatefulWidget {
  const RiseIn({required this.child, this.order = 0, super.key});

  final Widget child;
  final int order;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 420 + 70 * widget.order),
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      (70 * widget.order) / (420 + 70 * widget.order),
      1,
      curve: Curves.easeOutCubic,
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? widget.child
      : FadeTransition(
          opacity: _curve,
          child: AnimatedBuilder(
            animation: _curve,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, 14 * (1 - _curve.value)),
              child: child,
            ),
            child: widget.child,
          ),
        );
}

/// A small star rises from the bottom of the screen and fades into the sky:
/// a 随手记 or 日记 has been kept. It lives on the [overlay], so it keeps
/// rising after the editor closes. Reduced motion skips it.
void showWishRise(BuildContext context) {
  if (MediaQuery.disableAnimationsOf(context)) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final gold = context.xy.star;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _WishRise(color: gold, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _WishRise extends StatefulWidget {
  const _WishRise({required this.color, required this.onDone});

  final Color color;
  final VoidCallback onDone;

  @override
  State<_WishRise> createState() => _WishRiseState();
}

class _WishRiseState extends State<_WishRise>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final rise = Curves.easeOutCubic.transform(t);
          final size = MediaQuery.sizeOf(context);
          final fade = t < 0.15 ? t / 0.15 : (1 - (t - 0.15) / 0.85);
          // A slight drift sideways, like something carried on the air.
          final x = size.width / 2 + 18 * math.sin(t * math.pi * 1.5);
          final y = size.height * (0.82 - 0.62 * rise);
          final star = 18.0 * (1 - 0.45 * rise);
          return Stack(
            children: [
              Positioned(
                left: x - star,
                top: y - star,
                width: star * 2,
                height: star * 2,
                child: Opacity(
                  opacity: fade.clamp(0, 1),
                  child: CustomPaint(
                    painter: _GlowStarPainter(color: widget.color),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _GlowStarPainter extends CustomPainter {
  const _GlowStarPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width / 2,
      height: size.height / 2,
    );
    canvas.drawCircle(
      rect.center,
      size.width * 0.42,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.22),
    );
    canvas.drawPath(sparklePath(rect), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GlowStarPainter old) => old.color != color;
}
