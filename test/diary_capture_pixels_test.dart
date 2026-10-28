import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/diary_capture_pixels.dart';

const width = 100;
const height = 80;
const textRegion = Rect.fromLTWH(20, 30, 60, 20);

ByteData pixels(int Function(int x, int y) color) {
  final data = ByteData(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      data.setUint32((y * width + x) * 4, color(x, y));
    }
  }
  return data;
}

void verify(ByteData data, {List<Rect> regions = const [textRegion]}) =>
    verifyDiaryCapturePixels(
      data,
      width: width,
      height: height,
      textRegions: regions,
    );

ByteData twoColorText({bool dark = false}) => pixels((x, y) {
  final ink = y >= 33 && y < 47 && x >= 24 && x < 76 && x % 8 < 5;
  return ink != dark ? 0x202020ff : 0xf0f0f0ff;
});

void main() {
  for (final dark in [false, true]) {
    test('two-color text is nonblank, dark=$dark', () {
      expect(() => verify(twoColorText(dark: dark)), returnsNormally);
    });
    test('uniform page fails, dark=$dark', () {
      final data = pixels((x, y) => dark ? 0x202020ff : 0xf0f0f0ff);
      expect(() => verify(data), throwsA(isA<TestFailure>()));
    });
  }

  test('colorful decoration outside the text does not prove text painted', () {
    final data = pixels((x, y) => y < 20 ? (x << 24) | 0xff : 0xf0f0f0ff);
    expect(() => verify(data), throwsA(isA<TestFailure>()));
  });

  test('transparent colors do not prove visible text', () {
    final data = pixels((x, y) => (x << 24) | (y << 16));
    expect(() => verify(data), throwsA(isA<TestFailure>()));
  });

  test('a few stray pixels in an otherwise empty region fail', () {
    final data = pixels((x, y) {
      if (y < 20) return (x << 24) | 0xff;
      return x == 30 && y == 40 ? 0x202020ff : 0xf0f0f0ff;
    });
    expect(() => verify(data), throwsA(isA<TestFailure>()));
  });

  test('every required text region must contain painted text', () {
    expect(
      () => verify(
        twoColorText(),
        regions: [textRegion, const Rect.fromLTWH(0, 0, 10, 10)],
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  test('clipped text region fails', () {
    expect(
      () => verify(
        twoColorText(),
        regions: [const Rect.fromLTWH(-1, 30, 60, 20)],
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  test('no expected text regions fails', () {
    expect(
      () => verify(twoColorText(), regions: []),
      throwsA(isA<TestFailure>()),
    );
  });

  test('subpixel text region fails', () {
    expect(
      () => verify(
        twoColorText(),
        regions: [const Rect.fromLTWH(25, 35, .1, .1)],
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  test('truncated pixel buffer fails', () {
    expect(
      () => verify(ByteData(width * height * 4 - 4)),
      throwsA(isA<TestFailure>()),
    );
  });

  test('pixel view respects its byte offset', () {
    final original = twoColorText();
    final buffer = Uint8List(original.lengthInBytes + 8);
    buffer.setRange(4, buffer.length - 4, original.buffer.asUint8List());
    expect(
      () => verify(ByteData.sublistView(buffer, 4, buffer.length - 4)),
      returnsNormally,
    );
  });

  for (final painted in [true, false]) {
    testWidgets('widget text must actually paint, painted=$painted', (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.white,
              child: Center(
                child: Opacity(
                  opacity: painted ? 1 : 0,
                  child: const Text(
                    'Diary content',
                    style: TextStyle(color: Colors.black, fontSize: 20),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final text = find.text('Diary content');
      expect(text, findsOneWidget);
      final region = tester.getRect(text).inflate(1);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final data = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          return await image.toByteData(format: ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      expect(
        () => verifyDiaryCapturePixels(
          data!,
          width: 800,
          height: 600,
          textRegions: [region],
        ),
        painted ? returnsNormally : throwsA(isA<TestFailure>()),
      );
    });
  }
}
