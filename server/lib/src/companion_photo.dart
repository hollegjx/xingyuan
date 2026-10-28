import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

import 'object_store.dart';

class CompanionPhotoFailure implements Exception {
  const CompanionPhotoFailure(this.code);
  final String code;
}

class SanitizedCompanionPhoto {
  SanitizedCompanionPhoto._(Uint8List bytes, this.width, this.height)
    : bytes = bytes.asUnmodifiableView(),
      sha256 = crypto.sha256.convert(bytes).toString();
  final Uint8List bytes;
  final int width;
  final int height;
  final String sha256;
}

Future<SanitizedCompanionPhoto> sanitizeCompanionPhoto(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > companionPhotoByteLimit) {
    return Future.error(const CompanionPhotoFailure('photo_size'));
  }
  // Copy before crossing the isolate boundary so caller mutation cannot change validation.
  final frozen = Uint8List.fromList(bytes);
  return Isolate.run(() => _sanitize(frozen));
}

SanitizedCompanionPhoto _sanitize(Uint8List bytes) {
  try {
    final decoder = img.JpegDecoder(maxPixels: 1600 * 1600);
    if (!decoder.isValidFile(bytes)) {
      throw const CompanionPhotoFailure('photo_format');
    }
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > 1600 ||
        info.height > 1600) {
      throw const CompanionPhotoFailure('photo_dimensions');
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) throw const CompanionPhotoFailure('photo_format');
    final oriented = img.bakeOrientation(decoded);
    final clean = img.Image(
      width: oriented.width,
      height: oriented.height,
      numChannels: 3,
    );
    img.compositeImage(clean, oriented);
    for (final quality in [85, 70, 55, 40, 25]) {
      final sanitized = img.encodeJpg(clean, quality: quality);
      if (sanitized.length <= companionPhotoByteLimit) {
        return SanitizedCompanionPhoto._(sanitized, clean.width, clean.height);
      }
    }
    throw const CompanionPhotoFailure('photo_size');
  } on CompanionPhotoFailure {
    rethrow;
  } catch (_) {
    // Decoder errors may contain input details and must never escape to logs.
    throw const CompanionPhotoFailure('photo_format');
  }
}
