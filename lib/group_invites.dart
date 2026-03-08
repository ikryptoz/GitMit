import 'dart:math';

class ParsedGroupInvite {
  const ParsedGroupInvite(this.groupId, this.code);

  final String groupId;
  final String code;
}

String generateInviteCode({int length = 12}) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rnd = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
  );
}

const String _groupInviteWebBaseUrl = 'https://github.com/ikryptoz/GitMit';

String buildGroupInviteLink({required String groupId, required String code}) {
  final uri = Uri.parse(_groupInviteWebBaseUrl).replace(
    queryParameters: {
      'join': '1',
      'g': groupId,
      'c': code,
    },
  );
  return uri.toString();
}

/// QR payload for system camera scanners.
///
/// We intentionally use an HTTPS URL so native camera apps recognize it as a
/// clickable web link, even outside GitMit.
String buildGroupInviteQrPayload({required String groupId, required String code}) {
  return buildGroupInviteLink(groupId: groupId, code: code);
}

ParsedGroupInvite? parseGroupInvite(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  final uri = Uri.tryParse(s);
  if (uri != null) {
    final qp = uri.queryParameters;
    final g = (qp['g'] ?? qp['groupId'] ?? '').trim();
    final c = (qp['c'] ?? qp['code'] ?? '').trim();
    if (g.isNotEmpty && c.isNotEmpty) return ParsedGroupInvite(g, c);
  }

  // Accept a compact format for manual paste, e.g. groupId~code
  final m = RegExp(r'^([A-Za-z0-9_-]{6,})[~:|]([A-Za-z0-9]{6,})$').firstMatch(s);
  if (m != null) {
    return ParsedGroupInvite(m.group(1)!, m.group(2)!);
  }
  return null;
}
