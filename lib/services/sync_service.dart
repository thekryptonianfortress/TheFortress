import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/contact.dart';

/// Downloads and caches data needed for offline operation:
///   - Contact list with public keys
///   - TURN server credentials
class SyncService {
  final LocalDatabase _db = LocalDatabase.instance;

  Future<void> syncAll() async {
    await Future.wait([
      _syncContacts(),
      _syncTurnCredentials(),
    ]);
  }

  Future<void> _syncContacts() async {
    final token = await SecureStorage.getToken();
    final myId = await SecureStorage.getUserId();
    if (token == null || myId == null) return;

    try {
      final res = await http.get(
        Uri.parse('${AppConstants.serverBaseUrl}/contacts'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) return;

      final list = jsonDecode(res.body) as List;
      for (final json in list) {
        final contact = Contact.fromJson(json as Map<String, dynamic>);
        await _db.upsertContact(contact);
      }
    } catch (_) {
      // Offline — use cached contacts
    }
  }

  Future<void> _syncTurnCredentials() async {
    final token = await SecureStorage.getToken();
    if (token == null) return;

    try {
      final res = await http.get(
        Uri.parse('${AppConstants.serverBaseUrl}/turn-credentials'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AppConstants.iceServersCacheKey,
        jsonEncode(data['ice_servers']),
      );
      // Cache for 12 hours
      await prefs.setInt(
        AppConstants.iceServersCacheExpiryKey,
        DateTime.now().add(const Duration(hours: 12)).millisecondsSinceEpoch,
      );
    } catch (_) {
      // Offline — previously cached credentials will be used
    }
  }

  /// Lookup a user by virtual ID (with local cache fallback).
  Future<Map<String, dynamic>?> lookupUser(String virtualId) async {
    final token = await SecureStorage.getToken();
    if (token == null) return null;

    try {
      final res = await http.get(
        Uri.parse('${AppConstants.serverBaseUrl}/users/$virtualId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Add a contact on server and cache locally.
  Future<Contact?> addContact(String virtualId) async {
    final token = await SecureStorage.getToken();
    final myId = await SecureStorage.getUserId();
    if (token == null || myId == null) return null;

    final res = await http.post(
      Uri.parse('${AppConstants.serverBaseUrl}/contacts'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'virtual_id': virtualId}),
    );

    if (res.statusCode != 201) {
      final body = jsonDecode(res.body);
      throw Exception(body['error'] ?? 'Failed to add contact');
    }

    final contact = Contact.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    await _db.upsertContact(contact);
    return contact;
  }

  Future<void> removeContact(String contactDbId) async {
    final token = await SecureStorage.getToken();
    if (token == null) return;
    await http.delete(
      Uri.parse('${AppConstants.serverBaseUrl}/contacts/$contactDbId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    await _db.deleteContact(contactDbId);
  }
}
