class AuthResponse {
  const AuthResponse({
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
  });

  final String token;
  final String userId;
  final String email;
  final String name;

  /// Dio/json_decode often yields [Map<dynamic, dynamic>]; avoid `as Map<String, dynamic>` casts.
  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final userRaw = json['user'];
    final Map<String, dynamic> user = userRaw is Map
        ? Map<String, dynamic>.from(userRaw)
        : <String, dynamic>{};

    final token = json['token'];
    if (token == null || '$token'.isEmpty) {
      throw FormatException('Login response missing token');
    }

    return AuthResponse(
      token: '$token',
      userId: '${user['id'] ?? ''}',
      email: '${user['email'] ?? ''}',
      name: '${user['name'] ?? ''}',
    );
  }
}
