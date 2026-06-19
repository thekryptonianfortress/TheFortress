enum CallStatus { missed, completed, rejected, ongoing }
enum CallDirection { incoming, outgoing }

class CallRecord {
  final String id;
  final String callerId;
  final String calleeId;
  final String peerVirtualId;
  final String peerUsername;
  final CallStatus status;
  final CallDirection direction;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? durationSeconds;

  const CallRecord({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.peerVirtualId,
    required this.peerUsername,
    required this.status,
    required this.direction,
    required this.startedAt,
    this.endedAt,
    this.durationSeconds,
  });

  factory CallRecord.fromJson(Map<String, dynamic> json, String myId) => CallRecord(
        id: json['id'] as String,
        callerId: json['caller_id'] as String,
        calleeId: json['callee_id'] as String,
        peerVirtualId: json['peer_virtual_id'] as String,
        peerUsername: json['peer_username'] as String,
        status: CallStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => CallStatus.missed,
        ),
        direction: json['caller_id'] == myId ? CallDirection.outgoing : CallDirection.incoming,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: json['ended_at'] != null ? DateTime.tryParse(json['ended_at'] as String) : null,
        durationSeconds: json['duration_seconds'] as int?,
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'caller_id': callerId,
        'callee_id': calleeId,
        'peer_virtual_id': peerVirtualId,
        'peer_username': peerUsername,
        'status': status.name,
        'direction': direction.name,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'duration_seconds': durationSeconds,
      };

  factory CallRecord.fromDbMap(Map<String, dynamic> map) => CallRecord(
        id: map['id'] as String,
        callerId: map['caller_id'] as String,
        calleeId: map['callee_id'] as String,
        peerVirtualId: map['peer_virtual_id'] as String,
        peerUsername: map['peer_username'] as String,
        status: CallStatus.values.firstWhere((e) => e.name == map['status']),
        direction: CallDirection.values.firstWhere((e) => e.name == map['direction']),
        startedAt: DateTime.parse(map['started_at'] as String),
        endedAt: map['ended_at'] != null ? DateTime.tryParse(map['ended_at'] as String) : null,
        durationSeconds: map['duration_seconds'] as int?,
      );
}
