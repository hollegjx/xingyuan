import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  Map<String, Object?> requestBody() => {
    'protocol': companionProtocol,
    'group_id': id(1),
    'operation_id': id(2),
    'fingerprint': 'a' * 64,
  };
  PublicationResolveRequest request() =>
      PublicationResolveRequest.fromJson(requestBody());
  Map<String, Object?> receipt() => {
    'protocol': companionProtocol,
    'group_id': id(1),
    'operation_id': id(2),
    'resource_id': id(3),
    'revision': 2,
  };
  Map<String, Object?> response() => {
    ...requestBody(),
    'receipt': receipt(),
    'error_code': null,
  };
  PublicationResolution parse(Object? body) =>
      PublicationResolution.fromJson(body, request: request());
  SharingCommand command([Map<String, Object?> changes = const {}]) =>
      SharingCommand.fromJson(SharingCommandKind.publish, {
        'protocol': companionProtocol,
        'group_id': id(1),
        'operation_id': id(2),
        'grant_id': id(4),
        'source_id': id(5),
        'base_revision': 1,
        'title': 'Synthetic goal',
        'occurred_at': '2026-10-21T10:00:00.000Z',
        'completed_at': null,
        'share_details': true,
        'text': 'Synthetic withdrawn text',
        'photo_ids': <String>[],
        ...changes,
      });

  test(
    'resolution request contains only original identity and fingerprint',
    () {
      expect(request().toJson(), requestBody());
      for (final key in requestBody().keys) {
        expect(
          () => PublicationResolveRequest.fromJson(requestBody()..remove(key)),
          throwsFormatException,
        );
      }
      for (final key in [
        'text',
        'photo_ids',
        'member_id',
        'kind',
        'source_id',
      ]) {
        expect(
          () => PublicationResolveRequest.fromJson({
            ...requestBody(),
            key: 'secret',
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'resolution rejects invalid protocol IDs fingerprints and body size',
    () {
      final invalid = <String, List<Object?>>{
        'protocol': [null, assistantProtocol, 'v0'],
        'group_id': [
          null,
          'private text',
          id(1).toUpperCase().replaceFirst('4', 'Z'),
        ],
        'operation_id': [null, '', 'operation'],
        'fingerprint': [null, '', 'a' * 63, 'a' * 65, 'A' * 64, 'g' * 64, 123],
      };
      for (final entry in invalid.entries) {
        for (final value in entry.value) {
          expect(
            () => PublicationResolveRequest.fromJson({
              ...requestBody(),
              entry.key: value,
            }),
            throwsFormatException,
            reason: entry.key,
          );
        }
      }
      expect(
        () => PublicationResolveRequest.fromJson(null),
        throwsFormatException,
      );
      expect(
        () => PublicationResolveRequest.fromJson({
          ...requestBody(),
          'fingerprint': 'x' * (assistantBodyLimit + 1),
        }),
        throwsFormatException,
      );
    },
  );

  test('resolution roundtrips success and each definitive rejection', () {
    final resolved = parse(response());
    expect(resolved.toJson(), response());
    expect(resolved.receipt!.revision, 2);
    resolved.validateCommand(command());
    for (final code in publicationRejectionCodes) {
      final body = {...requestBody(), 'receipt': null, 'error_code': code};
      final rejected = parse(body);
      expect(rejected.toJson(), body);
      expect(rejected.receipt, isNull);
      rejected.validateCommand(command());
    }
  });

  test('resolution requires exact outer identity and one result', () {
    for (final entry in <String, Object?>{
      'protocol': assistantProtocol,
      'group_id': id(7),
      'operation_id': id(8),
      'fingerprint': 'b' * 64,
      'error_code': 'publication_cancelled',
    }.entries) {
      expect(
        () => parse({...response(), entry.key: entry.value}),
        throwsFormatException,
      );
    }
    for (final key in response().keys) {
      expect(() => parse(response()..remove(key)), throwsFormatException);
    }
    for (final code in [null, '', 'network', 'private-error', 409]) {
      expect(
        () => parse({...response(), 'receipt': null, 'error_code': code}),
        throwsFormatException,
      );
    }
    expect(
      () => parse({...response(), 'text': 'private'}),
      throwsFormatException,
    );
  });

  test('recovered receipt is strict and bound to the original publication', () {
    for (final entry in <String, Object?>{
      'protocol': assistantProtocol,
      'group_id': id(9),
      'operation_id': id(9),
      'resource_id': 'invalid',
      'revision': 0,
      'text': 'private',
    }.entries) {
      expect(
        () => parse({
          ...response(),
          'receipt': {...receipt(), entry.key: entry.value},
        }),
        throwsFormatException,
      );
    }
    for (final key in receipt().keys) {
      expect(
        () => parse({...response(), 'receipt': receipt()..remove(key)}),
        throwsFormatException,
      );
    }
    for (final revision in [-1, 1.5, '2', 9007199254740992]) {
      expect(
        () => parse({
          ...response(),
          'receipt': {...receipt(), 'revision': revision},
        }),
        throwsFormatException,
      );
    }
    final resolved = parse(response());
    for (final changes in [
      {'group_id': id(8)},
      {'operation_id': id(8)},
      {'base_revision': 0},
      {'base_revision': 2},
    ]) {
      expect(
        () => resolved.validateCommand(command(changes)),
        throwsFormatException,
      );
    }
    expect(
      () => resolved.validateCommand(
        SharingCommand.fromJson(SharingCommandKind.stop, {
          'protocol': companionProtocol,
          'group_id': id(1),
          'operation_id': id(2),
          'grant_id': id(4),
        }),
      ),
      throwsFormatException,
    );
  });

  test(
    'canonical fingerprint input preserves pre-resolution command encoding',
    () {
      final value = command();
      final expected = jsonEncode({'kind': 'publish', ...value.toJson()});
      expect(value.fingerprintInput, expected);
      final reordered = Map<String, Object?>.fromEntries(
        value.toJson().entries.toList().reversed,
      );
      expect(
        SharingCommand.fromJson(
          SharingCommandKind.publish,
          reordered,
        ).fingerprintInput,
        expected,
      );
      expect(command({'text': 'Changed'}).fingerprintInput, isNot(expected));
    },
  );
}
