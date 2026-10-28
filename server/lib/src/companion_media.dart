import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'companion_photo.dart';
import 'companion_store.dart';
import 'object_store.dart';

class CompanionMedia {
  CompanionMedia(this.store, this.objects);
  final CompanionStore store;
  final ObjectStore objects;
  final Set<String> _uploads = {};

  Future<CompanionPhotoReceipt> upload(
    String device,
    CompanionPhotoUpload request,
    Future<void> Function() authenticate,
  ) async {
    final key = '$device/${request.operationId}';
    if (!_uploads.add(key)) {
      throw const CompanionFailure(409, 'upload_in_progress');
    }
    CompanionPhotoReservation? reservation;
    try {
      reservation = store.reservePhoto(device, request);
      CompanionPhotoMetadata photo;
      if (reservation.ready case final ready?) {
        final bytes = await objects.read(ready.id);
        if (bytes == null ||
            bytes.length != ready.byteCount ||
            sha256.convert(bytes).toString() != ready.sha256) {
          throw const ObjectStoreFailure('photo_integrity');
        }
        await authenticate();
        photo = store.reservePhoto(device, request).ready!;
      } else {
        final clean = await sanitizeCompanionPhoto(request.bytes);
        await authenticate();
        store.reservePhoto(device, request);
        await objects.put(reservation.photoId, clean.bytes);
        await authenticate();
        photo = store.finishPhoto(device, reservation, clean);
      }
      return CompanionPhotoReceipt.fromJson({
        'protocol': companionProtocol,
        'operation_id': request.operationId,
        'photo': photo.toJson(),
      }, request: request);
    } on CompanionPhotoFailure catch (error) {
      final failure = CompanionFailure(400, error.code);
      if (reservation != null) {
        store.abortPhoto(reservation, failure);
        await store.drainPhotoDeletions(objects);
      }
      throw failure;
    } on CompanionFailure catch (error) {
      if (reservation != null) {
        store.abortPhoto(reservation, error);
        await store.drainPhotoDeletions(objects);
      }
      rethrow;
    } on ObjectStoreFailure {
      // Keep the reservation for same-ID recovery after transient disk errors.
      throw const CompanionFailure(503, 'photo_storage_unavailable');
    } finally {
      _uploads.remove(key);
    }
  }

  Future<CompanionPhotoDownload> download(
    String device,
    CompanionPhotoRequest request,
    Future<void> Function() authenticate,
  ) async {
    final photo = store.photoFor(device, request);
    final bytes = await objects.read(photo.id);
    await authenticate();
    final current = store.photoFor(device, request);
    if (bytes == null ||
        bytes.length != current.byteCount ||
        sha256.convert(bytes).toString() != current.sha256) {
      throw const CompanionFailure(503, 'photo_storage_unavailable');
    }
    return CompanionPhotoDownload.fromJson({
      'protocol': companionProtocol,
      'photo': current.toJson(),
      'jpeg_base64': base64Encode(bytes),
    }, request: request);
  }
}
