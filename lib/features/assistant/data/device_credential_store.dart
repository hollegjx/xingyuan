import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceCredentialFailure implements Exception {
  const DeviceCredentialFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class DeviceCredentialStore {
  const DeviceCredentialStore({
    this.storage = const FlutterSecureStorage(),
    this.key = 'xingyuan.assistant.device.v1',
  });

  static const iosOptions = IOSOptions(
    accountName: 'xingyuan.assistant',
    accessibility: KeychainAccessibility.unlocked_this_device,
    synchronizable: false,
  );

  final FlutterSecureStorage storage;
  final String key;

  Future<String?> read() async {
    try {
      return await storage.read(key: key, iOptions: iosOptions);
    } catch (_) {
      throw const DeviceCredentialFailure('无法读取设备凭证，请解锁设备后重试。');
    }
  }

  static String validate(String input) {
    final value = input.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw const DeviceCredentialFailure('设备凭证格式不正确，原有凭证未更改。');
    }
    return value;
  }

  Future<void> save(String input) async {
    final value = validate(input);
    try {
      await storage.write(key: key, value: value, iOptions: iosOptions);
    } catch (_) {
      throw const DeviceCredentialFailure('设备凭证未能保存，请解锁设备后重试。');
    }
  }

  Future<void> clear() async {
    try {
      await storage.delete(key: key, iOptions: iosOptions);
    } catch (_) {
      throw const DeviceCredentialFailure('设备凭证未能清除，请重试。');
    }
  }
}
