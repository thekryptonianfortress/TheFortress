import 'dart:convert';
enum MessageStatus { pending, sent, delivered, read }

class Message {
  final String id;
  final String senderId;
  final String recipientId;
  final String encryptedContent;
  final String nonce;
  final String? decryptedContent;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? editedAt;
  final bool isOutgoing;
  final bool isDeleted;
  final String? replyToId;
  /// emoji → list of userIds who reacted
  final Map<String, List<String>> reactions;

  // Attachment fields (null = plain text message)
  final String? attachmentUrl;
  final String? attachmentType; // 'image' | 'gif' | 'file'
  final String? attachmentName;
  final int? attachmentSize;

  const Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.encryptedContent,
    required this.nonce,
    this.decryptedContent,
    required this.status,
    required this.createdAt,
    this.editedAt,
    required this.isOutgoing,
    this.isDeleted = false,
    this.replyToId,
    this.reactions = const {},
    this.attachmentUrl,
    this.attachmentType,
    this.attachmentName,
    this.attachmentSize,
  });

  Message copyWith({
    String? decryptedContent,
    MessageStatus? status,
    String? encryptedContent,
    DateTime? editedAt,
    bool? isDeleted,
    Map<String, List<String>>? reactions,
  }) =>
      Message(
        id: id,
        senderId: senderId,
        recipientId: recipientId,
        encryptedContent: encryptedContent ?? this.encryptedContent,
        nonce: nonce,
        decryptedContent: decryptedContent ?? this.decryptedContent,
        status: status ?? this.status,
        createdAt: createdAt,
        editedAt: editedAt ?? this.editedAt,
        isOutgoing: isOutgoing,
        isDeleted: isDeleted ?? this.isDeleted,
        replyToId: replyToId,
        reactions: reactions ?? this.reactions,
        attachmentUrl: attachmentUrl,
        attachmentType: attachmentType,
        attachmentName: attachmentName,
        attachmentSize: attachmentSize,
      );

  factory Message.fromJson(Map<String, dynamic> json, String myId) => Message(
        id: json['id'] as String,
        senderId: json['sender_id'] as String,
        recipientId: json['recipient_id'] as String,
        encryptedContent: json['encrypted_content'] as String,
        nonce: json['nonce'] as String? ?? '',
        status: _statusFromString(json['status'] as String? ?? 'sent'),
        createdAt: DateTime.parse(json['created_at'] as String),
        editedAt: json['edited_at'] != null
            ? DateTime.tryParse(json['edited_at'] as String)
            : null,
        isOutgoing: json['sender_id'] == myId,
        isDeleted: (json['is_deleted'] as bool?) ?? false,
        replyToId: json['reply_to_id'] as String?,
        reactions: _reactionsFromJson(json['reactions']),
        attachmentUrl: json['attachment_url'] as String?,
        attachmentType: json['attachment_type'] as String?,
        attachmentName: json['attachment_name'] as String?,
        attachmentSize: (json['attachment_size'] as num?)?.toInt(),
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'sender_id': senderId,
        'recipient_id': recipientId,
        'encrypted_content': encryptedContent,
        'nonce': nonce,
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        'edited_at': editedAt?.toIso8601String(),
        'is_outgoing': isOutgoing ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'reply_to_id': replyToId,
        'reactions': _reactionsToJson(reactions),
        'attachment_url': attachmentUrl,
        'attachment_type': attachmentType,
        'attachment_name': attachmentName,
        'attachment_size': attachmentSize,
      };

  factory Message.fromDbMap(Map<String, dynamic> map) => Message(
        id: map['id'] as String,
        senderId: map['sender_id'] as String,
        recipientId: map['recipient_id'] as String,
        encryptedContent: map['encrypted_content'] as String,
        nonce: map['nonce'] as String,
        status: _statusFromString(map['status'] as String),
        createdAt: DateTime.parse(map['created_at'] as String),
        editedAt: map['edited_at'] != null
            ? DateTime.tryParse(map['edited_at'] as String)
            : null,
        isOutgoing: (map['is_outgoing'] as int) == 1,
        isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
        replyToId: map['reply_to_id'] as String?,
        reactions: _reactionsFromJson(map['reactions']),
        attachmentUrl: map['attachment_url'] as String?,
        attachmentType: map['attachment_type'] as String?,
        attachmentName: map['attachment_name'] as String?,
        attachmentSize: map['attachment_size'] as int?,
      );

  static Map<String, List<String>> _reactionsFromJson(dynamic raw) {
    if (raw == null) return {};
    try {
      final map = (raw is String) ? (jsonDecode(raw) as Map<String, dynamic>) : (raw as Map<String, dynamic>);
      return map.map((k, v) => MapEntry(k, List<String>.from(v as List)));
    } catch (_) { return {}; }
  }

  static String? _reactionsToJson(Map<String, List<String>> r) =>
      r.isEmpty ? null : jsonEncode(r);

  static MessageStatus _statusFromString(String s) =>
      MessageStatus.values.firstWhere((e) => e.name == s,
          orElse: () => MessageStatus.sent);
}
