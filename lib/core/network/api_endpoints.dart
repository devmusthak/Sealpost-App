
abstract final class ApiEndpoints {
  static String get baseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (fromEnv.isNotEmpty) {
      return fromEnv.endsWith('/') ? fromEnv : '$fromEnv/';
    }
    return 'https://mail.livera.ae/';
    // return 'http://192.168.1.6:4999/';
  }

  static const String health = '/health';

  static const String authPrefix = '/api/auth';
  static const String login = '$authPrefix/login';
  static const String register = '$authPrefix/register';
  static const String fcmToken = '$authPrefix/fcm-token';
  static const String voipToken = '$authPrefix/voip-token';
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
  static const String chatMessagePollVote = '$chatMessages/poll/vote';
  /// PATCH same path as [chatMessages] — edit existing message (sender, time window).
  static const String chatMessageEdit = chatMessages;
  static const String chatGroups = '$chatPrefix/groups';
  static const String agoraRtcToken = '$chatPrefix/call/agora-token';
  static const String agoraCallInvite = '$chatPrefix/call/agora-invite';
  static const String voiceCallAccept = '$chatPrefix/call/accept';
  static const String voiceCallReject = '$chatPrefix/call/reject';
  static const String voiceCallEnd = '$chatPrefix/call/end';
  static const String voiceCallStatus = '$chatPrefix/call/status';
  static const String chatGroupInvites = '$chatGroups/invites';
  static const String chatGroupInviteJoin = '$chatGroups/invite/join';
  static const String chatGroupMessages = '$chatGroups/messages';
  static const String chatGroupMessagesRead = '$chatGroupMessages/read';
  static const String chatGroupMessageReaction = '$chatGroupMessages/reaction';
  static const String chatGroupMessagePollVote = '$chatGroupMessages/poll/vote';
  static const String chatGroupMessageEdit = chatGroupMessages;
  static String chatGroupMembers(String groupId) => '$chatGroups/$groupId/members';
  static String chatGroupShared(String groupId) => '$chatGroups/$groupId/shared';
  static String chatGroupInviteInfo(String inviteId) => '$chatGroups/invite/$inviteId';

  static String get socketOrigin {
    final u = Uri.parse(baseUrl);
    if (u.hasPort) {
      return '${u.scheme}://${u.host}:${u.port}';
    }
    return '${u.scheme}://${u.host}';
  }
}
