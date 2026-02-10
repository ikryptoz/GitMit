import 'dart:convert';

import 'package:http/http.dart' as http;

class GithubUser {
  final String login;
  final String avatarUrl;

  const GithubUser({required this.login, required this.avatarUrl});

  factory GithubUser.fromJson(Map<String, dynamic> json) {
    return GithubUser(
      login: (json['login'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
    );
  }
}

Future<List<GithubUser>> searchGithubUsers(String query) async {
  final cleaned = query.trim().replaceFirst(RegExp(r'^@+'), '');
  if (cleaned.isEmpty) return const [];

  final uri = Uri.https('api.github.com', '/search/users', {
    'q': '$cleaned in:login',
    'per_page': '20',
  });

  final res = await http.get(
    uri,
    headers: const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'gitmit',
    },
  );

  if (res.statusCode != 200) {
    throw Exception('GitHub API error: ${res.statusCode}');
  }

  final decoded = jsonDecode(res.body);
  if (decoded is! Map<String, dynamic>) return const [];
  final items = decoded['items'];
  if (items is! List) return const [];

  return items
      .whereType<Map>()
      .map((e) => GithubUser.fromJson(Map<String, dynamic>.from(e)))
      .where((u) => u.login.isNotEmpty)
      .toList(growable: false);
}
