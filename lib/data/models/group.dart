class GroupMember {
  final String id;
  final String groupId;
  final String userId;
  final String username;
  final String virtualId;
  final String? avatarUrl;
  final String role;   // 'admin' | 'member'
  final String status; // 'pending' | 'active' | 'banned'
  final DateTime joinedAt;

  const GroupMember({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.username,
    required this.virtualId,
    this.avatarUrl,
    required this.role,
    required this.status,
    required this.joinedAt,
  });

  bool get isAdmin => role == 'admin';
  bool get isActive => status == 'active';
  bool get isPending => status == 'pending';

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        id: j['id'] as String,
        groupId: j['group_id'] as String,
        userId: j['user_id'] as String,
        username: j['username'] as String,
        virtualId: j['virtual_id'] as String,
        avatarUrl: j['avatar_url'] as String?,
        role: j['role'] as String,
        status: j['status'] as String,
        joinedAt: j['joined_at'] != null
            ? DateTime.parse(j['joined_at'] as String)
            : DateTime.now(),
      );
}

class Group {
  final String id;
  final String name;
  final String? description;
  final String? avatarUrl;
  final String joinCode;
  final String createdBy;
  final DateTime createdAt;
  final String myRole;   // 'admin' | 'member'
  final int memberCount;
  final int pendingCount;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final List<GroupMember> members;
  final String? themeId;
  final String? pinnedMessageId;
  final String? pinnedMessageContent;
  final String? pinnedMessageType;

  const Group({
    required this.id,
    required this.name,
    this.description,
    this.avatarUrl,
    required this.joinCode,
    required this.createdBy,
    required this.createdAt,
    required this.myRole,
    required this.memberCount,
    this.pendingCount = 0,
    this.lastMessage,
    this.lastMessageAt,
    this.members = const [],
    this.themeId,
    this.pinnedMessageId,
    this.pinnedMessageContent,
    this.pinnedMessageType,
  });

  bool get isAdmin => myRole == 'admin';

  Group copyWith({
    String? name,
    String? description,
    String? avatarUrl,
    int? memberCount,
    int? pendingCount,
    String? lastMessage,
    DateTime? lastMessageAt,
    List<GroupMember>? members,
    String? themeId,
    Object? pinnedMessageId = _sentinel,
    Object? pinnedMessageContent = _sentinel,
    Object? pinnedMessageType = _sentinel,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        joinCode: joinCode,
        createdBy: createdBy,
        createdAt: createdAt,
        myRole: myRole,
        memberCount: memberCount ?? this.memberCount,
        pendingCount: pendingCount ?? this.pendingCount,
        lastMessage: lastMessage ?? this.lastMessage,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        members: members ?? this.members,
        themeId: themeId ?? this.themeId,
        pinnedMessageId: pinnedMessageId == _sentinel ? this.pinnedMessageId : pinnedMessageId as String?,
        pinnedMessageContent: pinnedMessageContent == _sentinel ? this.pinnedMessageContent : pinnedMessageContent as String?,
        pinnedMessageType: pinnedMessageType == _sentinel ? this.pinnedMessageType : pinnedMessageType as String?,
      );

static const Object _sentinel = Object();

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'name': name,
        'description': description,
        'avatar_url': avatarUrl,
        'join_code': joinCode,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'my_role': myRole,
        'member_count': memberCount,
        'pending_count': pendingCount,
        'last_message': lastMessage,
        'last_message_at': lastMessageAt?.toIso8601String(),
        'theme_id': themeId,
        'pinned_message_id': pinnedMessageId,
        'pinned_message_content': pinnedMessageContent,
        'pinned_message_type': pinnedMessageType,
      };

  factory Group.fromDbMap(Map<String, dynamic> m) => Group(
        id: m['id'] as String,
        name: m['name'] as String,
        description: m['description'] as String?,
        avatarUrl: m['avatar_url'] as String?,
        joinCode: m['join_code'] as String,
        createdBy: m['created_by'] as String,
        createdAt: DateTime.parse(m['created_at'] as String),
        myRole: m['my_role'] as String,
        memberCount: m['member_count'] as int,
        pendingCount: m['pending_count'] as int? ?? 0,
        lastMessage: m['last_message'] as String?,
        lastMessageAt: m['last_message_at'] != null
            ? DateTime.tryParse(m['last_message_at'] as String)
            : null,
        themeId: m['theme_id'] as String?,
        pinnedMessageId: m['pinned_message_id'] as String?,
        pinnedMessageContent: m['pinned_message_content'] as String?,
        pinnedMessageType: m['pinned_message_type'] as String?,
      );

  factory Group.fromJson(Map<String, dynamic> j) {
    final pm = j['pinned_message'] as Map<String, dynamic>?;
    return Group(
      id: j['id'] as String,
      name: j['name'] as String,
      description: j['description'] as String?,
      avatarUrl: j['avatar_url'] as String?,
      joinCode: j['join_code'] as String,
      createdBy: j['created_by'] as String,
      createdAt: DateTime.parse(j['created_at'] as String),
      myRole: j['my_role'] as String? ?? 'member',
      memberCount: int.tryParse('${j['member_count'] ?? 1}') ?? 1,
      pendingCount: int.tryParse('${j['pending_count'] ?? 0}') ?? 0,
      lastMessage: j['last_message'] as String?,
      lastMessageAt: j['last_message_at'] != null
          ? DateTime.tryParse(j['last_message_at'] as String)
          : null,
      themeId: j['theme_id'] as String?,
      pinnedMessageId: pm?['id'] as String? ?? j['pinned_message_id'] as String?,
      pinnedMessageContent: pm?['content'] as String? ?? j['pinned_message_content'] as String?,
      pinnedMessageType: pm?['attachment_type'] as String? ?? j['pinned_message_attachment_type'] as String?,
      members: j['members'] != null
          ? (j['members'] as List)
              .map((m) => GroupMember.fromJson(Map<String, dynamic>.from(m as Map)))
              .toList()
          : [],
    );
  }
}
