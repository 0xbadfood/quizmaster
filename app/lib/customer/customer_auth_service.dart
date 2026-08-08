import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'customer_api_client.dart';
import 'customer_session.dart';

class CustomerAuthCanceledException implements Exception {
  const CustomerAuthCanceledException();
}

class CustomerAuthService {
  static const String _defaultGoogleServerClientId =
      '137843631604-h8mdeat6cj1ts1p5le6opa8fmcs7f7hp.apps.googleusercontent.com';
  static const String _googleClientId = String.fromEnvironment(
    'STORYVAULT_GOOGLE_CLIENT_ID',
  );
  static const String _googleIosClientId = String.fromEnvironment(
    'STORYVAULT_GOOGLE_IOS_CLIENT_ID',
  );
  static const String _googleServerClientId = String.fromEnvironment(
    'STORYVAULT_GOOGLE_SERVER_CLIENT_ID',
    defaultValue: _defaultGoogleServerClientId,
  );

  bool _googleInitialized = false;

  Future<CustomerSession> signInWithGoogle(CustomerApiClient apiClient) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw StateError(
        'Google sign-in is enabled for Android and iOS devices.',
      );
    }
    final GoogleSignIn googleSignIn = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await googleSignIn.initialize(
        clientId: _googlePlatformClientId(),
        serverClientId: _emptyToNull(_googleServerClientId),
      );
      _googleInitialized = true;
    }
    if (!googleSignIn.supportsAuthenticate()) {
      throw StateError('Google sign-in is not supported on this device.');
    }
    final GoogleSignInAccount account;
    try {
      account = await googleSignIn.authenticate(
        scopeHint: const <String>['email', 'profile'],
      );
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        if (_isGoogleAndroidOAuthRegistrationFailure(error)) {
          throw StateError(
            'Google sign-in is not configured for this Android app. Add this package name and signing SHA fingerprint in Google Cloud or Firebase.',
          );
        }
        throw const CustomerAuthCanceledException();
      }
      rethrow;
    }
    final String? idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError(
        'Google did not return an ID token. Check the Google OAuth client and server client ID setup.',
      );
    }
    return apiClient.signInWithGoogle(
      idToken: idToken,
      providerSub: account.id,
      email: account.email,
      displayName: account.displayName,
      platform: _platformName(),
      appVersion: await _appVersion(),
    );
  }

  Future<CustomerSession> signInWithApple(CustomerApiClient apiClient) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      throw StateError('Apple sign-in is enabled for iOS devices.');
    }
    final bool available = await SignInWithApple.isAvailable();
    if (!available) {
      throw StateError('Sign in with Apple is not available on this device.');
    }
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const <AppleIDAuthorizationScopes>[
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const CustomerAuthCanceledException();
      }
      rethrow;
    }
    final String? idToken = credential.identityToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Apple did not return an identity token.');
    }
    return apiClient.signInWithApple(
      idToken: idToken,
      providerSub: credential.userIdentifier,
      email: credential.email,
      displayName: _appleDisplayName(credential),
      platform: _platformName(),
      appVersion: await _appVersion(),
    );
  }

  String? _appleDisplayName(AuthorizationCredentialAppleID credential) {
    final parts = <String>[
      credential.givenName ?? '',
      credential.familyName ?? '',
    ].map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' ');
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _googlePlatformClientId() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // On iOS the GoogleSignIn SDK can also read GIDClientID from Info.plist.
      // Returning null here lets the native SDK use that project configuration.
      return _emptyToNull(_googleIosClientId);
    }
    return _emptyToNull(_googleClientId);
  }

  bool _isGoogleAndroidOAuthRegistrationFailure(GoogleSignInException error) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final text = [
      error.description,
      error.details?.toString(),
    ].whereType<String>().join(' ').toLowerCase();
    return text.contains('account reauth failed') ||
        text.contains('unregistered_on_api_console') ||
        text.contains('not registered to use oauth2.0');
  }

  String _platformName() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  Future<String?> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      return build.isEmpty ? info.version : '${info.version}+$build';
    } catch (_) {
      return null;
    }
  }
}
