class CustomerSession {
  const CustomerSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  factory CustomerSession.fromAuthJson(Map<String, dynamic> json) {
    final expiresAtText = (json['expires_at'] ?? '').toString();
    final parsedExpiresAt = DateTime.tryParse(expiresAtText);
    return CustomerSession(
      accessToken: (json['access_token'] ?? '').toString(),
      refreshToken: (json['refresh_token'] ?? '').toString(),
      expiresAt:
          parsedExpiresAt ??
          DateTime.now().toUtc().add(const Duration(minutes: 30)),
    );
  }

  Map<String, String> toStorageMap() {
    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt.toUtc().toIso8601String(),
    };
  }

  factory CustomerSession.fromStorageMap(Map<String, String> values) {
    return CustomerSession(
      accessToken: values['access_token'] ?? '',
      refreshToken: values['refresh_token'] ?? '',
      expiresAt:
          DateTime.tryParse(values['expires_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  bool get isUsable => accessToken.isNotEmpty && refreshToken.isNotEmpty;
}

class CustomerProfile {
  const CustomerProfile({
    required this.userId,
    required this.parentDisplayName,
    required this.pinSet,
    required this.hasFullLibrary,
    required this.children,
    required this.entitlements,
  });

  final String userId;
  final String parentDisplayName;
  final bool pinSet;
  final bool hasFullLibrary;
  final List<CustomerChildProfile> children;
  final List<CustomerEntitlement> entitlements;

  bool get onboardingComplete => children.isNotEmpty && pinSet;

  factory CustomerProfile.fromJson(Map<String, dynamic> json) {
    final user = (json['user'] as Map<dynamic, dynamic>? ?? const {})
        .cast<String, dynamic>();
    final settings = (json['settings'] as Map<dynamic, dynamic>? ?? const {})
        .cast<String, dynamic>();
    final children = (json['children'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (item) => CustomerChildProfile.fromJson(item.cast<String, dynamic>()),
        )
        .toList(growable: false);
    final entitlements =
        (json['entitlements'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (item) =>
                  CustomerEntitlement.fromJson(item.cast<String, dynamic>()),
            )
            .toList(growable: false);
    return CustomerProfile(
      userId: (user['id'] ?? '').toString(),
      parentDisplayName: (user['parent_display_name'] ?? '').toString(),
      pinSet: settings['pin_set'] == true,
      hasFullLibrary: json['has_full_library'] == true,
      children: children,
      entitlements: entitlements,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user': {'id': userId, 'parent_display_name': parentDisplayName},
      'settings': {'pin_set': pinSet},
      'has_full_library': hasFullLibrary,
      'children': children.map((child) => child.toJson()).toList(),
      'entitlements': entitlements
          .map((entitlement) => entitlement.toJson())
          .toList(),
    };
  }
}

class CustomerChildProfile {
  const CustomerChildProfile({
    required this.id,
    required this.nickname,
    required this.ageGroup,
  });

  final String id;
  final String nickname;
  final String ageGroup;

  factory CustomerChildProfile.fromJson(Map<String, dynamic> json) {
    return CustomerChildProfile(
      id: (json['id'] ?? '').toString(),
      nickname: (json['nickname'] ?? '').toString(),
      ageGroup: (json['age_group'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'nickname': nickname, 'age_group': ageGroup};
  }
}

class CustomerEntitlement {
  const CustomerEntitlement({
    required this.type,
    required this.source,
    required this.status,
    this.endsAt,
  });

  final String type;
  final String source;
  final String status;
  final DateTime? endsAt;

  factory CustomerEntitlement.fromJson(Map<String, dynamic> json) {
    return CustomerEntitlement(
      type: (json['type'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      endsAt: DateTime.tryParse((json['ends_at'] ?? '').toString()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'source': source,
      'status': status,
      'ends_at': endsAt?.toUtc().toIso8601String(),
    };
  }
}
