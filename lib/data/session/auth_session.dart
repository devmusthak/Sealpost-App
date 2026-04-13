import '../auth/auth_response.dart';

class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
  });

  final String token;
  final String userId;
  final String email;
  final String name;

  factory AuthSession.fromAuthResponse(AuthResponse r) {
    return AuthSession(
      token: r.token,
      userId: r.userId,
      email: r.email,
      name: r.name,
    );
  }
}
