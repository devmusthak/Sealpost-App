import 'package:dio/dio.dart';

import '../../core/network/api_endpoints.dart';
import '../session/auth_session.dart';
import '../session/session_storage.dart';
import 'auth_exception.dart';
import 'auth_response.dart';

class AuthRepository {
  AuthRepository(this._dio, this._sessionStorage);

  final Dio _dio;
  final SessionStorage _sessionStorage;

  AuthSession? _session;

  AuthSession? get session => _session;

  String? get accessToken => _session?.token;

  String? get userId => _session?.userId;

  /// [firebaseUid] — set when Firebase Auth is wired; send `''` until then (server clears field).
  Future<void> login({
    required String email,
    required String password,
    String firebaseUid = '',
  }) async {
    try {
      final res = await _dio.post(
        ApiEndpoints.login,
        data: {
          'email': email,
          'password': password,
          'firebaseUid': firebaseUid,
        },
      );

      final status = res.statusCode ?? 0;
      final raw = res.data;

      if (status == 200 && raw != null) {
        final data = _mapFromDynamic(raw);
        if (data == null) {
          throw AuthException('Invalid login response', statusCode: status);
        }
        try {
          final auth = AuthResponse.fromJson(data);
          _session = AuthSession.fromAuthResponse(auth);
          await _sessionStorage.save(_session!);
        } on FormatException catch (e) {
          throw AuthException(
            e.message,
            statusCode: status,
          );
        }
        return;
      }

      final errMap = _mapFromDynamic(raw);
      if (errMap != null) {
        throw _fromErrorBody(status, errMap);
      }
      throw AuthException('Login failed', statusCode: status);
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  /// JSON decode often yields [Map<dynamic, dynamic>]; normalize for safe parsing.
  Map<String, dynamic>? _mapFromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  AuthException _fromErrorBody(int status, Map<String, dynamic> data) {
    final msg = data['message'] as String? ?? 'Request failed';
    if (status == 423) {
      final retry = data['retryAfterSeconds'];
      return AuthException(
        msg,
        statusCode: status,
        retryAfterSeconds: retry is int ? retry : int.tryParse('$retry'),
      );
    }
    return AuthException(msg, statusCode: status);
  }

  AuthException _fromDio(DioException e) {
    final status = e.response?.statusCode;
    final raw = e.response?.data;
    final data = _mapFromDynamic(raw);
    if (data != null && status != null) {
      return _fromErrorBody(status, data);
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError) {
      return AuthException(
        'Cannot reach server. Set API_BASE_URL (e.g. http://10.0.2.2:3001 for Android emulator).',
        statusCode: status,
      );
    }
    return AuthException(
      e.message ?? 'Network error',
      statusCode: status,
    );
  }

  /// Restores session from disk. Returns whether a non-empty session was loaded.
  Future<bool> restoreSession() async {
    final s = await _sessionStorage.load();
    if (s == null || s.token.isEmpty) {
      _session = null;
      return false;
    }
    _session = s;
    return true;
  }

  Future<void> logout() async {
    final bearer = accessToken;
    if (bearer != null && bearer.isNotEmpty) {
      try {
        await _dio.post(
          ApiEndpoints.presence,
          data: {'online': false},
          options: Options(
            headers: {'Authorization': 'Bearer $bearer'},
          ),
        );
      } catch (_) {
        /* still clear session */
      }
    }
    _session = null;
    await _sessionStorage.clear();
  }

  /// Saves FCM token for push (new mail). No-op if not signed in.
  Future<void> registerFcmToken(String fcmToken) async {
    final t = fcmToken.trim();
    if (t.isEmpty) return;
    final bearer = accessToken;
    if (bearer == null || bearer.isEmpty) return;
    try {
      await _dio.post(
        ApiEndpoints.fcmToken,
        data: {'fcmToken': t},
        options: Options(
          headers: {'Authorization': 'Bearer $bearer'},
        ),
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  Future<void> updatePresence({required bool online}) async {
    final bearer = accessToken;
    if (bearer == null || bearer.isEmpty) return;
    try {
      await _dio.post(
        ApiEndpoints.presence,
        data: {'online': online},
        options: Options(
          headers: {'Authorization': 'Bearer $bearer'},
        ),
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  /// After login or restoring a session, push online so presence works even if lifecycle already fired before a token existed.
  Future<void> syncPresenceForActiveSession() async {
    await updatePresence(online: true);
  }
}
