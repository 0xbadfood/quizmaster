import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'customer_session.dart';
import 'customer_session_store.dart';

class CustomerApiClient {
  CustomerApiClient({
    http.Client? httpClient,
    CustomerSessionStore? sessionStore,
    String productionOrigin = 'https://api.toystech.in',
  }) : _http = httpClient ?? http.Client(),
       _sessionStore = sessionStore ?? CustomerSessionStore(),
       _productionOrigin = productionOrigin;

  final http.Client _http;
  final CustomerSessionStore _sessionStore;
  final String _productionOrigin;

  String get _apiBase => '$_productionOrigin/api/customer/v1';

  Future<CustomerSession?> loadStoredSession() {
    return _sessionStore.load();
  }

  Future<void> saveSession(CustomerSession session) {
    return _sessionStore.save(session);
  }

  Future<CustomerProfile?> loadStoredProfile() {
    return _sessionStore.loadProfile();
  }

  Future<void> saveProfile(CustomerProfile profile) {
    return _sessionStore.saveProfile(profile);
  }

  Future<void> clearSession() {
    return _sessionStore.clear();
  }

  Future<CustomerSession> signInWithGoogle({
    required String idToken,
    String? providerSub,
    String? email,
    String? displayName,
    String? appInstanceId,
    String? platform,
    String? appVersion,
  }) async {
    return _providerAuth(
      path: '/auth/google',
      payload: {
        'id_token': idToken,
        'provider_sub': providerSub,
        'email': email,
        'display_name': displayName,
        'app_instance_id': appInstanceId,
        'platform': platform,
        'app_version': appVersion,
      },
    );
  }

  Future<CustomerSession> signInWithApple({
    required String idToken,
    String? providerSub,
    String? email,
    String? displayName,
    String? appInstanceId,
    String? platform,
    String? appVersion,
  }) async {
    return _providerAuth(
      path: '/auth/apple',
      payload: {
        'id_token': idToken,
        'provider_sub': providerSub,
        'email': email,
        'display_name': displayName,
        'app_instance_id': appInstanceId,
        'platform': platform,
        'app_version': appVersion,
      },
    );
  }

  Future<CustomerSession> refresh(CustomerSession session) async {
    final response = await _post(
      '/auth/refresh',
      body: {'refresh_token': session.refreshToken},
    );
    final refreshed = CustomerSession.fromAuthJson(response);
    await saveSession(refreshed);
    return refreshed;
  }

  Future<void> logout(CustomerSession? session) async {
    if (session != null && session.refreshToken.isNotEmpty) {
      try {
        await _post(
          '/auth/logout',
          body: {'refresh_token': session.refreshToken},
          accessToken: session.accessToken,
        );
      } catch (_) {
        // Local session cleanup should still happen if the network call fails.
      }
    }
    await clearSession();
  }

  Future<CustomerProfile> me(CustomerSession session) async {
    final response = await _get('/me', accessToken: session.accessToken);
    return CustomerProfile.fromJson(response);
  }

  Future<CustomerProfile> updateParent({
    required CustomerSession session,
    String? displayName,
  }) async {
    await _patch(
      '/me/parent',
      accessToken: session.accessToken,
      body: {'display_name': displayName},
    );
    return me(session);
  }

  Future<CustomerProfile> createChild({
    required CustomerSession session,
    required String nickname,
    required String ageGroup,
    String? avatarKey,
    List<String> interests = const [],
  }) async {
    await _post(
      '/me/children',
      accessToken: session.accessToken,
      body: {
        'nickname': nickname,
        'age_group': ageGroup,
        'avatar_key': avatarKey,
        'interests': interests,
      },
    );
    return me(session);
  }

  Future<CustomerProfile> setPin({
    required CustomerSession session,
    required String pin,
  }) async {
    await _post(
      '/me/pin',
      accessToken: session.accessToken,
      body: {'pin': pin},
    );
    return me(session);
  }

  Future<void> verifyPin({
    required CustomerSession session,
    required String pin,
  }) async {
    await _post(
      '/me/pin/verify',
      accessToken: session.accessToken,
      body: {'pin': pin},
    );
  }

  Future<CustomerProfile> redeemToyCode({
    required CustomerSession session,
    required String code,
  }) async {
    await _post(
      '/toy-codes/redeem',
      accessToken: session.accessToken,
      body: {'code': code},
    );
    return me(session);
  }

  Future<CustomerSession> _providerAuth({
    required String path,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _post(path, body: payload);
    final session = CustomerSession.fromAuthJson(response);
    await saveSession(session);
    return session;
  }

  Future<Map<String, dynamic>> _get(String path, {String? accessToken}) async {
    final response = await _http.get(
      Uri.parse('$_apiBase$path'),
      headers: _headers(accessToken),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final response = await _http.post(
      Uri.parse('$_apiBase$path'),
      headers: _headers(accessToken),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _patch(
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final response = await _http.patch(
      Uri.parse('$_apiBase$path'),
      headers: _headers(accessToken),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    );
    return _decode(response);
  }

  Map<String, String> _headers(String? accessToken) {
    return {
      'content-type': 'application/json',
      if ((accessToken ?? '').isNotEmpty)
        HttpHeaders.authorizationHeader: 'Bearer $accessToken',
    };
  }

  Map<String, dynamic> _decode(http.Response response) {
    final rawBody = response.body.trim();
    final decoded = rawBody.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(rawBody) as Map<dynamic, dynamic>)
              .cast<String, dynamic>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded['detail']?.toString() ?? response.reasonPhrase;
      throw HttpException(
        detail == null || detail.isEmpty
            ? 'Request failed: ${response.statusCode}'
            : detail,
      );
    }
    return decoded;
  }
}
