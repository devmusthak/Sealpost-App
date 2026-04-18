/// LAN / dev server base URL.
///
/// Override per machine or emulator:
/// `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4999/` (Android emulator → host)
/// `flutter run --dart-define=API_BASE_URL=http://192.168.x.x:4999/` (physical device on Wi‑Fi)
abstract final class ApiEndpoints {
  static String get baseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromEnv.isNotEmpty) {
      return fromEnv.endsWith('/') ? fromEnv : '$fromEnv/';
    }
    return 'http://192.168.1.18:4999/';
  }

  static const String health = '/health';

  static const String authPrefix = '/api/auth';
  static const String login = '$authPrefix/login';
  static const String register = '$authPrefix/register';
  static const String fcmToken = '$authPrefix/fcm-token';
  static const String presence = '$authPrefix/presence';
  static const String userSearch = '$authPrefix/users/search';

  static const String mails = '/api/mails';

  static const String mailsSend = '$mails/send';
  static const String chatPrefix = '/api/chat';
  static const String chatContacts = '$chatPrefix/contacts';
  static const String chatFriendRequest = '$chatPrefix/friend-request';
  static const String chatAcceptFriendRequest = '$chatFriendRequest/accept';
  static const String chatNotifyFriendRequest = '$chatFriendRequest/notify';
  static const String chatMessages = '$chatPrefix/messages';
  static const String chatMessagesRead = '$chatMessages/read';
  static const String chatMessageReaction = '$chatMessages/reaction';

  static String get socketOrigin {
    final u = Uri.parse(baseUrl);
    if (u.hasPort) {
      return '${u.scheme}://${u.host}:${u.port}';
    }
    return '${u.scheme}://${u.host}';
  }
}
