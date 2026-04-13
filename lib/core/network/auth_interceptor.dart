import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../data/auth/auth_repository.dart';

class AuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = Get.find<AuthRepository>().accessToken;
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }
}
