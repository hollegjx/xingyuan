import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

void verifyDiaryCapturePixels(
  ByteData rgba, {
  required int width,
  required int height,
  required List<Rect> textRegions,
}) {
  expect(width, greaterThan(0));
  expect(height, greaterThan(0));
  expect(rgba.lengthInBytes, width * height * 4);
  expect(textRegions, isNotEmpty, reason: 'Require visible text evidence');
  final pixels = rgba.buffer.asUint8List(
    rgba.offsetInBytes,
    rgba.lengthInBytes,
  );
  final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  for (final region in textRegions) {
    expect(region.isFinite && !region.isEmpty, isTrue);
    expect(
      region.intersect(bounds),
      region,
      reason: 'Text must not be clipped',
    );
    final colors = <int, int>{};
    var opaque = 0;
    final left = region.left.floor();
    final right = region.right.ceil();
    final top = region.top.floor();
    final bottom = region.bottom.ceil();
    final area = (right - left) * (bottom - top);
    expect(
      area,
      greaterThanOrEqualTo(4),
      reason: 'Require a usable text region',
    );
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final i = (y * width + x) * 4;
        if (pixels[i + 3] < 250) continue;
        opaque++;
        final rgb = (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
        colors.update(rgb, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    expect(
      opaque,
      greaterThanOrEqualTo((area * .95).ceil()),
      reason: 'Text region must be visibly opaque: $region',
    );
    final dominant = colors.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    var contrasting = 0;
    for (final color in colors.entries) {
      if ([0, 8, 16].any(
        (shift) =>
            (((color.key >> shift) & 255) - ((dominant >> shift) & 255))
                .abs() >=
            32,
      )) {
        contrasting += color.value;
      }
    }
    // Check ink versus background at known text, not antialias palette size.
    // Requiring area coverage rejects isolated specks in an empty region.
    expect(
      contrasting,
      greaterThanOrEqualTo((area * .01).ceil().clamp(4, area)),
      reason: 'Text region needs contrasting painted pixels: $region',
    );
  }
}
