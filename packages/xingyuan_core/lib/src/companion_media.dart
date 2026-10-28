part of 'protocol.dart';

const companionPhotoByteLimit = 2 * 1024 * 1024;
const companionMediaBodyLimit = ((companionPhotoByteLimit + 2) ~/ 3) * 4 + 2048;
const companionPhotoUploadRoute = '/v1/companion/photos/upload';
const companionPhotoReadRoute = '/v1/companion/photos/get';
const companionPhotoRemoveRoute = '/v1/companion/photos/remove';
const companionMediaRoutes = {
  companionPhotoUploadRoute,
  companionPhotoReadRoute,
  companionPhotoRemoveRoute,
};

enum CompanionPhotoPurpose { record, chat }

Object? decodeCompanionMediaJson(String source) {
  if (utf8.encode(source).length > companionMediaBodyLimit) {
    _invalid('media size');
  }
  try {
    return jsonDecode(source);
  } on FormatException {
    _invalid('media JSON');
  }
}

Uint8List _companionJpegBytes(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > ((companionPhotoByteLimit + 2) ~/ 3) * 4) {
    _invalid('photo size');
  }
  try {
    final bytes = base64Decode(value);
    if (bytes.isEmpty ||
        bytes.length > companionPhotoByteLimit ||
        base64Encode(bytes) != value) {
      _invalid('photo encoding');
    }
    return bytes.asUnmodifiableView();
  } on FormatException {
    _invalid('photo encoding');
  }
}

CompanionPhotoPurpose _photoPurpose(Object? value) {
  final found = CompanionPhotoPurpose.values
      .where((p) => p.name == value)
      .firstOrNull;
  if (found == null) _invalid('photo purpose');
  return found;
}

String? _photoGrant(CompanionPhotoPurpose purpose, Object? value) {
  if (purpose == CompanionPhotoPurpose.record) return _companionId(value);
  if (value != null) _invalid('chat photo grant');
  return null;
}

class CompanionPhotoUpload {
  CompanionPhotoUpload._(
    this.operationId,
    this.groupId,
    this.purpose,
    this.grantId,
    this.bytes,
  );
  factory CompanionPhotoUpload.fromJson(Object? value) {
    final map = _object(value, {
      'protocol',
      'operation_id',
      'group_id',
      'purpose',
      'grant_id',
      'jpeg_base64',
    });
    _checkCompanionProtocol(map['protocol']);
    final purpose = _photoPurpose(map['purpose']);
    return CompanionPhotoUpload._(
      _companionId(map['operation_id']),
      _companionId(map['group_id']),
      purpose,
      _photoGrant(purpose, map['grant_id']),
      _companionJpegBytes(map['jpeg_base64']),
    );
  }
  final String operationId;
  final String groupId;
  final CompanionPhotoPurpose purpose;
  final String? grantId;
  final Uint8List bytes;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'group_id': groupId,
    'purpose': purpose.name,
    'grant_id': grantId,
    'jpeg_base64': base64Encode(bytes),
  };
}

class CompanionPhotoMetadata {
  CompanionPhotoMetadata._(
    this.id,
    this.groupId,
    this.authorId,
    this.purpose,
    this.grantId,
    this.width,
    this.height,
    this.byteCount,
    this.sha256,
  );
  factory CompanionPhotoMetadata.fromJson(Object? value) {
    final map = _object(value, {
      'id',
      'group_id',
      'author_id',
      'purpose',
      'grant_id',
      'width',
      'height',
      'byte_count',
      'sha256',
    });
    final purpose = _photoPurpose(map['purpose']);
    final digest = _text(map['sha256'], 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) _invalid('photo digest');
    return CompanionPhotoMetadata._(
      _companionId(map['id']),
      _companionId(map['group_id']),
      _companionId(map['author_id']),
      purpose,
      _photoGrant(purpose, map['grant_id']),
      _integer(map['width'], 1, 1600),
      _integer(map['height'], 1, 1600),
      _integer(map['byte_count'], 1, companionPhotoByteLimit),
      digest,
    );
  }
  final String id;
  final String groupId;
  final String authorId;
  final CompanionPhotoPurpose purpose;
  final String? grantId;
  final int width;
  final int height;
  final int byteCount;
  final String sha256;
  Map<String, Object?> toJson() => {
    'id': id,
    'group_id': groupId,
    'author_id': authorId,
    'purpose': purpose.name,
    'grant_id': grantId,
    'width': width,
    'height': height,
    'byte_count': byteCount,
    'sha256': sha256,
  };
}

class CompanionPhotoReceipt {
  CompanionPhotoReceipt._(this.operationId, this.photo);
  factory CompanionPhotoReceipt.fromJson(
    Object? value, {
    required CompanionPhotoUpload request,
  }) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'operation_id', 'photo'});
    _checkCompanionProtocol(map['protocol']);
    final photo = CompanionPhotoMetadata.fromJson(map['photo']);
    if (_companionId(map['operation_id']) != request.operationId ||
        photo.groupId != request.groupId ||
        photo.purpose != request.purpose ||
        photo.grantId != request.grantId) {
      _invalid('photo receipt');
    }
    return CompanionPhotoReceipt._(request.operationId, photo);
  }
  final String operationId;
  final CompanionPhotoMetadata photo;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'photo': photo.toJson(),
  };
}

class CompanionPhotoRequest {
  CompanionPhotoRequest._(this.groupId, this.photoId, this.operationId);
  factory CompanionPhotoRequest.fromJson(Object? value, {bool remove = false}) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'photo_id',
      if (remove) 'operation_id',
    });
    _checkCompanionProtocol(map['protocol']);
    return CompanionPhotoRequest._(
      _companionId(map['group_id']),
      _companionId(map['photo_id']),
      remove ? _companionId(map['operation_id']) : null,
    );
  }
  final String groupId;
  final String photoId;
  final String? operationId;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'photo_id': photoId,
    'operation_id': ?operationId,
  };
}

class CompanionPhotoDownload {
  CompanionPhotoDownload._(this.photo, this.bytes);
  factory CompanionPhotoDownload.fromJson(
    Object? value, {
    required CompanionPhotoRequest request,
  }) {
    final map = _object(value, {'protocol', 'photo', 'jpeg_base64'});
    _checkCompanionProtocol(map['protocol']);
    final photo = CompanionPhotoMetadata.fromJson(map['photo']);
    final bytes = _companionJpegBytes(map['jpeg_base64']);
    if (photo.id != request.photoId ||
        photo.groupId != request.groupId ||
        photo.byteCount != bytes.length) {
      _invalid('photo download');
    }
    return CompanionPhotoDownload._(photo, bytes);
  }
  final CompanionPhotoMetadata photo;
  final Uint8List bytes;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'photo': photo.toJson(),
    'jpeg_base64': base64Encode(bytes),
  };
}
