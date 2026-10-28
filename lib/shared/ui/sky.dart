import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

class _StarFieldPainter extends CustomPainter {
  const _StarFieldPainter({
    required this.seed,
    required this.dim,
    required this.bright,
    required this.gold,
  });

  final int seed;
  final Color dim;
  final Color bright;
  final Color gold;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final count = (size.width * size.height / 2600).clamp(12, 70).round();
    for (var i = 0; i < count; i++) {
      final at = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final roll = random.nextDouble();
      final radius = roll > 0.92 ? 1.5 : (roll > 0.6 ? 1.0 : 0.7);
      final color = roll > 0.97 ? gold : (roll > 0.6 ? bright : dim);
      canvas.drawCircle(at, radius, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_StarFieldPainter old) =>
      old.seed != seed ||
      old.dim != dim ||
      old.bright != bright ||
      old.gold != gold;
}

/// A night-sky band. Text on it should use [XyColors.onSky].
class SkyPanel extends StatelessWidget {
  const SkyPanel({
    required this.child,
    this.seed = 7,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 20, 24),
    this.radius = const BorderRadius.vertical(bottom: Radius.circular(28)),
    super.key,
  });

  final Widget child;
  final int seed;
  final EdgeInsetsGeometry padding;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [xy.skyDeep, xy.sky],
          ),
        ),
        child: CustomPaint(
          painter: _StarFieldPainter(
            seed: seed,
            dim: xy.onSkyMuted.withValues(alpha: 0.35),
            bright: xy.onSky.withValues(alpha: 0.7),
            gold: xy.star,
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: xy.onSky),
            child: IconTheme.merge(
              data: IconThemeData(color: xy.onSky),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// A translucent pill button for use on a [SkyPanel].
class SkyPill extends StatelessWidget {
  const SkyPill({
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.tooltip,
    this.emphasis = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? leading;
  final String? tooltip;

  /// Filled with the sky's light colour instead of a translucent wash.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final foreground = emphasis ? xy.sky : xy.onSky;
    final child = Material(
      color: emphasis ? xy.onSky : xy.onSky.withValues(alpha: 0.12),
      shape: StadiumBorder(
        side: emphasis
            ? BorderSide.none
            : BorderSide(color: xy.onSky.withValues(alpha: 0.22)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 8),
                ] else if (icon != null) ...[
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null
        ? child
        : Tooltip(message: tooltip, excludeFromSemantics: true, child: child);
  }
}
