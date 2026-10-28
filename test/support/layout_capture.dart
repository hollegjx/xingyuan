import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class LayoutCapture {
  static const enabled = bool.fromEnvironment('ASSISTANT_LAYOUT_CAPTURE');
  static const run = String.fromEnvironment('ASSISTANT_LAYOUT_RUN');
  static const source = String.fromEnvironment('ASSISTANT_LAYOUT_SOURCE');
  final key = GlobalKey();
  final _frames = <Map<String, Object>>[];
  final _passed = <double>[];
  Directory? _directory;

  Widget wrap(Widget child) => RepaintBoundary(key: key, child: child);

  Future<void> prepare() async {
    if (!enabled) {
      debugPrint(
        'LAYOUT_CAPTURE NOT RUN: native iOS renderer export is opt-in.',
      );
      return;
    }
    if (!Platform.isIOS ||
        !RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(source)) {
      throw StateError(
        'PNG export requires an iOS test simulator, fresh run ID and source SHA.',
      );
    }
    final directory = Directory(
      '${Directory.systemTemp.path}/xingyuan-layout-$run',
    );
    if (directory.existsSync()) throw StateError('Use a fresh layout run ID.');
    await directory.create(recursive: true);
    _directory = directory;
    await _report();
    debugPrint('LAYOUT_CAPTURE directory=${directory.path}');
  }

  Future<void> shot(WidgetTester tester, double scale, String name) async {
    expect(tester.takeException(), isNull);
    if (!enabled) return;
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    expect(boundary.debugNeedsPaint, isFalse);
    expect(boundary.size, const Size(320, 568));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        expect(image.width, 320);
        expect(image.height, 568);
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final colors = <int>{};
        for (var i = 0; i < pixels.length; i += 4) {
          colors.add((pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2]);
        }
        expect(
          colors.length,
          greaterThan(100),
          reason: 'Reject blank captures',
        );
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final filename = '${scale.toInt()}x-$name.png';
        final file = File('${_directory!.path}/$filename');
        expect(await file.exists(), isFalse);
        await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
        _frames.add({
          'file': filename,
          'width': image.width,
          'height': image.height,
          'text_scale': scale,
          'simulated_keyboard_inset': tester.view.viewInsets.bottom,
          'simulated_safe_area_top': tester.view.padding.top,
          'simulated_safe_area_bottom': tester.view.padding.bottom,
          'rgb_colors': colors.length,
        });
        await _report();
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> passed(WidgetTester tester, double scale) async {
    _passed.add(scale);
    if (enabled) await tester.runAsync(_report);
  }

  Future<void> _report() async {
    await File('${_directory!.path}/report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'run': run,
        'git_head_before_capture': source,
        'source': 'iOS simulator Flutter renderer; not an OS screenshot',
        'font': 'Native iOS fonts; unchanged production theme',
        'platform_layout': 'iOS',
        'synthetic_backend': true,
        'system_keyboard_rendered': false,
        'completed_workflow_scales': _passed,
        'success_requires_test_process_exit_zero': true,
        'frames': _frames,
      }),
      flush: true,
    );
  }
}
