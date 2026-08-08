import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'customer_session.dart';

class CustomerSessionStore {
  CustomerSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _accessTokenKey = 'storyvault_customer_access_token';
  static const String _refreshTokenKey = 'storyvault_customer_refresh_token';
  static const String _expiresAtKey = 'storyvault_customer_expires_at';
  static const String _profileJsonKey = 'storyvault_customer_profile_json';

  final FlutterSecureStorage _storage;

  Future<CustomerSession?> load() async {
    final values = <String, String>{
      'access_token': await _storage.read(key: _accessTokenKey) ?? '',
      'refresh_token': await _storage.read(key: _refreshTokenKey) ?? '',
      'expires_at': await _storage.read(key: _expiresAtKey) ?? '',
    };
    final session = CustomerSession.fromStorageMap(values);
    return session.isUsable ? session : null;
  }

  Future<void> save(CustomerSession session) async {
    await _storage.write(key: _accessTokenKey, value: session.accessToken);
    await _storage.write(key: _refreshTokenKey, value: session.refreshToken);
    await _storage.write(
      key: _expiresAtKey,
      value: session.expiresAt.toUtc().toIso8601String(),
    );
  }

  Future<CustomerProfile?> loadProfile() async {
    final rawProfile = await _storage.read(key: _profileJsonKey);
    if (rawProfile == null || rawProfile.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(rawProfile) as Map<dynamic, dynamic>;
      return CustomerProfile.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProfile(CustomerProfile profile) async {
    await _storage.write(
      key: _profileJsonKey,
      value: jsonEncode(profile.toJson()),
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _expiresAtKey);
    await _storage.delete(key: _profileJsonKey);
  }
}
