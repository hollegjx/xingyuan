import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// The four-point 星愿 sparkle, drawn in a 24×24 design box.
Path sparklePath(Rect bounds) {
  final scale = bounds.shortestSide / 24;
  final dx = bounds.left + (bounds.width - 24 * scale) / 2;
  final dy = bounds.top + (bounds.height - 24 * scale) / 2;
  Offset p(double x, double y) => Offset(dx + x * scale, dy + y * scale);
  final a = p(12, 2.5), b = p(21.5, 12), c = p(12, 21.5), d = p(2.5, 12);
  final path = Path()..moveTo(a.dx, a.dy);
  void curve(double x1, double y1, double x2, double y2, Offset to) {
    final c1 = p(x1, y1), c2 = p(x2, y2);
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  }

  curve(12.9, 7.6, 16.4, 11.1, b);
  curve(16.4, 12.9, 12.9, 16.4, c);
  curve(11.1, 16.4, 7.6, 12.9, d);
  curve(7.6, 11.1, 11.1, 7.6, a);
  return path..close();
}

class _SparklePainter extends CustomPainter {
  const _SparklePainter({
    required this.fill,
    required this.stroke,
    required this.glow,
  });

  final Color? fill;
  final Color? stroke;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = sparklePath(Offset.zero & size);
    if (fill case final color? when glow > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.55 * glow)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            size.shortestSide * 0.18,
          ),
      );
    }
    if (fill case final color?) {
      canvas.drawPath(path, Paint()..color = color);
    }
    if (stroke case final color?) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(1.4, size.shortestSide / 16),
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) =>
      old.fill != fill || old.stroke != stroke || old.glow != glow;
}

/// A static star: gold when lit, an outline when waiting.
class StarMark extends StatelessWidget {
  const StarMark({
    required this.lit,
    this.size = 24,
    this.color,
    this.outline,
    this.glow = true,
    super.key,
  });

  final bool lit;
  final double size;
  final Color? color;
  final Color? outline;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SparklePainter(
          fill: lit ? (color ?? xy.star) : null,
          stroke: lit ? null : (outline ?? xy.muted),
          glow: lit && glow ? 1 : 0,
        ),
      ),
    );
  }
}

/// The check-in control: tap the star to light it, tap again to undo.
class StarCheckButton extends StatefulWidget {
  const StarCheckButton({
    required this.lit,
    required this.onPressed,
    this.busy = false,
    this.size = 30,
    super.key,
  });

  final bool lit;
  final bool busy;
  final double size;
  final VoidCallback? onPressed;

  @override
  State<StarCheckButton> createState() => _StarCheckButtonState();
}

class _StarCheckButtonState extends State<StarCheckButton>
    with SingleTickerProviderStateMixin {
  late final _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.28,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.28,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 60,
    ),
  ]).animate(_pop);

  @override
  void didUpdateWidget(StarCheckButton old) {
    super.didUpdateWidget(old);
    if (!old.lit && widget.lit && !MediaQuery.disableAnimationsOf(context)) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  bool _pressed = false;

  void _tap() {
    if (!widget.lit) HapticFeedback.lightImpact().ignore();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final enabled = widget.onPressed != null && !widget.busy;
    final label = widget.lit ? '撤销打卡' : '打卡';
    return Semantics(
      button: true,
      enabled: enabled,
      checked: widget.lit,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: enabled ? _tap : null,
          onHighlightChanged: (value) => setState(() => _pressed = value),
          highlightColor: Colors.transparent,
          radius: 26,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: widget.busy
                  ? Theme.of(context).platform == TargetPlatform.iOS
                        ? const CupertinoActivityIndicator(radius: 9)
                        : SizedBox.square(
                            dimension: widget.size * 0.6,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: xy.muted,
                            ),
                          )
                  : AnimatedScale(
                      scale: _pressed ? 0.86 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: ScaleTransition(
                        scale: _scale,
                        child: StarMark(
                          lit: widget.lit,
                          size: widget.size,
                          outline: enabled
                              ? Theme.of(context).colorScheme.primary
                              : xy.faint,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of small stars showing how much of today is lit.
class StarProgress extends StatelessWidget {
  const StarProgress({
    required this.lit,
    required this.total,
    this.size = 14,
    this.maxStars = 10,
    this.outline,
    super.key,
  });

  final int lit;
  final int total;
  final double size;
  final int maxStars;
  final Color? outline;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();
    final shown = math.min(total, maxStars);
    final litShown = total <= maxStars ? lit : (lit * maxStars / total).round();
    return ExcludeSemantics(
      child: Wrap(
        spacing: size * 0.35,
        children: [
          for (var i = 0; i < shown; i++)
            StarMark(
              lit: i < litShown,
              size: size,
              outline: outline,
              glow: false,
            ),
        ],
      ),
    );
  }
}
