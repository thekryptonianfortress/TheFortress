enum MessageStatus { pending, sent, delivered, read }

class Message {
  final String id;
  final String senderId;
  final String recipientId;
  final String encryptedContent;
  final String nonce;
  final String? decryptedContent; // populated after decryption, not stored
  final MessageStatus status;
  final DateTime createdAt;
  final bool isOutgoing;

  const Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.encryptedContent,
    required this.nonce,
    this.decryptedContent,
    required this.status,
    required this.createdAt,
    required this.isOutgoing,
  });

  Message copyWith({String? decryptedContent, MessageStatus? status}) => Message(
        id: id,
        senderId: senderId,
        recipientId: recipientId,
        encryptedContent: encryptedContent,
        nonce: nonce,
        decryptedContent: decryptedContent ?? this.decryptedContent,
        status: status ?? this.status,
        createdAt: createdAt,
        isOutgoing: isOutgoing,
      );

  factory Message.fromJson(Map<String, dynamic> json, String myId) => Message(
        id: json['id'] as String,
        senderId: json['sender_id'] as String,
        recipientId: json['recipient_id'] as String,
        encryptedContent: json['encrypted_content'] as String,
        nonce: json['nonce'] as String,
        status: _statusFromString(json['status'] as String? ?? 'sent'),
        createdAt: DateTime.parse(json['created_at'] as String),
        isOutgoing: json['sender_id'] == myId,
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'sender_id': senderId,
        'recipient_id': recipientId,
        'encrypted_content': encryptedContent,
        'nonce': nonce,
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        'is_outgoing': isOutgoing ? 1 : 0,
      };

  factory Message.fromDbMap(Map<String, dynamic> map) => Message(
        id: map['id'] as String,
        senderId: map['sender_id'] as String,
        recipientId: map['recipient_id'] as String,
        encryptedContent: map['encrypted_content'] as String,
        nonce: map['nonce'] as String,
        status: _statusFromString(map['status'] as String),
        createdAt: DateTime.parse(map['created_at'] as String),
        isOutgoing: (map['is_outgoing'] as int) == 1,
      );

  static MessageStatus _statusFromString(String s) =>
      MessageStatus.values.firstWhere((e) => e.name == s, orElse: () => MessageStatus.sent);
}
