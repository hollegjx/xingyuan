import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  Map<String, Object?> upload() => {
    'protocol': companionProtocol,
    'operation_id': id(1),
    'group_id': id(2),
    'purpose': 'record',
    'grant_id': id(3),
    'jpeg_base64': base64Encode([1, 2, 3]),
  };
  Map<String, Object?> metadata() => {
    'id': id(4),
    'group_id': id(2),
    'author_id': id(5),
    'purpose': 'record',
    'grant_id': id(3),
    'width': 12,
    'height': 8,
    'byte_count': 3,
    'sha256': 'a' * 64,
  };
  test(
    'upload roundtrips immutable canonical bytes and rejects private fields',
    () {
      final body = upload();
      final parsed = CompanionPhotoUpload.fromJson(body);
      expect(parsed.toJson(), body);
      expect(() => parsed.bytes[0] = 4, throwsUnsupportedError);
      for (final extra in [
        'owner_id',
        'member_id',
        'private_note',
        'path',
        'url',
      ]) {
        expect(
          () => CompanionPhotoUpload.fromJson({...body, extra: 'private'}),
          throwsFormatException,
        );
      }
      for (final invalid in [
        '',
        'AA==\n',
        'AB==',
        '%41%41==',
        base64Encode(Uint8List(companionPhotoByteLimit + 1)),
      ]) {
        expect(
          () =>
              CompanionPhotoUpload.fromJson({...body, 'jpeg_base64': invalid}),
          throwsFormatException,
        );
      }
      final maximal = {
        ...body,
        'jpeg_base64': base64Encode(Uint8List(companionPhotoByteLimit)),
      };
      expect(
        CompanionPhotoUpload.fromJson(
          decodeCompanionMediaJson(jsonEncode(maximal)),
        ).bytes.length,
        companionPhotoByteLimit,
      );
      expect(
        () => decodeCompanionMediaJson(' ' * (companionMediaBodyLimit + 1)),
        throwsFormatException,
      );
    },
  );
  test('record upload requires a grant and chat upload prohibits one', () {
    for (final changes in <Map<String, Object?>>[
      {'grant_id': null},
      {'purpose': 'chat'},
      {'purpose': 'unknown'},
      {'operation_id': 'private-text'},
    ]) {
      expect(
        () => CompanionPhotoUpload.fromJson({...upload(), ...changes}),
        throwsFormatException,
      );
    }
    expect(
      CompanionPhotoUpload.fromJson({
        ...upload(),
        'purpose': 'chat',
        'grant_id': null,
      }).purpose,
      CompanionPhotoPurpose.chat,
    );
  });
  test('metadata rejects dimensions size digest and ownership mismatches', () {
    for (final changes in <Map<String, Object?>>[
      {'width': 0},
      {'height': 1601},
      {'byte_count': companionPhotoByteLimit + 1},
      {'sha256': 'G' * 64},
      {'author_id': 'private'},
      {'url': 'https://invalid.example'},
    ]) {
      expect(
        () => CompanionPhotoMetadata.fromJson({...metadata(), ...changes}),
        throwsFormatException,
      );
    }
  });
  test('upload receipt is bound to operation group grant and purpose', () {
    final request = CompanionPhotoUpload.fromJson(upload());
    final body = {
      'protocol': companionProtocol,
      'operation_id': id(1),
      'photo': metadata(),
    };
    expect(
      CompanionPhotoReceipt.fromJson(body, request: request).toJson(),
      body,
    );
    expect(
      () => CompanionPhotoReceipt.fromJson({
        ...body,
        'operation_id': id(9),
      }, request: request),
      throwsFormatException,
    );
    for (final changes in <Map<String, Object?>>[
      {'group_id': id(9)},
      {'grant_id': id(9)},
      {'purpose': 'chat', 'grant_id': null},
    ]) {
      expect(
        () => CompanionPhotoReceipt.fromJson({
          ...body,
          'photo': {...metadata(), ...changes},
        }, request: request),
        throwsFormatException,
      );
    }
  });
  test('read and remove requests have distinct strict operation semantics', () {
    final body = {
      'protocol': companionProtocol,
      'group_id': id(2),
      'photo_id': id(4),
    };
    expect(CompanionPhotoRequest.fromJson(body).toJson(), body);
    expect(
      () => CompanionPhotoRequest.fromJson(body, remove: true),
      throwsFormatException,
    );
    final remove = {...body, 'operation_id': id(1)};
    expect(
      CompanionPhotoRequest.fromJson(remove, remove: true).toJson(),
      remove,
    );
    expect(() => CompanionPhotoRequest.fromJson(remove), throwsFormatException);
  });
  test('download validates requested photo group and exact byte count', () {
    final request = CompanionPhotoRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': id(2),
      'photo_id': id(4),
    });
    final body = {
      'protocol': companionProtocol,
      'photo': metadata(),
      'jpeg_base64': base64Encode([1, 2, 3]),
    };
    expect(
      CompanionPhotoDownload.fromJson(body, request: request).toJson(),
      body,
    );
    for (final changes in <Map<String, Object?>>[
      {'id': id(9)},
      {'group_id': id(9)},
      {'byte_count': 2},
    ]) {
      expect(
        () => CompanionPhotoDownload.fromJson({
          ...body,
          'photo': {...metadata(), ...changes},
        }, request: request),
        throwsFormatException,
      );
    }
  });
}
