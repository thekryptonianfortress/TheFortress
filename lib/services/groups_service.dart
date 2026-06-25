import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../data/local/secure_storage.dart';
import '../data/models/group.dart';
import '../data/models/group_message.dart';

class GroupsService {
  Future<Map<String, String>> _headers() async {
    final token = await SecureStorage.getToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  String get _base => AppConstants.serverBaseUrl;

  Future<Group> createGroup({required String name, String? description, String? avatarUrl}) async {
    final res = await http.post(
      Uri.parse('$_base/groups'),
      headers: await _headers(),
      body: jsonEncode({
        'name': name,
        if (description != null) 'description': description,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
      }),
    );
    if (res.statusCode != 200) throw Exception(jsonDecode(res.body)['error'] ?? 'Failed to create group');
    return Group.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<Group>> fetchGroups() async {
    final res = await http.get(Uri.parse('$_base/groups'), headers: await _headers());
    if (res.statusCode != 200) throw Exception('Failed to fetch groups');
    return (jsonDecode(res.body) as List)
        .map((j) => Group.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
  }

  Future<Group> fetchGroup(String groupId) async {
    final res = await http.get(Uri.parse('$_base/groups/$groupId'), headers: await _headers());
    if (res.statusCode != 200) throw Exception('Failed to fetch group');
    return Group.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> joinGroup(String joinCode) async {
    final res = await http.post(
      Uri.parse('$_base/groups/join'),
      headers: await _headers(),
      body: jsonEncode({'join_code': joinCode}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Failed to join group');
    return body;
  }

  Future<void> approveRequest(String groupId, String userId) async {
    final res = await http.put(
      Uri.parse('$_base/groups/$groupId/members/$userId/approve'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to approve request');
  }

  Future<void> rejectRequest(String groupId, String userId) async {
    final res = await http.put(
      Uri.parse('$_base/groups/$groupId/members/$userId/reject'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to reject request');
  }

  Future<void> removeMember(String groupId, String userId) async {
    final res = await http.delete(
      Uri.parse('$_base/groups/$groupId/members/$userId'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to remove member');
  }

  Future<void> promoteToAdmin(String groupId, String userId) async {
    final res = await http.put(
      Uri.parse('$_base/groups/$groupId/promote/$userId'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to promote member');
  }

  Future<List<GroupMessage>> fetchMessages(String groupId, String myId) async {
    final res = await http.get(
      Uri.parse('$_base/groups/$groupId/messages'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to fetch messages');
    return (jsonDecode(res.body) as List)
        .map((j) => GroupMessage.fromJson(Map<String, dynamic>.from(j as Map), myId))
        .toList();
  }

  Future<Group> updateGroup(String groupId, {String? name, String? description, String? avatarUrl, String? themeId}) async {
    final res = await http.put(
      Uri.parse('$_base/groups/$groupId'),
      headers: await _headers(),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (themeId != null) 'theme_id': themeId,
      }),
    );
    if (res.statusCode != 200) throw Exception('Failed to update group');
    return Group.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> deleteGroup(String groupId) async {
    final res = await http.delete(
      Uri.parse('$_base/groups/$groupId'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Failed to delete group');
  }
}
