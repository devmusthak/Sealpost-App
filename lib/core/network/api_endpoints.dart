
abstract final class ApiEndpoints {
  static String get baseUrl {
    return 'https://mail.livera.ae/';
  }

  static const String health = '/health';

  static const String authPrefix = '/api/auth';
  static const String login = '$authPrefix/login';
  static const String register = '$authPrefix/register';
  static const String fcmToken = '$authPrefix/fcm-token';

  static const String mails = '/api/mails';

  static const String mailsSend = '$mails/send';

  static String get socketOrigin {
    final u = Uri.parse(baseUrl);
    if (u.hasPort) {
      return '${u.scheme}://${u.host}:${u.port}';
    }
    return '${u.scheme}://${u.host}';
  }
}
