import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

const maxRecordPhotoBytes = 2 * 1024 * 1024;
const maxRecordPhotoInputBytes = 20 * 1024 * 1024;
const _maxDecodedPixels = 16 * 1024 * 1024;

class RecordPhotoException implements Exception {
  const RecordPhotoException(this.message);
  final String message;
}

class SanitizedRecordPhoto {
  SanitizedRecordPhoto(Uint8List bytes, this.width, this.height)
    : bytes = bytes.asUnmodifiableView(),
      sha256 = crypto.sha256.convert(bytes).toString();

  final Uint8List bytes;
  final int width;
  final int height;
  final String sha256;
}

Future<SanitizedRecordPhoto> sanitizeRecordPhoto(Uint8List input) {
  if (input.isEmpty || input.length > maxRecordPhotoInputBytes) {
    return Future.error(const RecordPhotoException('照片过大或无法读取，请重新选择'));
  }
  return Isolate.run(() => _sanitize(input));
}

SanitizedRecordPhoto _sanitize(Uint8List input) {
  try {
    final decoders = <img.Decoder>[
      img.JpegDecoder(maxPixels: _maxDecodedPixels),
      img.PngDecoder(maxPixels: _maxDecodedPixels),
      img.GifDecoder()..maxPixels = _maxDecodedPixels,
      img.WebPDecoder()..maxPixels = _maxDecodedPixels,
    ];
    final decoder = decoders
        .where((decoder) => decoder.isValidFile(input))
        .firstOrNull;
    final info = decoder?.startDecode(input);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width * info.height > _maxDecodedPixels) {
      throw const RecordPhotoException('照片格式或尺寸不受支持，请重新选择');
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) throw const RecordPhotoException('照片无法解码，请重新选择');
    var oriented = img.bakeOrientation(decoded);
    if (oriented.width > 1600 || oriented.height > 1600) {
      final landscape = oriented.width >= oriented.height;
      oriented = img.copyResize(
        oriented,
        width: landscape ? 1600 : null,
        height: landscape ? null : 1600,
        interpolation: img.Interpolation.average,
      );
    }
    // Copy only pixels into a fresh image, never EXIF, GPS, text, ICC or frames.
    final clean = img.Image(
      width: oriented.width,
      height: oriented.height,
      numChannels: 3,
    );
    img.fill(clean, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(clean, oriented);
    for (final quality in [85, 70, 55, 40, 25]) {
      final bytes = img.encodeJpg(clean, quality: quality);
      if (bytes.length <= maxRecordPhotoBytes) {
        return SanitizedRecordPhoto(bytes, clean.width, clean.height);
      }
    }
    throw const RecordPhotoException('照片压缩后仍过大，请换一张照片');
  } on img.ImageException {
    throw const RecordPhotoException('照片无法解码，请重新选择');
  } on FormatException {
    throw const RecordPhotoException('照片无法解码，请重新选择');
  } on RangeError {
    throw const RecordPhotoException('照片文件不完整，请重新选择');
  }
}
