import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gitmit/rtdb.dart';
import 'package:http/http.dart' as http;

class DataUsageSnapshot {
  DataUsageSnapshot(this.counters);

  final Map<String, int> counters;

  factory DataUsageSnapshot.empty() => DataUsageSnapshot({});

  factory DataUsageSnapshot.fromJson(Map<String, dynamic> m) {
    final out = <String, int>{};
    for (final e in m.entries) {
      final v = e.value;
      if (v is int) {
        out[e.key] = v;
      } else if (v is num) {
        out[e.key] = v.toInt();
      } else if (v != null) {
        final parsed = int.tryParse(v.toString());
        if (parsed != null) out[e.key] = parsed;
      }
    }
    return DataUsageSnapshot(out);
  }

  Map<String, dynamic> toJson() => counters;

  int _read(String key) => counters[key] ?? 0;

  int networkRx(String net) => _read('net:$net:rx');
  int networkTx(String net) => _read('net:$net:tx');

  int categoryRx(String net, String category) => _read('net:$net:cat:$category:rx');
  int categoryTx(String net, String category) => _read('net:$net:cat:$category:tx');

  int categoryTotal(String net, String category) => categoryRx(net, category) + categoryTx(net, category);

  Map<String, int> categoryTotalsForNetwork(String net, List<String> categories) {
    final out = <String, int>{};
    for (final c in categories) {
      out[c] = categoryTotal(net, c);
    }
    return out;
  }

  int totalRx() => networkRx('total');
  int totalTx() => networkTx('total');

  void add({required String net, required String category, required int rx, required int tx}) {
    _addKey('net:$net:rx', rx);
    _addKey('net:$net:tx', tx);
    _addKey('net:$net:cat:$category:rx', rx);
    _addKey('net:$net:cat:$category:tx', tx);

    if (net != 'total') {
      _addKey('net:total:rx', rx);
      _addKey('net:total:tx', tx);
      _addKey('net:total:cat:$category:rx', rx);
      _addKey('net:total:cat:$category:tx', tx);
    }
  }

  void _addKey(String key, int delta) {
    if (delta <= 0) return;
    counters[key] = (counters[key] ?? 0) + delta;
  }
}

class DataUsagePolicy {
  const DataUsagePolicy({
    required this.allowWifi,
    required this.allowMobile,
    required this.allowRoaming,
    required this.dataSaverEnabled,
  });

  final bool allowWifi;
  final bool allowMobile;
  final bool allowRoaming;
  final bool dataSaverEnabled;

  factory DataUsagePolicy.defaults() => const DataUsagePolicy(
        allowWifi: true,
        allowMobile: true,
        allowRoaming: false,
        dataSaverEnabled: false,
      );
}

class DataUsageTracker {
  static const _storage = FlutterSecureStorage();
  static const _storagePrefix = 'data_usage_v1_';
  static const _policyCacheTtl = Duration(seconds: 30);

  static final _updates = StreamController<DataUsageSnapshot>.broadcast();
  static DataUsageSnapshot _snapshot = DataUsageSnapshot.empty();
  static String? _activeUid;
  static Timer? _flushTimer;
  static DateTime? _lastPolicyFetch;
  static DataUsagePolicy _policy = DataUsagePolicy.defaults();

  static const MethodChannel _networkChannel = MethodChannel('gitmit/network');

  static Stream<DataUsageSnapshot> get stream => _updates.stream;
  static DataUsageSnapshot get snapshot => _snapshot;

  static const List<String> categories = ['api', 'media', 'avatars', 'other'];
  static const List<String> networks = ['total', 'wifi', 'mobile', 'roaming', 'unknown'];

  static Future<void> setActiveUser(String? uid) async {
    final trimmed = (uid ?? '').trim();
    _activeUid = trimmed.isEmpty ? null : trimmed;
    _snapshot = DataUsageSnapshot.empty();
    _lastPolicyFetch = null;
    _policy = DataUsagePolicy.defaults();
    await _load();
    _updates.add(_snapshot);
  }

