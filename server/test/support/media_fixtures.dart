import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'sharing_fixtures.dart';

CompanionPhotoUpload mediaUpload(
  String group,
  String? grant, {
  String? operation,
  List<int>? bytes,
}) => CompanionPhotoUpload.fromJson({
  'protocol': companionProtocol,
  'operation_id': operation ?? sharingId(),
  'group_id': group,
  'purpose': grant == null ? 'chat' : 'record',
  'grant_id': grant,
  'jpeg_base64': base64Encode(
    bytes ?? img.encodeJpg(img.Image(width: 12, height: 8)),
  ),
});

CompanionPhotoRequest mediaRequest(
  String group,
  String photo, {
  String? operation,
}) => CompanionPhotoRequest.fromJson({
  'protocol': companionProtocol,
  'group_id': group,
  'photo_id': photo,
  'operation_id': ?operation,
}, remove: operation != null);

class ControlledObjects implements ObjectStore {
  ControlledObjects(this.delegate);
  final ObjectStore delegate;
  Future<void> Function(String)? beforePut;
  Future<void> Function(String)? afterRead;
  Future<void> Function(String)? afterDelete;
  bool failDelete = false;
  bool failPut = false;
  @override
  Future<void> put(String key, Uint8List bytes) async {
    await beforePut?.call(key);
    if (failPut) throw const ObjectStoreFailure('test_write_failure');
    await delegate.put(key, bytes);
  }

  @override
  Future<Uint8List?> read(String key) async {
    final bytes = await delegate.read(key);
    await afterRead?.call(key);
    return bytes;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw const ObjectStoreFailure('test_delete_failure');
    await delegate.delete(key);
    await afterDelete?.call(key);
  }

  @override
  Future<List<String>> keys({bool includePending = false}) =>
      delegate.keys(includePending: includePending);
}
