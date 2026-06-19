class User {
  final String id;
  final String virtualId;
  final String username;
  final String publicKey;
  final DateTime? lastSeen;

  const User({
    required this.id,
    required this.virtualId,
    required this.username,
    required this.publicKey,
    this.lastSeen,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        virtualId: json['virtual_id'] as String,
        username: json['username'] as String,
        publicKey: json['public_key'] as String,
        lastSeen: json['last_seen'] != null
            ? DateTime.tryParse(json['last_seen'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'virtual_id': virtualId,
        'username': username,
        'public_key': publicKey,
        'last_seen': lastSeen?.toIso8601String(),
      };

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'virtual_id': virtualId,
        'username': username,
        'public_key': publicKey,
        'last_seen': lastSeen?.toIso8601String(),
      };

  factory User.fromDbMap(Map<String, dynamic> map) => User(
        id: map['id'] as String,
        virtualId: map['virtual_id'] as String,
        username: map['username'] as String,
        publicKey: map['public_key'] as String,
        lastSeen: map['last_seen'] != null
            ? DateTime.tryParse(map['last_seen'] as String)
            : null,
      );
}
