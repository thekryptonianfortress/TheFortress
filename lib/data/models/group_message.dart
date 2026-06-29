import 'dart:convert';

class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String senderUsername;
  final String? senderAvatarUrl;
  final String content;
  final String? attachmentUrl;
  final String? attachmentType;
  final String? attachmentName;
  final int? attachmentSize;
  final String? replyToId;
  final Map<String, List<String>> reactions;
  final bool isDeleted;
  final DateTime? editedAt;
  final DateTime createdAt;
  final bool isOutgoing;
  final Map<int, int>? pollVotes;
  final int? myPollVote;

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderUsername,
    this.senderAvatarUrl,
    required this.content,
    this.attachmentUrl,
    this.attachmentType,
    this.attachmentName,
    this.attachmentSize,
    this.replyToId,
    this.reactions = const {},
    this.isDeleted = false,
    this.editedAt,
    required this.createdAt,
    required this.isOutgoing,
    this.pollVotes,
    this.myPollVote,
  });

  GroupMessage copyWith({
    String? content,
    Map<String, List<String>>? reactions,
    bool? isDeleted,
    DateTime? editedAt,
    Map<int, int>? pollVotes,
    int? myPollVote,
  }) =>
      GroupMessage(
        id: id,
        groupId: groupId,
        senderId: senderId,
        senderUsername: senderUsername,
        senderAvatarUrl: senderAvatarUrl,
        content: content ?? this.content,
        attachmentUrl: attachmentUrl,
        attachmentType: attachmentType,
        attachmentName: attachmentName,
        attachmentSize: attachmentSize,
        replyToId: replyToId,
        reactions: reactions ?? this.reactions,
        isDeleted: isDeleted ?? this.isDeleted,
        editedAt: editedAt ?? this.editedAt,
        createdAt: createdAt,
        isOutgoing: isOutgoing,
        pollVotes: pollVotes ?? this.pollVotes,
        myPollVote: myPollVote ?? this.myPollVote,
      );

  factory GroupMessage.fromJson(Map<String, dynamic> j, String myId) => GroupMessage(
        id: j['id'] as String,
        groupId: j['group_id'] as String,
        senderId: j['sender_id'] as String,
        senderUsername: j['sender_username'] as String? ?? '',
        senderAvatarUrl: j['sender_avatar_url'] as String?,
        content: j['content'] as String? ?? '',
        attachmentUrl: j['attachment_url'] as String?,
        attachmentType: j['attachment_type'] as String?,
        attachmentName: j['attachment_name'] as String?,
        attachmentSize: (j['attachment_size'] as num?)?.toInt(),
        replyToId: j['reply_to_id'] as String?,
        reactions: _parseReactions(j['reactions']),
        isDeleted: j['is_deleted'] as bool? ?? false,
        editedAt: j['edited_at'] != null
            ? DateTime.tryParse(j['edited_at'] as String)
            : null,
        createdAt: DateTime.parse(j['created_at'] as String),
        isOutgoing: j['sender_id'] == myId,
        pollVotes: _parsePollVotes(j['poll_votes']),
        myPollVote: (j['my_poll_vote'] as num?)?.toInt(),
      );

  static Map<int, int>? _parsePollVotes(dynamic raw) {
    if (raw == null) return null;
    try {
      final map = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : raw as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(int.parse(k), (v as num).toInt()));
    } catch (_) {
      return null;
    }
  }

  static Map<String, List<String>> _parseReactions(dynamic raw) {
    if (raw == null) return {};
    try {
      final map = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : raw as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, List<String>.from(v as List)));
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'group_id': groupId,
        'sender_id': senderId,
        'sender_username': senderUsername,
        'sender_avatar_url': senderAvatarUrl,
        'content': content,
        'attachment_url': attachmentUrl,
        'attachment_type': attachmentType,
        'attachment_name': attachmentName,
        'attachment_size': attachmentSize,
        'reply_to_id': replyToId,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
        'is_deleted': isDeleted ? 1 : 0,
        'edited_at': editedAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'is_outgoing': isOutgoing ? 1 : 0,
        'poll_votes': pollVotes != null
            ? jsonEncode(pollVotes!.map((k, v) => MapEntry('$k', v)))
            : null,
        'my_poll_vote': myPollVote,
      };

  factory GroupMessage.fromDbMap(Map<String, dynamic> m) => GroupMessage(
        id: m['id'] as String,
        groupId: m['group_id'] as String,
        senderId: m['sender_id'] as String,
        senderUsername: m['sender_username'] as String? ?? '',
        senderAvatarUrl: m['sender_avatar_url'] as String?,
        content: m['content'] as String? ?? '',
        attachmentUrl: m['attachment_url'] as String?,
        attachmentType: m['attachment_type'] as String?,
        attachmentName: m['attachment_name'] as String?,
        attachmentSize: m['attachment_size'] as int?,
        replyToId: m['reply_to_id'] as String?,
        reactions: _parseReactions(m['reactions']),
        isDeleted: (m['is_deleted'] as int? ?? 0) == 1,
        editedAt: m['edited_at'] != null ? DateTime.tryParse(m['edited_at'] as String) : null,
        createdAt: DateTime.parse(m['created_at'] as String),
        isOutgoing: (m['is_outgoing'] as int? ?? 0) == 1,
        pollVotes: _parsePollVotes(m['poll_votes']),
        myPollVote: m['my_poll_vote'] as int?,
      );
}
