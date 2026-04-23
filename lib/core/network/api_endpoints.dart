
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
  /// Multipart field [file] — ImageKit upload (server-side).
  static const String chatMediaUpload = '$chatPrefix/media/upload';
  static const String chatMessagesRead = '$chatMessages/read';
  static const String chatMessageReaction = '$chatMessages/reaction';
  /// PATCH same path as [chatMessages] — edit existing message (sender, time window).
  static const String chatMessageEdit = chatMessages;

  static String get socketOrigin {
    final u = Uri.parse(baseUrl);
    if (u.hasPort) {
      return '${u.scheme}://${u.host}:${u.port}';
    }
    return '${u.scheme}://${u.host}';
  }
}
