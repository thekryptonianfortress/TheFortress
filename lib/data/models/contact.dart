class Contact {
  final String id;
  final String userId;       // owner (me)
  final String contactId;    // the contact's user id
  final String virtualId;
  final String username;
  final String publicKey;
  final bool isOnline;
  final DateTime? lastSeen;

  const Contact({
    required this.id,
    required this.userId,
    required this.contactId,
    required this.virtualId,
    required this.username,
    required this.publicKey,
    this.isOnline = false,
    this.lastSeen,
  });

  Contact copyWith({bool? isOnline, DateTime? lastSeen}) => Contact(
        id: id,
        userId: userId,
        contactId: contactId,
        virtualId: virtualId,
        username: username,
        publicKey: publicKey,
        isOnline: isOnline ?? this.isOnline,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        contactId: json['contact_id'] as String,
        virtualId: json['virtual_id'] as String,
        username: json['username'] as String,
        publicKey: json['public_key'] as String,
        lastSeen: json['last_seen'] != null
            ? DateTime.tryParse(json['last_seen'] as String)
            : null,
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'user_id': userId,
        'contact_id': contactId,
        'virtual_id': virtualId,
        'username': username,
        'public_key': publicKey,
        'last_seen': lastSeen?.toIso8601String(),
      };

  factory Contact.fromDbMap(Map<String, dynamic> map) => Contact(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        contactId: map['contact_id'] as String,
        virtualId: map['virtual_id'] as String,
        username: map['username'] as String,
        publicKey: map['public_key'] as String,
        lastSeen: map['last_seen'] != null
            ? DateTime.tryParse(map['last_seen'] as String)
            : null,
      );
}
