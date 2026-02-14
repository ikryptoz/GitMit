import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:gitmit/data_usage.dart';

/// Optional GitHub Personal Access Token (PAT).
///
/// Provide it at build/run time via:
/// `--dart-define=GITHUB_TOKEN=...`
const String githubToken = String.fromEnvironment('GITHUB_TOKEN', defaultValue: '');

Map<String, String> githubApiHeaders({
  String accept = 'application/vnd.github+json',
  bool includeAuth = true,
}) {
  final headers = <String, String>{
    'Accept': accept,
    'User-Agent': 'gitmit',
  };

  final token = githubToken.trim();
  if (includeAuth && token.isNotEmpty) {
    // GitHub v3 REST accepts "token <PAT>".
    headers['Authorization'] = 'token $token';
  }
  return headers;
}

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

  final res = await DataUsageTracker.trackedGet(
    uri,
    headers: githubApiHeaders(),
    category: 'api',
  );

  // If token is invalid/expired, gracefully fallback to unauthenticated search
  // so Contacts search still works (with stricter rate limits).
  if ((res.statusCode == 401 || res.statusCode == 403) && githubToken.trim().isNotEmpty) {
    final retry = await DataUsageTracker.trackedGet(
      uri,
      headers: githubApiHeaders(includeAuth: false),
      category: 'api',
    );
    if (retry.statusCode == 200) {
      final decoded = jsonDecode(retry.body);
      if (decoded is! Map<String, dynamic>) return const [];
      final items = decoded['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => GithubUser.fromJson(Map<String, dynamic>.from(e)))
          .where((u) => u.login.isNotEmpty)
          .toList(growable: false);
    }
  }

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

Future<List<dynamic>?> fetchRepoContributors(String owner, String repo) async {
  final url = Uri.https('api.github.com', '/repos/$owner/$repo/contributors');
  final response = await http.get(url, headers: githubApiHeaders());

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    print('[ERROR] Failed to fetch contributors: ${response.statusCode}');
    return null;
  }
}

Future<Map<String, dynamic>?> fetchUserContributionCalendar(String username) async {
  const graphqlEndpoint = 'https://api.github.com/graphql';
  final query = {
    'query': '''
      query {
        user(login: $username) {
          name
          avatarUrl
          contributionsCollection {
            totalContributions
            contributionCalendar {
              days {
                contributionCount
              }
            }
          }
        }
      }
    ''',
  };

  final response = await http.post(Uri.parse(graphqlEndpoint), headers: githubApiHeaders(), body: query);

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    print('[ERROR] Failed to fetch contribution calendar: ${response.statusCode}');
    return null;
  }
}
