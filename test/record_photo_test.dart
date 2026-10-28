import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'EXIF orientation is baked into pixels before metadata removal',
    () async {
      final source = img.Image(width: 24, height: 12);
      source.exif.imageIfd.orientation = 6;
      final result = await sanitizeRecordPhoto(img.encodeJpg(source));
      expect([result.width, result.height], [12, 24]);
      expect(img.decodeJpg(result.bytes)!.exif.isEmpty, isTrue);
    },
  );
  test(
    'JPEG metadata including GPS is removed and pixels remain readable',
    () async {
      final source = img.Image(width: 24, height: 12);
      img.fill(source, color: img.ColorRgb8(220, 30, 40));
      source.exif.gpsIfd
        ..gpsLatitude = 12.34
        ..gpsLatitudeRef = 'N'
        ..gpsLongitude = 56.78
        ..gpsLongitudeRef = 'E';
      source.exif.imageIfd.imageDescription = 'SYNTHETIC PRIVATE METADATA';
      final original = img.encodeJpg(source);
      expect(img.decodeJpg(original)!.exif.gpsIfd.hasGPSLatitude, isTrue);
      final result = await sanitizeRecordPhoto(original);
      final decoded = img.decodeJpg(result.bytes)!;
      expect(decoded.width, 24);
      expect(decoded.height, 12);
      expect(decoded.exif.isEmpty, isTrue);
      expect(
        String.fromCharCodes(result.bytes),
        isNot(contains('SYNTHETIC PRIVATE METADATA')),
      );
      expect(decoded.getPixel(3, 3).r, greaterThan(200));
      expect(result.sha256, sha256.convert(result.bytes).toString());
    },
  );

  test('long edge is at most 1600 and small photos are not upscaled', () async {
    final source = img.Image(width: 2400, height: 1200);
    final result = await sanitizeRecordPhoto(img.encodePng(source));
    expect(result.width, 1600);
    expect(result.height, 800);
    expect(result.bytes.take(2), [0xff, 0xd8]);
    expect(result.bytes.length, lessThanOrEqualTo(maxRecordPhotoBytes));
    final small = await sanitizeRecordPhoto(
      img.encodePng(img.Image(width: 12, height: 8)),
    );
    expect([small.width, small.height], [12, 8]);
  });

  test(
    'transparent PNG metadata is dropped and transparency flattens to white',
    () async {
      final source = img.Image(width: 16, height: 16, numChannels: 4);
      source.textData = {'Comment': 'SYNTHETIC PRIVATE TEXT'};
      final result = await sanitizeRecordPhoto(img.encodePng(source));
      final decoded = img.decodeJpg(result.bytes)!;
      final pixel = decoded.getPixel(4, 4);
      expect([pixel.r, pixel.g, pixel.b], everyElement(greaterThan(245)));
      expect(decoded.textData, anyOf(isNull, isEmpty));
      expect(
        String.fromCharCodes(result.bytes),
        isNot(contains('SYNTHETIC PRIVATE TEXT')),
      );
    },
  );

  test('high entropy image stays under upload size limit', () async {
    final random = Random(42);
    final pixels = Uint8List(1600 * 1600 * 3);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = random.nextInt(256);
    }
    final source = img.Image.fromBytes(
      width: 1600,
      height: 1600,
      bytes: pixels.buffer,
      numChannels: 3,
    );
    final result = await sanitizeRecordPhoto(img.encodePng(source));
    expect(result.bytes.length, lessThanOrEqualTo(maxRecordPhotoBytes));
    expect(img.decodeJpg(result.bytes), isNotNull);
  });

  test(
    'invalid, oversized input and truncated images fail explicitly',
    () async {
      await expectLater(
        sanitizeRecordPhoto(Uint8List(0)),
        throwsA(isA<RecordPhotoException>()),
      );
      await expectLater(
        sanitizeRecordPhoto(Uint8List(maxRecordPhotoInputBytes + 1)),
        throwsA(isA<RecordPhotoException>()),
      );
      await expectLater(
        sanitizeRecordPhoto(Uint8List.fromList([0xff, 0xd8, 0xff])),
        throwsA(isA<RecordPhotoException>()),
      );
    },
  );
}
