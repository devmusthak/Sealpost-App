import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../data/auth/auth_repository.dart';
import '../../data/session/account_session_manager.dart';

class AuthInterceptor extends Interceptor {
  static bool _handlingUnauthorized = false;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = Get.find<AuthRepository>().accessToken;
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode ?? 0;
    final authHeader = err.requestOptions.headers['Authorization'];
    final hasBearerAuth =
        authHeader is String && authHeader.toLowerCase().startsWith('bearer ');

    if (status == 401 && hasBearerAuth && !_handlingUnauthorized) {
      _handlingUnauthorized = true;
      Future<void>(() async {
        try {
          if (Get.isRegistered<AccountSessionManager>()) {
            await Get.find<AccountSessionManager>().logoutActiveAccount();
          } else if (Get.isRegistered<AuthRepository>()) {
            await Get.find<AuthRepository>().logout();
          }
        } finally {
          _handlingUnauthorized = false;
        }
      });
    }
    handler.next(err);
  }
}
