import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:xingyuan_server/src/companion_photo.dart';
import 'package:xingyuan_server/src/object_store.dart';

void main() {
  Matcher failure(String code) =>
      isA<CompanionPhotoFailure>().having((e) => e.code, 'code', code);
  test('server JPEG sanitation drops GPS and private metadata and keeps visible pixels', () async {
    final source = img.Image(width: 24, height: 12);
    img.fill(source, color: img.ColorRgb8(220, 30, 40));
    source.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLatitudeRef = 'N'
      ..gpsLongitude = 56.78
      ..gpsLongitudeRef = 'E';
    source.exif.imageIfd
      ..imageDescription = 'SYNTHETIC PRIVATE EXIF'
      ..orientation = 6;
    final original = img.encodeJpg(source);
    expect(img.decodeJpg(original)!.exif.isEmpty, false);
    final result = await sanitizeCompanionPhoto(original);
    final decoded = img.decodeJpg(result.bytes)!;
    expect([result.width, result.height], [12, 24]);
    expect(decoded.exif.isEmpty, true);
    expect(decoded.iccProfile, isNull);
    expect(decoded.textData, anyOf(isNull, isEmpty));
    expect(decoded.getPixel(3, 3).r, greaterThan(200));
    expect(
      String.fromCharCodes(result.bytes),
      isNot(contains('SYNTHETIC PRIVATE EXIF')),
    );
    expect(result.sha256, sha256.convert(result.bytes).toString());
  });

  test('non JPEG truncated empty and oversized files are rejected', () async {
    final png = img.encodePng(img.Image(width: 12, height: 8));
    await expectLater(
      sanitizeCompanionPhoto(png),
      throwsA(failure('photo_format')),
    );
    await expectLater(
      sanitizeCompanionPhoto(Uint8List.fromList([0xff, 0xd8, 0xff])),
      throwsA(failure('photo_format')),
    );
    await expectLater(
      sanitizeCompanionPhoto(Uint8List(0)),
      throwsA(failure('photo_size')),
    );
    await expectLater(
      sanitizeCompanionPhoto(Uint8List(companionPhotoByteLimit + 1)),
      throwsA(failure('photo_size')),
    );
    final jpeg = img.encodeJpg(img.Image(width: 12, height: 8));
    await expectLater(
      sanitizeCompanionPhoto(jpeg.sublist(0, jpeg.length ~/ 2)),
      throwsA(failure('photo_format')),
    );
  });

  test('server rejects dimensions above 1600 rather than silently accepting arbitrary inputs', () async {
    for (final dimensions in [(1601, 1), (1, 1601), (1700, 1700)]) {
      final source = img.encodeJpg(
        img.Image(width: dimensions.$1, height: dimensions.$2),
      );
      await expectLater(
        sanitizeCompanionPhoto(source),
        throwsA(failure('photo_dimensions')),
      );
    }
    final small = await sanitizeCompanionPhoto(
      img.encodeJpg(img.Image(width: 12, height: 8)),
    );
    expect([small.width, small.height], [12, 8]);
  });

  test(
    'high entropy JPEG stays bounded and returned bytes are immutable',
    () async {
      final random = Random(13);
      final source = img.Image(width: 1600, height: 1600);
      for (final pixel in source) {
        pixel.setRgb(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
      final original = img.encodeJpg(source, quality: 40);
      expect(original.length, lessThanOrEqualTo(companionPhotoByteLimit));
      final result = await sanitizeCompanionPhoto(original);
      expect(result.bytes.length, lessThanOrEqualTo(companionPhotoByteLimit));
      expect([result.width, result.height], [1600, 1600]);
      expect(() => result.bytes[0] = 0, throwsUnsupportedError);
    },
  );
}
