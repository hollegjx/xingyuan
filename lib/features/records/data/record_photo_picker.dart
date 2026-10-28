import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'record_photo.dart';

enum RecordPhotoSource { camera, library }

class RecordPhotoPicker {
  Future<Uint8List?> pick(RecordPhotoSource source) async {
    try {
      final selected = await ImagePicker().pickImage(
        source: source == RecordPhotoSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (selected == null) return null;
      try {
        if (await selected.length() > maxRecordPhotoInputBytes) {
          throw const RecordPhotoException('照片过大，请重新选择');
        }
        return await selected.readAsBytes();
      } finally {
        // Only remove the plugin's app-temporary copy, never a library source.
        final temporary = await getTemporaryDirectory();
        if (p.isWithin(temporary.path, selected.path) ||
            p.isWithin(Directory.systemTemp.path, selected.path)) {
          final copy = File(selected.path);
          if (await copy.exists()) await copy.delete();
        }
      }
    } on PlatformException catch (error) {
      throw RecordPhotoException(switch (error.code) {
        'camera_access_denied' ||
        'camera_access_restricted' => '未获得相机权限，仍可写文字或从相册选照片',
        'photo_access_denied' ||
        'photo_access_restricted' => '未获得相册权限，仍可写文字或拍照',
        _ => '无法打开照片，请稍后重试',
      });
    }
  }
}
