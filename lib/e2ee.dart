import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitmit/rtdb.dart';

class E2eeException implements Exception {
  E2eeException(this.message);
  final String message;

  @override
  String toString() => message;
}

class E2ee {
  static const int version = 1;

  static const String _kPrivKey = 'e2ee_x25519_private_v1';
  static const String _kPubKey = 'e2ee_x25519_public_v1';

  static const String _kGroupPrefix = 'e2ee_groupkey_v1_';

  static const _storage = FlutterSecureStorage();

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();

  static final Random _rng = Random.secure();
  static List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _rng.nextInt(256), growable: false);

  static String _b64(List<int> bytes) => base64UrlEncode(bytes);
  static List<int> _unb64(String s) => base64Url.decode(s);

  static Future<SimpleKeyPairData> getOrCreateIdentityKeyPair() async {
    try {
      final priv = await _storage.read(key: _kPrivKey);
      final pub = await _storage.read(key: _kPubKey);
      if (priv != null && priv.isNotEmpty && pub != null && pub.isNotEmpty) {
        final privBytes = _unb64(priv);
        final pubBytes = _unb64(pub);
        return SimpleKeyPairData(
          privBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );
      }

      final kp = await _x25519.newKeyPair();
      final privBytes = await kp.extractPrivateKeyBytes();
      final pubKey = await kp.extractPublicKey();

      await _storage.write(key: _kPrivKey, value: _b64(privBytes));
      await _storage.write(key: _kPubKey, value: _b64(pubKey.bytes));

      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubKey.bytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    } catch (e) {
      // flutter_secure_storage may throw MissingPluginException in unsupported contexts.
      throw E2eeException('E2EE key storage error: $e');
    }
  }

  static Future<SimplePublicKey> getMyPublicKey() async {
    final kp = await getOrCreateIdentityKeyPair();
    return kp.publicKey;
  }

  static Future<void> publishMyPublicKey({required String uid}) async {
    // Avoid crashing the app in tests/web.
    if (kIsWeb) return;

    final pub = await getMyPublicKey();
    await rtdb().ref('users/$uid/e2ee').update({
      'v': version,
      'x25519': _b64(pub.bytes),
      'updatedAt': ServerValue.timestamp,
    });
  }

  static Future<SimplePublicKey?> fetchUserPublicKey(String uid) async {
    final snap = await rtdb().ref('users/$uid/e2ee/x25519').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    try {
      return SimplePublicKey(_unb64(s), type: KeyPairType.x25519);
    } catch (_) {
      return null;
    }
  }

  static Future<SecretKey> _sharedKeyWith({required String otherUid}) async {
    final myKp = await getOrCreateIdentityKeyPair();
    final otherPub = await fetchUserPublicKey(otherUid);
    if (otherPub == null) {
      throw E2eeException('E2EE: other user has no public key');
    }

    final shared = await _x25519.sharedSecretKey(
      keyPair: myKp,
      remotePublicKey: otherPub,
    );
    // X25519 shared secret is already suitable as 32-byte key material.
    final bytes = await shared.extractBytes();
    return SecretKey(bytes);
  }

  static Future<Map<String, Object?>> encryptForUser({
    required String otherUid,
    required String plaintext,
  }) async {
    final key = await _sharedKeyWith(otherUid: otherUid);
    final nonce = _randomBytes(12);
    final clearBytes = utf8.encode(plaintext);
    final box = await _aead.encrypt(
      clearBytes,
      secretKey: key,
      nonce: nonce,
    );

    return {
      'e2eeV': version,
      'alg': 'x25519+chacha20poly1305',
      'nonce': _b64(box.nonce),
      'ciphertext': _b64(box.cipherText),
      'mac': _b64(box.mac.bytes),
    };
  }

  static Future<String> decryptFromUser({
    required String otherUid,
    required Map<String, dynamic> message,
  }) async {
    final nonce = (message['nonce'] ?? '').toString();
    final ciphertext = (message['ciphertext'] ?? '').toString();
    final mac = (message['mac'] ?? '').toString();
    if (nonce.isEmpty || ciphertext.isEmpty || mac.isEmpty) {
      throw E2eeException('E2EE: missing fields');
    }

    final key = await _sharedKeyWith(otherUid: otherUid);

    final box = SecretBox(
      _unb64(ciphertext),
      nonce: _unb64(nonce),
      mac: Mac(_unb64(mac)),
    );

    final clearBytes = await _aead.decrypt(
      box,
      secretKey: key,
    );
    return utf8.decode(clearBytes);
  }

  // ----------------
  // Group E2EE (v1)
  // ----------------

  static Future<SecretKey?> getLocalGroupKey(String groupId) async {
    try {
      final s = await _storage.read(key: '$_kGroupPrefix$groupId');
      if (s == null || s.isEmpty) return null;
      return SecretKey(_unb64(s));
    } catch (e) {
      throw E2eeException('E2EE group key storage error: $e');
    }
  }

  static Future<void> _saveLocalGroupKey(String groupId, SecretKey key) async {
    final bytes = await key.extractBytes();
    await _storage.write(key: '$_kGroupPrefix$groupId', value: _b64(bytes));
  }

  static Future<SecretKey?> fetchGroupKey({
    required String groupId,
    required String myUid,
  }) async {
    final local = await getLocalGroupKey(groupId);
    if (local != null) return local;

    final snap = await rtdb().ref('groupE2ee/$groupId/keys/$myUid').get();
    final v = snap.value;
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    final fromUid = (m['fromUid'] ?? '').toString();
    if (fromUid.isEmpty) return null;

    final clear = await decryptFromUser(otherUid: fromUid, message: m);
    // group key is stored as base64Url string of raw bytes
    final keyBytes = _unb64(clear);
    final key = SecretKey(keyBytes);
    await _saveLocalGroupKey(groupId, key);
    return key;
  }

  static Future<void> ensureGroupKeyDistributed({
    required String groupId,
    required String myUid,
  }) async {
    // Generate new 32-byte key.
    final keyBytes = _randomBytes(32);
    final groupKey = SecretKey(keyBytes);

    // Load members.
    final memSnap = await rtdb().ref('groupMembers/$groupId').get();
    final mv = memSnap.value;
    final mm = (mv is Map) ? mv : null;
    if (mm == null || mm.isEmpty) {
      throw E2eeException('E2EE: group has no members');
    }

    // Ensure we have our public key published.
    await publishMyPublicKey(uid: myUid);

    final updates = <String, Object?>{};
    final wrapped = _b64(keyBytes);

    for (final entry in mm.entries) {
      final uid = entry.key.toString();
      // Skip removed/falsey members
      if (entry.value == null || entry.value == false) continue;

      final pub = await fetchUserPublicKey(uid);
      if (pub == null) {
        // If a member has no key, we cannot do E2EE for the whole group.
        throw E2eeException('E2EE: member $uid has no public key');
      }

      final envelope = await encryptForUser(otherUid: uid, plaintext: wrapped);
      updates['groupE2ee/$groupId/keys/$uid'] = {
        ...envelope,
        'fromUid': myUid,
        'rotatedAt': ServerValue.timestamp,
      };
    }

    updates['groupE2ee/$groupId/meta'] = {
      'v': version,
      'rotatedAt': ServerValue.timestamp,
      'rotatedByUid': myUid,
    };

    await rtdb().ref().update(updates);
    await _saveLocalGroupKey(groupId, groupKey);
  }

  static Future<Map<String, Object?>> encryptForGroup({
    required SecretKey groupKey,
    required String plaintext,
  }) async {
    final nonce = _randomBytes(12);
    final clearBytes = utf8.encode(plaintext);
    final box = await _aead.encrypt(
      clearBytes,
      secretKey: groupKey,
      nonce: nonce,
    );

    return {
      'e2eeV': version,
      'alg': 'group+chacha20poly1305',
      'nonce': _b64(box.nonce),
      'ciphertext': _b64(box.cipherText),
      'mac': _b64(box.mac.bytes),
    };
  }

  static Future<String> decryptFromGroup({
    required SecretKey groupKey,
    required Map<String, dynamic> message,
  }) async {
    final nonce = (message['nonce'] ?? '').toString();
    final ciphertext = (message['ciphertext'] ?? '').toString();
    final mac = (message['mac'] ?? '').toString();
    if (nonce.isEmpty || ciphertext.isEmpty || mac.isEmpty) {
      throw E2eeException('E2EE: missing fields');
    }

    final box = SecretBox(
      _unb64(ciphertext),
      nonce: _unb64(nonce),
      mac: Mac(_unb64(mac)),
    );

    final clearBytes = await _aead.decrypt(
      box,
      secretKey: groupKey,
    );
    return utf8.decode(clearBytes);
  }
}
