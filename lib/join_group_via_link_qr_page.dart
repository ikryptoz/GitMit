import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:gitmit/group_invites.dart';
import 'package:gitmit/rtdb.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class JoinGroupViaLinkQrPage extends StatefulWidget {
  const JoinGroupViaLinkQrPage({super.key, this.initialRaw, this.autoJoin = false});

  final String? initialRaw;
  final bool autoJoin;

  @override
  State<JoinGroupViaLinkQrPage> createState() => _JoinGroupViaLinkQrPageState();
}

class _JoinGroupViaLinkQrPageState extends State<JoinGroupViaLinkQrPage> {
  final _ctrl = TextEditingController();
  bool _joining = false;
  bool _autoDone = false;

  @override
  void initState() {
    super.initState();
    if ((widget.initialRaw ?? '').trim().isNotEmpty) {
      _ctrl.text = widget.initialRaw!.trim();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.autoJoin && !_autoDone) {
      _autoDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final raw = _ctrl.text.trim();
        if (raw.isEmpty) return;
        _joinFromRaw(raw);
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _joinFromRaw(String raw) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final parsed = parseGroupInvite(raw);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Neplatná pozvánka.')),
      );
      return;
    }

    setState(() => _joining = true);
    try {
      final gid = parsed.groupId;
      final code = parsed.code;

      final gSnap = await rtdb().ref('groups/$gid').get();
      final gv = gSnap.value;
      final gm = (gv is Map) ? gv : null;
      if (gm == null) {
        throw Exception('Skupina neexistuje.');
      }
      final perms = (gm['permissions'] is Map) ? (gm['permissions'] as Map) : null;
      final enabled = perms?['inviteLinkEnabled'] == true;
      if (!enabled) {
        throw Exception('Pozvánka přes link/QR je vypnutá.');
      }
      final expected = (gm['inviteCode'] ?? '').toString().trim();
      if (expected.isEmpty || expected != code.trim()) {
        throw Exception('Pozvánka je neplatná nebo expirovaná.');
      }

      final existing = await rtdb().ref('groupMembers/$gid/${current.uid}').get();
      if (existing.exists) {
        if (!mounted) return;
        Navigator.of(context).pop(gid);
        return;
      }

      await rtdb().ref().update({
        'groupMembers/$gid/${current.uid}': {
          'role': 'member',
          'joinedAt': ServerValue.timestamp,
          'joinedVia': 'link',
        },
        'userGroups/${current.uid}/$gid': true,
      });

      // Optional: local event for online members.
      await rtdb().ref('groupEvents/$gid').push().set({
        'type': 'member_joined',
        'uid': current.uid,
        'createdAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      Navigator.of(context).pop(gid);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Připojit se do skupiny')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(
              labelText: 'Link / kód pozvánky',
              hintText: 'Vlož link nebo naskenuj QR',
            ),
            minLines: 1,
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _joining ? null : () => _joinFromRaw(_ctrl.text),
                  icon: _joining
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator())
                      : const Icon(Icons.login),
                  label: const Text('Připojit se'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _joining
                ? null
                : () async {
                    final res = await Navigator.of(context).push<String>(
                      MaterialPageRoute(builder: (_) => const ScanQrPage()),
                    );
                    if (res == null || res.trim().isEmpty) return;
                    _ctrl.text = res.trim();
                  },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Skenovat QR'),
          ),
        ],
      ),
    );
  }
}

class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key});

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<ScanQrPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skenovat QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final barcodes = capture.barcodes;
          if (barcodes.isEmpty) return;
          final raw = barcodes.first.rawValue;
          if (raw == null || raw.trim().isEmpty) return;
          _done = true;
          Navigator.of(context).pop(raw.trim());
        },
      ),
    );
  }
}
