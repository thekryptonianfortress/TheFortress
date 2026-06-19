import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Handles E2E encryption for messages using X25519 key exchange + AES-256-GCM.
class CryptoUtils {
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();

  /// Generate a new X25519 keypair for a user.
  static Future<Map<String, String>> generateKeypair() async {
    final keyPair = await _x25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

    return {
      'publicKey': base64Encode(publicKey.bytes),
      'privateKey': base64Encode(privateKeyBytes),
    };
  }

  /// Derive shared secret from our private key + their public key.
  static Future<Uint8List> deriveSharedSecret({
    required String ourPrivateKeyB64,
    required String theirPublicKeyB64,
  }) async {
    final privateKeyBytes = base64Decode(ourPrivateKeyB64);
    final publicKeyBytes = base64Decode(theirPublicKeyB64);

    final keyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
    final theirPublicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: theirPublicKey,
    );
    return Uint8List.fromList(await sharedSecret.extractBytes());
  }

  /// Encrypt a plaintext message using AES-256-GCM.
  /// Returns base64(ciphertext) and base64(nonce) separately.
  static Future<Map<String, String>> encryptMessage({
    required String plaintext,
    required Uint8List sharedSecret,
  }) async {
    final secretKey = SecretKey(sharedSecret);
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    return {
      'ciphertext': base64Encode(secretBox.cipherText + secretBox.mac.bytes),
      'nonce': base64Encode(secretBox.nonce),
    };
  }

  /// Decrypt a message using AES-256-GCM.
  static Future<String> decryptMessage({
    required String ciphertextB64,
    required String nonceB64,
    required Uint8List sharedSecret,
  }) async {
    final secretKey = SecretKey(sharedSecret);
    final combined = base64Decode(ciphertextB64);
    final cipherText = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final nonce = base64Decode(nonceB64);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );
    final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    return utf8.decode(plainBytes);
  }
}
