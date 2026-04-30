import 'dart:convert';

class ChatPollOption {
  const ChatPollOption({
    required this.optionId,
    required this.text,
    required this.voteCount,
  });

  final String optionId;
  final String text;
  final int voteCount;

  ChatPollOption copyWith({int? voteCount}) {
    return ChatPollOption(
      optionId: optionId,
      text: text,
      voteCount: voteCount ?? this.voteCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'optionId': optionId,
        'text': text,
        'voteCount': voteCount,
      };

  static ChatPollOption? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final optionId = '${map['optionId'] ?? ''}'.trim();
    final text = '${map['text'] ?? ''}'.trim();
    if (optionId.isEmpty || text.isEmpty) return null;
    return ChatPollOption(
      optionId: optionId,
      text: text,
      voteCount: (map['voteCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class ChatPollVote {
  const ChatPollVote({
    required this.userId,
    required this.optionId,
    required this.votedAtUtc,
    this.userName = '',
    this.avatarUrl = '',
  });

  final String userId;
  final String optionId;
  final DateTime votedAtUtc;
  final String userName;
  final String avatarUrl;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'optionId': optionId,
        'votedAt': votedAtUtc.toUtc().toIso8601String(),
        'userName': userName,
        'avatarUrl': avatarUrl,
      };

  static ChatPollVote? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final userId = '${map['userId'] ?? ''}'.trim();
    final optionId = '${map['optionId'] ?? ''}'.trim();
    final votedAt = DateTime.tryParse('${map['votedAt'] ?? ''}')?.toUtc();
    if (userId.isEmpty || optionId.isEmpty || votedAt == null) return null;
    return ChatPollVote(
      userId: userId,
      optionId: optionId,
      votedAtUtc: votedAt,
      userName: '${map['userName'] ?? ''}'.trim(),
      avatarUrl: '${map['avatarUrl'] ?? ''}'.trim(),
    );
  }
}

class ChatPollMessage {
  const ChatPollMessage({
    required this.pollId,
    required this.question,
    required this.options,
    required this.votes,
    required this.createdBy,
    required this.createdAtUtc,
    required this.endsAtUtc,
    required this.allowMultipleAnswers,
    required this.visibleAnswers,
    required this.status,
  });

  final String pollId;
  final String question;
  final List<ChatPollOption> options;
  final List<ChatPollVote> votes;
  final String createdBy;
  final DateTime createdAtUtc;
  final DateTime endsAtUtc;
  final bool allowMultipleAnswers;
  final bool visibleAnswers;
  final String status;

  bool isEndedAt(DateTime nowUtc) =>
      status == 'ended' || !endsAtUtc.isAfter(nowUtc);

  int get totalVotes => votes.length;

  String? selectedOptionForUser(String userId) {
    final uid = userId.trim();
    if (uid.isEmpty) return null;
    for (final vote in votes) {
      if (vote.userId == uid) return vote.optionId;
    }
    return null;
  }

  String remainingLabel(DateTime nowUtc) {
    if (isEndedAt(nowUtc)) return 'Poll ended';
    final left = endsAtUtc.difference(nowUtc);
    if (left.inHours < 48) {
      final h = left.inHours <= 0 ? 1 : left.inHours;
      return '$h hrs left';
    }
    final d = left.inDays <= 0 ? 1 : left.inDays;
    return '$d days left';
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        't': 'poll',
        'pollId': pollId,
        'question': question,
        'options': options.map((e) => e.toJson()).toList(),
        'votes': votes.map((e) => e.toJson()).toList(),
        'createdBy': createdBy,
        'createdAt': createdAtUtc.toUtc().toIso8601String(),
        'endsAtUtc': endsAtUtc.toUtc().toIso8601String(),
        'allowMultipleAnswers': allowMultipleAnswers,
        'visibleAnswers': visibleAnswers,
        'status': status,
      };

  String encode() => jsonEncode(toJson());

  ChatPollMessage copyWith({
    List<ChatPollOption>? options,
    List<ChatPollVote>? votes,
    String? status,
  }) {
    return ChatPollMessage(
      pollId: pollId,
      question: question,
      options: options ?? this.options,
      votes: votes ?? this.votes,
      createdBy: createdBy,
      createdAtUtc: createdAtUtc,
      endsAtUtc: endsAtUtc,
      allowMultipleAnswers: allowMultipleAnswers,
      visibleAnswers: visibleAnswers,
      status: status ?? this.status,
    );
  }

  static ChatPollMessage? tryParse(String raw) {
    final body = raw.trim();
    if (body.isEmpty || !body.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static ChatPollMessage? fromJson(Map<String, dynamic> json) {
    if ('${json['t'] ?? ''}' != 'poll') return null;
    final pollId = '${json['pollId'] ?? ''}'.trim();
    final question = '${json['question'] ?? ''}'.trim();
    final createdBy = '${json['createdBy'] ?? ''}'.trim();
    final createdAtUtc = DateTime.tryParse('${json['createdAt'] ?? ''}')?.toUtc();
    final endsAtUtc = DateTime.tryParse('${json['endsAtUtc'] ?? ''}')?.toUtc();
    final optionsRaw = json['options'];
    final votesRaw = json['votes'];
    if (pollId.isEmpty ||
        question.isEmpty ||
        createdBy.isEmpty ||
        createdAtUtc == null ||
        endsAtUtc == null ||
        optionsRaw is! List ||
        votesRaw is! List) {
      return null;
    }
    final options = <ChatPollOption>[];
    for (final item in optionsRaw) {
      final parsed = ChatPollOption.fromJson(item);
      if (parsed != null) options.add(parsed);
    }
    if (options.length < 2) return null;
    final votes = <ChatPollVote>[];
    for (final item in votesRaw) {
      final parsed = ChatPollVote.fromJson(item);
      if (parsed != null) votes.add(parsed);
    }
    return ChatPollMessage(
      pollId: pollId,
      question: question,
      options: options,
      votes: votes,
      createdBy: createdBy,
      createdAtUtc: createdAtUtc,
      endsAtUtc: endsAtUtc,
      allowMultipleAnswers: json['allowMultipleAnswers'] == true,
      visibleAnswers: json['visibleAnswers'] == true,
      status: '${json['status'] ?? 'active'}'.trim().toLowerCase(),
    );
  }
}
