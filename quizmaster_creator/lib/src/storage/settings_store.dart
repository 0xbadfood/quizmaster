import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSettingsStore implements SettingsStore {
  SecureSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class MemorySettingsStore implements SettingsStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
