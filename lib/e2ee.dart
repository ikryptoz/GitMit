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
  static const int v1 = 1;
  static const int v2 = 2;

  // Highest supported/advertised E2EE version by this client.
  static const int currentVersion = v2;

  static const String _kPrivKey = 'e2ee_x25519_private_v1';
  static const String _kPubKey = 'e2ee_x25519_public_v1';

  // v2 identity signing (Ed25519)
  static const String _kEdPrivKey = 'e2ee_ed25519_private_v2';
  static const String _kEdPubKey = 'e2ee_ed25519_public_v2';

  // v2 signed prekey (X25519)
  static const String _kSpkPrivKey = 'e2ee_spk_x25519_private_v2';
  static const String _kSpkPubKey = 'e2ee_spk_x25519_public_v2';
  static const String _kSpkIdKey = 'e2ee_spk_id_v2';
  static const String _kSpkSigKey = 'e2ee_spk_sig_v2';

  static const String _kGroupPrefix = 'e2ee_groupkey_v1_';

  // v2 double-ratchet session state per peer.
  static const String _kDrPrefix = 'e2ee_dr_v2_';

  // v2 group sender-key state.
  static const String _kGSendPrefix = 'e2ee_gsender_v2_';
  static const String _kGRecvPrefix = 'e2ee_grecv_v2_';

  static const _storage = FlutterSecureStorage();

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _ed25519 = Ed25519();
  static final _hmacSha256 = Hmac.sha256();

  static final Random _rng = Random.secure();
  static List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _rng.nextInt(256), growable: false);

  static List<int> _concat(List<List<int>> parts) {
    final out = <int>[];
    for (final p in parts) {
      out.addAll(p);
    }
    return out;
  }

  static List<int> _u64(int n) {
    // Big-endian 64-bit.
    final out = List<int>.filled(8, 0, growable: false);
    var x = n;
    for (var i = 7; i >= 0; i--) {
      out[i] = x & 0xff;
      x = x >> 8;
    }
    return out;
  }

  static String _b64(List<int> bytes) => base64UrlEncode(bytes);
  static List<int> _unb64(String s) => base64Url.decode(s);

  static Future<List<int>> _hmac(List<int> key, List<int> data) async {
    final mac = await _hmacSha256.calculateMac(data, secretKey: SecretKey(key));
    return mac.bytes;
  }

  // RFC 5869 HKDF (SHA-256)
  static Future<List<int>> _hkdf({
    required List<int> salt,
    required List<int> ikm,
    required List<int> info,
    required int length,
  }) async {
    final prk = await _hmac(salt, ikm);
    var t = <int>[];
    final okm = <int>[];
    var c = 1;
    while (okm.length < length) {
      final input = <int>[...t, ...info, c & 0xff];
      t = await _hmac(prk, input);
      okm.addAll(t);
      c++;
      if (c > 255) {
        throw E2eeException('E2EE: HKDF length too large');
      }
    }
    return okm.sublist(0, length);
  }

  static Future<({List<int> messageKey, List<int> nextChainKey})> _kdfCk(List<int> chainKey) async {
    final mk = await _hmac(chainKey, const [0x01]);
    final ck = await _hmac(chainKey, const [0x02]);
    return (messageKey: mk, nextChainKey: ck);
  }

  static Future<({List<int> rootKey, List<int> chainKey})> _kdfRk({
    required List<int> rootKey,
    required List<int> dhOut,
    required List<int> info,
  }) async {
    final out = await _hkdf(
      salt: rootKey,
      ikm: dhOut,
      info: info,
      length: 64,
    );
    return (rootKey: out.sublist(0, 32), chainKey: out.sublist(32, 64));
  }

  static List<int> _aadFromHeader(Map<String, Object?> header) {
    // Stable-ish AAD: canonical-ish JSON (sorted keys) to bind header.
    final keys = header.keys.toList()..sort();
    final ordered = <String, Object?>{};
    for (final k in keys) {
      ordered[k] = header[k];
    }
    return utf8.encode(jsonEncode(ordered));
  }

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

  static Future<SimpleKeyPairData> getOrCreateSigningKeyPair() async {
    try {
      final priv = await _storage.read(key: _kEdPrivKey);
      final pub = await _storage.read(key: _kEdPubKey);
      if (priv != null && priv.isNotEmpty && pub != null && pub.isNotEmpty) {
        return SimpleKeyPairData(
          _unb64(priv),
          publicKey: SimplePublicKey(_unb64(pub), type: KeyPairType.ed25519),
          type: KeyPairType.ed25519,
        );
      }

      final kp = await _ed25519.newKeyPair();
      final privBytes = await kp.extractPrivateKeyBytes();
      final pubKey = await kp.extractPublicKey();

      await _storage.write(key: _kEdPrivKey, value: _b64(privBytes));
      await _storage.write(key: _kEdPubKey, value: _b64(pubKey.bytes));

      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubKey.bytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    } catch (e) {
      throw E2eeException('E2EE key storage error: $e');
    }
  }

  static Future<({int spkId, SimpleKeyPairData spk, List<int> signature})> getOrCreateSignedPrekey() async {
    try {
      final priv = await _storage.read(key: _kSpkPrivKey);
      final pub = await _storage.read(key: _kSpkPubKey);
      final idStr = await _storage.read(key: _kSpkIdKey);
      final sigStr = await _storage.read(key: _kSpkSigKey);

      if (priv != null && priv.isNotEmpty && pub != null && pub.isNotEmpty && idStr != null && idStr.isNotEmpty && sigStr != null && sigStr.isNotEmpty) {
        final spkId = int.tryParse(idStr) ?? 0;
        final spkPriv = _unb64(priv);
        final spkPub = _unb64(pub);
        final sig = _unb64(sigStr);
        return (
          spkId: spkId,
          spk: SimpleKeyPairData(
            spkPriv,
            publicKey: SimplePublicKey(spkPub, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          ),
          signature: sig,
        );
      }

      final spk = await _x25519.newKeyPair();
      final spkPriv = await spk.extractPrivateKeyBytes();
      final spkPubKey = await spk.extractPublicKey();
      final spkId = DateTime.now().millisecondsSinceEpoch;

      final signKp = await getOrCreateSigningKeyPair();
      final idKp = await getOrCreateIdentityKeyPair();
      final msg = _concat([
        utf8.encode('gitmit-e2ee-v2-spk'),
        _u64(spkId),
        spkPubKey.bytes,
        idKp.publicKey.bytes,
      ]);
      final sig = await _ed25519.sign(msg, keyPair: signKp);

      await _storage.write(key: _kSpkPrivKey, value: _b64(spkPriv));
      await _storage.write(key: _kSpkPubKey, value: _b64(spkPubKey.bytes));
      await _storage.write(key: _kSpkIdKey, value: spkId.toString());
      await _storage.write(key: _kSpkSigKey, value: _b64(sig.bytes));

      return (
        spkId: spkId,
        spk: SimpleKeyPairData(
          spkPriv,
          publicKey: SimplePublicKey(spkPubKey.bytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        ),
        signature: sig.bytes,
      );
    } catch (e) {
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

    final idKp = await getOrCreateIdentityKeyPair();
    final signKp = await getOrCreateSigningKeyPair();
    final spk = await getOrCreateSignedPrekey();

    await rtdb().ref('users/$uid/e2ee').update({
      'v': currentVersion,
      // Keep legacy field name so v1 clients still work.
      'x25519': _b64(idKp.publicKey.bytes),
      'ed25519': _b64(signKp.publicKey.bytes),
      'spkId': spk.spkId,
      'spkX25519': _b64(spk.spk.publicKey.bytes),
      'spkSig': _b64(spk.signature),
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

  static Future<({
    int version,
    SimplePublicKey? identityX25519,
    SimplePublicKey? identityEd25519,
    int? spkId,
    SimplePublicKey? signedPrekeyX25519,
    List<int>? signedPrekeySig,
  })> fetchUserBundle(String uid) async {
    final snap = await rtdb().ref('users/$uid/e2ee').get();
    final v = snap.value;
    final m = (v is Map) ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    final ver = (m['v'] is int) ? m['v'] as int : int.tryParse((m['v'] ?? '').toString()) ?? v1;

    SimplePublicKey? ix;
    SimplePublicKey? ie;
    SimplePublicKey? spk;
    List<int>? sig;
    int? spkId;

    try {
      final x = (m['x25519'] ?? '').toString().trim();
      if (x.isNotEmpty) ix = SimplePublicKey(_unb64(x), type: KeyPairType.x25519);
    } catch (_) {}
    try {
      final e = (m['ed25519'] ?? '').toString().trim();
      if (e.isNotEmpty) ie = SimplePublicKey(_unb64(e), type: KeyPairType.ed25519);
    } catch (_) {}
    try {
      final id = m['spkId'];
      if (id is int) {
        spkId = id;
      } else {
        spkId = int.tryParse((id ?? '').toString());
      }
    } catch (_) {}
    try {
      final p = (m['spkX25519'] ?? '').toString().trim();
      if (p.isNotEmpty) spk = SimplePublicKey(_unb64(p), type: KeyPairType.x25519);
    } catch (_) {}
    try {
      final s = (m['spkSig'] ?? '').toString().trim();
      if (s.isNotEmpty) sig = _unb64(s);
    } catch (_) {}

    return (
      version: ver,
      identityX25519: ix,
      identityEd25519: ie,
      spkId: spkId,
      signedPrekeyX25519: spk,
      signedPrekeySig: sig,
    );
  }

  static Future<void> _verifySignedPrekey({
    required String uid,
    required SimplePublicKey identityX25519,
    required SimplePublicKey identityEd25519,
    required int spkId,
    required SimplePublicKey signedPrekeyX25519,
    required List<int> signature,
  }) async {
    final msg = _concat([
      utf8.encode('gitmit-e2ee-v2-spk'),
      _u64(spkId),
      signedPrekeyX25519.bytes,
      identityX25519.bytes,
    ]);
    final ok = await _ed25519.verify(
      msg,
      signature: Signature(signature, publicKey: identityEd25519),
    );
    if (!ok) {
      throw E2eeException('E2EE: invalid signed prekey for $uid');
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
    // Try v2 (Signal-like): signed prekeys + double ratchet.
    try {
      final bundle = await fetchUserBundle(otherUid);
      if (bundle.version >= v2 && bundle.identityX25519 != null && bundle.identityEd25519 != null && bundle.spkId != null && bundle.signedPrekeyX25519 != null && bundle.signedPrekeySig != null) {
        return await _encryptForUserV2(
          otherUid: otherUid,
          plaintext: plaintext,
          otherIdentityX25519: bundle.identityX25519!,
          otherIdentityEd25519: bundle.identityEd25519!,
          otherSpkId: bundle.spkId!,
          otherSpkX25519: bundle.signedPrekeyX25519!,
          otherSpkSig: bundle.signedPrekeySig!,
        );
      }
    } catch (_) {
      // Fall back to v1.
    }

    final key = await _sharedKeyWith(otherUid: otherUid);
    final nonce = _randomBytes(12);
    final clearBytes = utf8.encode(plaintext);
    final box = await _aead.encrypt(
      clearBytes,
      secretKey: key,
      nonce: nonce,
    );

    return {
      'e2eeV': v1,
      'alg': 'x25519+chacha20poly1305',
      'nonce': _b64(box.nonce),
      'ciphertext': _b64(box.cipherText),
      'mac': _b64(box.mac.bytes),
    };
  }

  static String _sessionKey(String otherUid) => '$_kDrPrefix$otherUid';

  static Future<_DrState?> _loadSession(String otherUid) async {
    try {
      final s = await _storage.read(key: _sessionKey(otherUid));
      if (s == null || s.isEmpty) return null;
      final m = jsonDecode(s);
      if (m is! Map) return null;
      return _DrState.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveSession(String otherUid, _DrState state) async {
    await _storage.write(key: _sessionKey(otherUid), value: jsonEncode(state.toJson()));
  }

  static Future<List<int>> _dh({required SimpleKeyPairData my, required SimplePublicKey their}) async {
    final shared = await _x25519.sharedSecretKey(keyPair: my, remotePublicKey: their);
    return shared.extractBytes();
  }

  static Future<Map<String, Object?>> _encryptForUserV2({
    required String otherUid,
    required String plaintext,
    required SimplePublicKey otherIdentityX25519,
    required SimplePublicKey otherIdentityEd25519,
    required int otherSpkId,
    required SimplePublicKey otherSpkX25519,
    required List<int> otherSpkSig,
  }) async {
    await _verifySignedPrekey(
      uid: otherUid,
      identityX25519: otherIdentityX25519,
      identityEd25519: otherIdentityEd25519,
      spkId: otherSpkId,
      signedPrekeyX25519: otherSpkX25519,
      signature: otherSpkSig,
    );

    var st = await _loadSession(otherUid);
    if (st == null) {
      // Prekey message init (X3DH-like) + start double ratchet.
      final myIk = await getOrCreateIdentityKeyPair();
      final myDh = await _x25519.newKeyPair();
      final myDhPriv = await myDh.extractPrivateKeyBytes();
      final myDhPub = await myDh.extractPublicKey();

      final dh1 = await _dh(my: myIk, their: otherSpkX25519);
      final dh2 = await _dh(
        my: SimpleKeyPairData(myDhPriv, publicKey: SimplePublicKey(myDhPub.bytes, type: KeyPairType.x25519), type: KeyPairType.x25519),
        their: otherIdentityX25519,
      );
      final dh3 = await _dh(
        my: SimpleKeyPairData(myDhPriv, publicKey: SimplePublicKey(myDhPub.bytes, type: KeyPairType.x25519), type: KeyPairType.x25519),
        their: otherSpkX25519,
      );

      final ikm = _concat([dh1, dh2, dh3]);
      final out = await _hkdf(
        salt: List<int>.filled(32, 0, growable: false),
        ikm: ikm,
        info: utf8.encode('gitmit-x3dh-v2'),
        length: 64,
      );
      final rootKey = out.sublist(0, 32);
      final sendCk = out.sublist(32, 64);
      st = _DrState(
        rootKey: rootKey,
        sendCk: sendCk,
        recvCk: null,
        myDhPriv: myDhPriv,
        myDhPub: myDhPub.bytes,
        theirDhPub: otherSpkX25519.bytes,
        ns: 0,
        nr: 0,
        pn: 0,
        skipped: const {},
      );
    }

    if (st.sendCk == null) {
      // We can only send after we have a send chain.
      // Create one by DH-ratchet using current keys.
      final myDh = st.myDhKeyPair();
      final their = SimplePublicKey(st.theirDhPub, type: KeyPairType.x25519);
      final dhOut = await _dh(my: myDh, their: their);
      final k = await _kdfRk(rootKey: st.rootKey, dhOut: dhOut, info: utf8.encode('gitmit-dr-v2'));
      st = st.copyWith(rootKey: k.rootKey, sendCk: k.chainKey);
    }

    final ck = st.sendCk!;
    final derived = await _kdfCk(ck);
    final msgKey = derived.messageKey;
    final nextCk = derived.nextChainKey;

    final header = <String, Object?>{
      'e2eeV': v2,
      'alg': 'dr-v2',
      'dh': _b64(st.myDhPub),
      'pn': st.pn,
      'n': st.ns,
      if (st.isInit) 'init': true,
      if (st.isInit) 'spkId': otherSpkId,
    };

    final nonce = _randomBytes(12);
    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(msgKey),
      nonce: nonce,
      aad: _aadFromHeader(header),
    );

    final out = <String, Object?>{
      ...header,
      'nonce': _b64(box.nonce),
      'ciphertext': _b64(box.cipherText),
      'mac': _b64(box.mac.bytes),
    };

    // Advance send chain.
    st = st.copyWith(sendCk: nextCk, ns: st.ns + 1, isInit: false);
    await _saveSession(otherUid, st);
    return out;
  }

  static Future<String> decryptFromUser({
    required String otherUid,
    required Map<String, dynamic> message,
  }) async {
    final v = (message['e2eeV'] is int) ? message['e2eeV'] as int : int.tryParse((message['e2eeV'] ?? '').toString()) ?? v1;
    if (v >= v2 || (message['alg'] ?? '').toString().contains('dr-v2')) {
      return _decryptFromUserV2(otherUid: otherUid, message: message);
    }

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

  static Future<String> _decryptFromUserV2({
    required String otherUid,
    required Map<String, dynamic> message,
  }) async {
    final nonceB64 = (message['nonce'] ?? '').toString();
    final ciphertextB64 = (message['ciphertext'] ?? '').toString();
    final macB64 = (message['mac'] ?? '').toString();
    final dhB64 = (message['dh'] ?? '').toString();
    final n = (message['n'] is int) ? message['n'] as int : int.tryParse((message['n'] ?? '').toString()) ?? 0;
    final pn = (message['pn'] is int) ? message['pn'] as int : int.tryParse((message['pn'] ?? '').toString()) ?? 0;
    final isInit = message['init'] == true;
    final spkId = (message['spkId'] is int) ? message['spkId'] as int : int.tryParse((message['spkId'] ?? '').toString());

    if (nonceB64.isEmpty || ciphertextB64.isEmpty || macB64.isEmpty || dhB64.isEmpty) {
      throw E2eeException('E2EE: missing fields');
    }

    final header = <String, Object?>{
      'e2eeV': v2,
      'alg': 'dr-v2',
      'dh': dhB64,
      'pn': pn,
      'n': n,
      if (isInit) 'init': true,
      if (isInit && spkId != null) 'spkId': spkId,
    };

    final dhPub = _unb64(dhB64);
    var st = await _loadSession(otherUid);

    if (st == null || isInit) {
      // Build session from prekey message.
      final myIk = await getOrCreateIdentityKeyPair();
      final mySpk = await getOrCreateSignedPrekey();
      if (spkId != null && mySpk.spkId != spkId) {
        // If we rotated (or something went wrong), we can't decrypt init.
        throw E2eeException('E2EE: signed prekey mismatch');
      }

      final otherBundle = await fetchUserBundle(otherUid);
      final otherIk = otherBundle.identityX25519;
      if (otherIk == null) {
        throw E2eeException('E2EE: other user has no identity key');
      }

      final dh1 = await _dh(my: mySpk.spk, their: otherIk);
      final dh2 = await _dh(my: myIk, their: SimplePublicKey(dhPub, type: KeyPairType.x25519));
      final dh3 = await _dh(my: mySpk.spk, their: SimplePublicKey(dhPub, type: KeyPairType.x25519));

      final ikm = _concat([dh1, dh2, dh3]);
      final out = await _hkdf(
        salt: List<int>.filled(32, 0, growable: false),
        ikm: ikm,
        info: utf8.encode('gitmit-x3dh-v2'),
        length: 64,
      );
      var rootKey = out.sublist(0, 32);
      final recvCk = out.sublist(32, 64);

      // Set DHr = sender's DH, generate DHs and derive send chain.
      final myDhNew = await _x25519.newKeyPair();
      final myDhPriv = await myDhNew.extractPrivateKeyBytes();
      final myDhPub = await myDhNew.extractPublicKey();
      final dhOut = await _dh(
        my: SimpleKeyPairData(myDhPriv, publicKey: SimplePublicKey(myDhPub.bytes, type: KeyPairType.x25519), type: KeyPairType.x25519),
        their: SimplePublicKey(dhPub, type: KeyPairType.x25519),
      );
      final k = await _kdfRk(rootKey: rootKey, dhOut: dhOut, info: utf8.encode('gitmit-dr-v2'));
      rootKey = k.rootKey;
      final sendCk = k.chainKey;

      st = _DrState(
        rootKey: rootKey,
        sendCk: sendCk,
        recvCk: recvCk,
        myDhPriv: myDhPriv,
        myDhPub: myDhPub.bytes,
        theirDhPub: dhPub,
        ns: 0,
        nr: 0,
        pn: 0,
        skipped: const {},
      );
    }

    // DH ratchet if sender changed their DH.
    if (!_bytesEqual(st.theirDhPub, dhPub)) {
      final myDh = st.myDhKeyPair();
      final rk1 = await _kdfRk(
        rootKey: st.rootKey,
        dhOut: await _dh(my: myDh, their: SimplePublicKey(dhPub, type: KeyPairType.x25519)),
        info: utf8.encode('gitmit-dr-v2'),
      );
      var rootKey = rk1.rootKey;
      final recvCk = rk1.chainKey;

      final newMyDh = await _x25519.newKeyPair();
      final newMyDhPriv = await newMyDh.extractPrivateKeyBytes();
      final newMyDhPub = await newMyDh.extractPublicKey();

      final rk2 = await _kdfRk(
        rootKey: rootKey,
        dhOut: await _dh(
          my: SimpleKeyPairData(newMyDhPriv, publicKey: SimplePublicKey(newMyDhPub.bytes, type: KeyPairType.x25519), type: KeyPairType.x25519),
          their: SimplePublicKey(dhPub, type: KeyPairType.x25519),
        ),
        info: utf8.encode('gitmit-dr-v2'),
      );

      st = st.copyWith(
        pn: st.ns,
        ns: 0,
        nr: 0,
        rootKey: rk2.rootKey,
        recvCk: recvCk,
        sendCk: rk2.chainKey,
        myDhPriv: newMyDhPriv,
        myDhPub: newMyDhPub.bytes,
        theirDhPub: dhPub,
      );
    }

    final cacheKey = '${_b64(st.theirDhPub)}:$n';
    final skipped = Map<String, List<int>>.fromEntries(
      st.skipped.entries.map((e) => MapEntry(e.key, _unb64(e.value))),
    );

    List<int>? msgKey;
    var recvCk = st.recvCk;
    var nr = st.nr;

    if (n < nr) {
      msgKey = skipped.remove(cacheKey);
      if (msgKey == null) {
        throw E2eeException('E2EE: duplicate/old message');
      }
    } else {
      if (recvCk == null) {
        throw E2eeException('E2EE: missing receive chain');
      }

      var recvCkBytes = recvCk;

      while (nr < n) {
        final d = await _kdfCk(recvCkBytes);
        skipped['${_b64(st.theirDhPub)}:$nr'] = d.messageKey;
        recvCkBytes = d.nextChainKey;
        nr++;
        if (skipped.length > 50) {
          skipped.remove(skipped.keys.first);
        }
      }

      final d = await _kdfCk(recvCkBytes);
      msgKey = d.messageKey;
      recvCk = d.nextChainKey;
      nr = n + 1;
    }

    final box = SecretBox(
      _unb64(ciphertextB64),
      nonce: _unb64(nonceB64),
      mac: Mac(_unb64(macB64)),
    );

    final clear = await _aead.decrypt(
      box,
      secretKey: SecretKey(msgKey),
      aad: _aadFromHeader(header),
    );

    final newSkipped = <String, String>{};
    for (final e in skipped.entries) {
      newSkipped[e.key] = _b64(e.value);
    }
    st = st.copyWith(recvCk: recvCk, nr: nr, skipped: newSkipped);
    await _saveSession(otherUid, st);
    return utf8.decode(clear);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
      'v': v1,
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
      'e2eeV': v1,
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

  // ----------------
  // Group E2EE (v2): per-sender hash-ratcheted sender key (Signal-like Sender Keys)
  // ----------------

  static String _gSendKey(String groupId, String myUid) => '$_kGSendPrefix$groupId:$myUid';
  static String _gRecvKey(String groupId, String senderUid, String keyId) => '$_kGRecvPrefix$groupId:$senderUid:$keyId';

  static Future<_GroupSenderState?> _loadGroupSenderState({required String groupId, required String myUid}) async {
    try {
      final s = await _storage.read(key: _gSendKey(groupId, myUid));
      if (s == null || s.isEmpty) return null;
      final m = jsonDecode(s);
      if (m is! Map) return null;
      return _GroupSenderState.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveGroupSenderState({required String groupId, required String myUid, required _GroupSenderState st}) async {
    await _storage.write(key: _gSendKey(groupId, myUid), value: jsonEncode(st.toJson()));
  }

  static Future<_GroupRecvState?> _loadGroupRecvState({required String groupId, required String senderUid, required String keyId}) async {
    try {
      final s = await _storage.read(key: _gRecvKey(groupId, senderUid, keyId));
      if (s == null || s.isEmpty) return null;
      final m = jsonDecode(s);
      if (m is! Map) return null;
      return _GroupRecvState.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveGroupRecvState({required String groupId, required String senderUid, required String keyId, required _GroupRecvState st}) async {
    await _storage.write(key: _gRecvKey(groupId, senderUid, keyId), value: jsonEncode(st.toJson()));
  }

  static Future<bool> _groupSupportsV2(String groupId) async {
    final memSnap = await rtdb().ref('groupMembers/$groupId').get();
    final mv = memSnap.value;
    final mm = (mv is Map) ? mv : null;
    if (mm == null || mm.isEmpty) return false;

    for (final entry in mm.entries) {
      if (entry.value == null || entry.value == false) continue;
      final uid = entry.key.toString();
      final snap = await rtdb().ref('users/$uid/e2ee/v').get();
      final vv = snap.value;
      final ver = (vv is int) ? vv : int.tryParse((vv ?? '').toString()) ?? v1;
      if (ver < v2) return false;
    }
    return true;
  }

  static Future<void> _ensureSenderKeyDistributed({
    required String groupId,
    required String myUid,
    required _GroupSenderState st,
  }) async {
    final memSnap = await rtdb().ref('groupMembers/$groupId').get();
    final mv = memSnap.value;
    final mm = (mv is Map) ? mv : null;
    if (mm == null || mm.isEmpty) throw E2eeException('E2EE: group has no members');

    final updates = <String, Object?>{};
    for (final entry in mm.entries) {
      if (entry.value == null || entry.value == false) continue;
      final uid = entry.key.toString();
      // Distribute to everyone including self (simplifies multi-device future).
      final envelope = await encryptForUser(otherUid: uid, plaintext: _b64(st.chainKey));
      updates['groupE2ee/$groupId/senderKeys/$myUid/$uid'] = {
        ...envelope,
        'fromUid': myUid,
        'keyId': st.keyId,
        'createdAt': ServerValue.timestamp,
      };
    }
    updates['groupE2ee/$groupId/senderKeysMeta/$myUid'] = {
      'keyId': st.keyId,
      'updatedAt': ServerValue.timestamp,
    };
    await rtdb().ref().update(updates);
  }

  static Future<Map<String, Object?>?> encryptForGroupSignalLike({
    required String groupId,
    required String myUid,
    required String plaintext,
  }) async {
    // Only use v2 group messages when everyone advertises v2.
    final ok = await _groupSupportsV2(groupId);
    if (!ok) return null;

    var st = await _loadGroupSenderState(groupId: groupId, myUid: myUid);
    if (st == null) {
      st = _GroupSenderState(
        keyId: _b64(_randomBytes(8)),
        chainKey: _randomBytes(32),
        n: 0,
      );
      await _saveGroupSenderState(groupId: groupId, myUid: myUid, st: st);
      await _ensureSenderKeyDistributed(groupId: groupId, myUid: myUid, st: st);
    }

    final derived = await _kdfCk(st.chainKey);
    final msgKey = derived.messageKey;
    final nextCk = derived.nextChainKey;

    final header = <String, Object?>{
      'e2eeV': v2,
      'alg': 'group-sender-v2',
      'keyId': st.keyId,
      'n': st.n,
    };

    final nonce = _randomBytes(12);
    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(msgKey),
      nonce: nonce,
      aad: _aadFromHeader(header),
    );

    final out = <String, Object?>{
      ...header,
      'nonce': _b64(box.nonce),
      'ciphertext': _b64(box.cipherText),
      'mac': _b64(box.mac.bytes),
    };

    st = st.copyWith(chainKey: nextCk, n: st.n + 1);
    await _saveGroupSenderState(groupId: groupId, myUid: myUid, st: st);
    return out;
  }

  static Future<String> decryptGroupMessage({
    required String groupId,
    required String myUid,
    required SecretKey groupKey,
    required Map<String, dynamic> message,
  }) async {
    final v = (message['e2eeV'] is int) ? message['e2eeV'] as int : int.tryParse((message['e2eeV'] ?? '').toString()) ?? v1;
    final alg = (message['alg'] ?? '').toString();
    if (v >= v2 && alg == 'group-sender-v2') {
      return _decryptFromGroupV2(groupId: groupId, myUid: myUid, message: message);
    }
    return decryptFromGroup(groupKey: groupKey, message: message);
  }

  static Future<String> _decryptFromGroupV2({
    required String groupId,
    required String myUid,
    required Map<String, dynamic> message,
  }) async {
    final nonceB64 = (message['nonce'] ?? '').toString();
    final ciphertextB64 = (message['ciphertext'] ?? '').toString();
    final macB64 = (message['mac'] ?? '').toString();
    final keyId = (message['keyId'] ?? '').toString();
    final n = (message['n'] is int) ? message['n'] as int : int.tryParse((message['n'] ?? '').toString()) ?? 0;
    final senderUid = (message['fromUid'] ?? '').toString();
    if (nonceB64.isEmpty || ciphertextB64.isEmpty || macB64.isEmpty || keyId.isEmpty || senderUid.isEmpty) {
      throw E2eeException('E2EE: missing fields');
    }

    var st = await _loadGroupRecvState(groupId: groupId, senderUid: senderUid, keyId: keyId);
    if (st == null) {
      // Fetch wrapped sender key for me.
      final snap = await rtdb().ref('groupE2ee/$groupId/senderKeys/$senderUid/$myUid').get();
      final v = snap.value;
      if (v is! Map) throw E2eeException('E2EE: missing sender key');
      final env = Map<String, dynamic>.from(v);
      final clear = await decryptFromUser(otherUid: senderUid, message: env);
      final ck = _unb64(clear);
      st = _GroupRecvState(chainKey: ck, nr: 0, skipped: const {});
    }

    final header = <String, Object?>{
      'e2eeV': v2,
      'alg': 'group-sender-v2',
      'keyId': keyId,
      'n': n,
    };

    final skipped = Map<String, List<int>>.fromEntries(
      st.skipped.entries.map((e) => MapEntry(e.key, _unb64(e.value))),
    );
    final cacheKey = '$keyId:$n';

    List<int>? msgKey;
    var ck = st.chainKey;
    var nr = st.nr;

    if (n < nr) {
      msgKey = skipped.remove(cacheKey);
      if (msgKey == null) throw E2eeException('E2EE: duplicate/old group message');
    } else {
      while (nr < n) {
        final d = await _kdfCk(ck);
        skipped['$keyId:$nr'] = d.messageKey;
        ck = d.nextChainKey;
        nr++;
        if (skipped.length > 100) skipped.remove(skipped.keys.first);
      }
      final d = await _kdfCk(ck);
      msgKey = d.messageKey;
      ck = d.nextChainKey;
      nr = n + 1;
    }

    final box = SecretBox(
      _unb64(ciphertextB64),
      nonce: _unb64(nonceB64),
      mac: Mac(_unb64(macB64)),
    );
    final clear = await _aead.decrypt(
      box,
      secretKey: SecretKey(msgKey),
      aad: _aadFromHeader(header),
    );

    final newSkipped = <String, String>{};
    for (final e in skipped.entries) {
      newSkipped[e.key] = _b64(e.value);
    }
    await _saveGroupRecvState(
      groupId: groupId,
      senderUid: senderUid,
      keyId: keyId,
      st: st.copyWith(chainKey: ck, nr: nr, skipped: newSkipped),
    );
    return utf8.decode(clear);
  }
}

class _DrState {
  _DrState({
    required this.rootKey,
    required this.sendCk,
    required this.recvCk,
    required this.myDhPriv,
    required this.myDhPub,
    required this.theirDhPub,
    required this.ns,
    required this.nr,
    required this.pn,
    required this.skipped,
    this.isInit = true,
  });

  final List<int> rootKey;
  final List<int>? sendCk;
  final List<int>? recvCk;
  final List<int> myDhPriv;
  final List<int> myDhPub;
  final List<int> theirDhPub;
  final int ns;
  final int nr;
  final int pn;
  final Map<String, String> skipped;
  final bool isInit;

  SimpleKeyPairData myDhKeyPair() => SimpleKeyPairData(
        myDhPriv,
        publicKey: SimplePublicKey(myDhPub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );

  Map<String, Object?> toJson() => {
        'rk': base64UrlEncode(rootKey),
        'sck': sendCk == null ? null : base64UrlEncode(sendCk!),
        'rck': recvCk == null ? null : base64UrlEncode(recvCk!),
        'mdp': base64UrlEncode(myDhPriv),
        'mdq': base64UrlEncode(myDhPub),
        'tdq': base64UrlEncode(theirDhPub),
        'ns': ns,
        'nr': nr,
        'pn': pn,
        'sk': skipped,
        'init': isInit,
      };

  static _DrState fromJson(Map<String, dynamic> m) {
    List<int> unb(String s) => base64Url.decode(s);
    final rk = unb((m['rk'] ?? '').toString());
    final sckS = (m['sck'] ?? '').toString();
    final rckS = (m['rck'] ?? '').toString();
    return _DrState(
      rootKey: rk,
      sendCk: sckS.isEmpty ? null : unb(sckS),
      recvCk: rckS.isEmpty ? null : unb(rckS),
      myDhPriv: unb((m['mdp'] ?? '').toString()),
      myDhPub: unb((m['mdq'] ?? '').toString()),
      theirDhPub: unb((m['tdq'] ?? '').toString()),
      ns: (m['ns'] is int) ? m['ns'] as int : int.tryParse((m['ns'] ?? '').toString()) ?? 0,
      nr: (m['nr'] is int) ? m['nr'] as int : int.tryParse((m['nr'] ?? '').toString()) ?? 0,
      pn: (m['pn'] is int) ? m['pn'] as int : int.tryParse((m['pn'] ?? '').toString()) ?? 0,
      skipped: (m['sk'] is Map) ? Map<String, String>.from(m['sk'] as Map) : <String, String>{},
      isInit: m['init'] == true,
    );
  }

  _DrState copyWith({
    List<int>? rootKey,
    List<int>? sendCk,
    List<int>? recvCk,
    List<int>? myDhPriv,
    List<int>? myDhPub,
    List<int>? theirDhPub,
    int? ns,
    int? nr,
    int? pn,
    Map<String, String>? skipped,
    bool? isInit,
  }) {
    return _DrState(
      rootKey: rootKey ?? this.rootKey,
      sendCk: sendCk ?? this.sendCk,
      recvCk: recvCk ?? this.recvCk,
      myDhPriv: myDhPriv ?? this.myDhPriv,
      myDhPub: myDhPub ?? this.myDhPub,
      theirDhPub: theirDhPub ?? this.theirDhPub,
      ns: ns ?? this.ns,
      nr: nr ?? this.nr,
      pn: pn ?? this.pn,
      skipped: skipped ?? this.skipped,
      isInit: isInit ?? this.isInit,
    );
  }
}

class _GroupSenderState {
  _GroupSenderState({required this.keyId, required this.chainKey, required this.n});

  final String keyId;
  final List<int> chainKey;
  final int n;

  Map<String, Object?> toJson() => {
        'keyId': keyId,
        'ck': base64UrlEncode(chainKey),
        'n': n,
      };

  static _GroupSenderState fromJson(Map<String, dynamic> m) {
    return _GroupSenderState(
      keyId: (m['keyId'] ?? '').toString(),
      chainKey: base64Url.decode((m['ck'] ?? '').toString()),
      n: (m['n'] is int) ? m['n'] as int : int.tryParse((m['n'] ?? '').toString()) ?? 0,
    );
  }

  _GroupSenderState copyWith({String? keyId, List<int>? chainKey, int? n}) => _GroupSenderState(
        keyId: keyId ?? this.keyId,
        chainKey: chainKey ?? this.chainKey,
        n: n ?? this.n,
      );
}

class _GroupRecvState {
  _GroupRecvState({required this.chainKey, required this.nr, required this.skipped});

  final List<int> chainKey;
  final int nr;
  final Map<String, String> skipped;

  Map<String, Object?> toJson() => {
        'ck': base64UrlEncode(chainKey),
        'nr': nr,
        'sk': skipped,
      };

  static _GroupRecvState fromJson(Map<String, dynamic> m) {
    return _GroupRecvState(
      chainKey: base64Url.decode((m['ck'] ?? '').toString()),
      nr: (m['nr'] is int) ? m['nr'] as int : int.tryParse((m['nr'] ?? '').toString()) ?? 0,
      skipped: (m['sk'] is Map) ? Map<String, String>.from(m['sk'] as Map) : <String, String>{},
    );
  }

  _GroupRecvState copyWith({List<int>? chainKey, int? nr, Map<String, String>? skipped}) => _GroupRecvState(
        chainKey: chainKey ?? this.chainKey,
        nr: nr ?? this.nr,
        skipped: skipped ?? this.skipped,
      );
}