  static Future<void> reset() async {
    _snapshot = DataUsageSnapshot.empty();
    await _persist();
    _updates.add(_snapshot);
  }

  static Future<void> recordDownload(int bytes, {required String category}) async {
    if (bytes <= 0) return;
    final net = await _currentNetwork();
    _snapshot.add(net: net, category: category, rx: bytes, tx: 0);
    _schedulePersist();
    _updates.add(_snapshot);
  }

  static Future<void> recordUpload(int bytes, {required String category}) async {
    if (bytes <= 0) return;
    final net = await _currentNetwork();
    _snapshot.add(net: net, category: category, rx: 0, tx: bytes);
    _schedulePersist();
    _updates.add(_snapshot);
  }

  static Future<http.Response> trackedGet(
    Uri uri, {
    Map<String, String>? headers,
    required String category,
  }) async {
    final res = await http.get(uri, headers: headers);
    await recordDownload(res.bodyBytes.length, category: category);
    return res;
  }

  static Future<bool> canDownloadMedia() async {
    final policy = await _loadPolicy();
    final net = await _currentNetwork();
    if (policy.dataSaverEnabled && (net == 'mobile' || net == 'roaming')) return false;

    switch (net) {
      case 'wifi':
        return policy.allowWifi;
      case 'mobile':
        return policy.allowMobile;
      case 'roaming':
        return policy.allowRoaming;
      default:
        return false;
    }
  }

  static Future<DataUsagePolicy> _loadPolicy() async {
    final uid = _activeUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return DataUsagePolicy.defaults();

    final now = DateTime.now();
    if (_lastPolicyFetch != null && now.difference(_lastPolicyFetch!) < _policyCacheTtl) {
      return _policy;
    }

    try {
      final snap = await rtdb().ref('settings/$uid').get();
      final v = snap.value;
      final m = (v is Map) ? Map<String, dynamic>.from(v) : <String, dynamic>{};
      final allowWifi = m['dataAllowWifi'] == true;
      final allowMobile = (m['dataAllowMobile'] ?? true) == true;
      final allowRoaming = (m['dataAllowRoaming'] ?? false) == true;
      final saver = (m['dataSaverEnabled'] ?? false) == true;

      _policy = DataUsagePolicy(
        allowWifi: allowWifi,
        allowMobile: allowMobile,
        allowRoaming: allowRoaming,
        dataSaverEnabled: saver,
      );
      _lastPolicyFetch = now;
    } catch (_) {
      // Keep last policy
    }

    return _policy;
  }

  static void _schedulePersist() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(seconds: 1), () {
      _flushTimer = null;
      _persist();
    });
  }

  static Future<void> _persist() async {
    final uid = _activeUid;
    if (uid == null || uid.isEmpty) return;
    try {
      await _storage.write(key: '$_storagePrefix$uid', value: jsonEncode(_snapshot.toJson()));
    } catch (_) {
      // ignore
    }
  }

  static Future<void> _load() async {
    final uid = _activeUid;
    if (uid == null || uid.isEmpty) return;
    try {
      final raw = await _storage.read(key: '$_storagePrefix$uid');
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _snapshot = DataUsageSnapshot.fromJson(decoded);
      }
    } catch (_) {
      // ignore
    }
  }

  static Future<String> _currentNetwork() async {
    final result = await Connectivity().checkConnectivity();
    if (result == ConnectivityResult.wifi || result == ConnectivityResult.ethernet) return 'wifi';
    if (result == ConnectivityResult.mobile) {
      final roaming = await _isRoaming();
      if (roaming == true) return 'roaming';
      return 'mobile';
    }
    return 'unknown';
  }

  static Future<bool?> _isRoaming() async {
    if (kIsWeb) return null;
    if (!Platform.isAndroid) return null;
    try {
      return await _networkChannel.invokeMethod<bool>('isRoaming');
    } catch (_) {
      return null;
    }
  }
}
