import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/contact.dart';
import '../services/signaling_service.dart';
import '../services/sync_service.dart';

class ContactsProvider extends ChangeNotifier {
  final _db = LocalDatabase.instance;
  final _sync = SyncService();
  StreamSubscription<SignalingMessage>? _sub;

  List<Contact> _contacts = [];
  bool _isLoading = false;
  String? _error;

  ContactsProvider(SignalingService signaling) {
    _sub = signaling.stream.listen((msg) {
      if (msg.event == SignalingEvent.contactAutoAdded) {
        _handleAutoAdd(msg.data);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handleAutoAdd(Map<String, dynamic> data) async {
    final myId = await SecureStorage.getUserId();
    if (myId == null) return;
    final contactId = data['contact_id'] as String;
    if (_contacts.any((c) => c.contactId == contactId)) return;
    final contact = Contact(
      id: data['id'] as String,
      userId: myId,
      contactId: contactId,
      virtualId: data['virtual_id'] as String,
      username: data['username'] as String,
      publicKey: data['public_key'] as String? ?? '',
      avatarUrl: data['avatar_url'] as String?,
    );
    await _db.upsertContact(contact);
    _contacts = [..._contacts, contact];
    notifyListeners();
  }

  List<Contact> get contacts => _contacts;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Contact? getById(String contactId) {
    try {
      return _contacts.firstWhere((c) => c.contactId == contactId);
    } catch (_) {
      return null;
    }
  }

  Contact? getByVirtualId(String virtualId) {
    try {
      return _contacts.firstWhere((c) => c.virtualId == virtualId);
    } catch (_) {
      return null;
    }
  }

  Future<void> loadContacts() async {
    final myId = await SecureStorage.getUserId();
    if (myId == null) return;
    _contacts = await _db.getContacts(myId);
    notifyListeners();
    // Then sync from server in background
    await _sync.syncAll();
    _contacts = await _db.getContacts(myId);
    notifyListeners();
  }

  Future<bool> addContact(String virtualId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final contact = await _sync.addContact(virtualId);
      if (contact != null) {
        _contacts = [..._contacts, contact];
        notifyListeners();
        return true;
      }
      _error = 'User not found';
      return false;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> removeContact(String id, String contactDbId) async {
    await _sync.removeContact(contactDbId);
    _contacts.removeWhere((c) => c.id == contactDbId);
    notifyListeners();
  }

  void updatePresence(String userId, bool isOnline, {DateTime? lastSeen}) {
    final idx = _contacts.indexWhere((c) => c.contactId == userId);
    if (idx != -1) {
      _contacts[idx] = _contacts[idx].copyWith(
        isOnline: isOnline,
        lastSeen: !isOnline && lastSeen != null ? lastSeen : _contacts[idx].lastSeen,
      );
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
