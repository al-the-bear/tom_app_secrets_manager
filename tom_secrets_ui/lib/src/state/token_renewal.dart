// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Renewing a vault repository's GitHub token by hand (part-key-rotation
/// §3): GitHub's new-token page filled in through its template URL, the
/// pasted token handed to the service (`token.set`), and the page where the
/// old token is deleted.
///
/// GitHub's template parameters for a fine-grained token (checked against
/// GitHub's documentation, "Managing your personal access tokens", when this
/// was built): `name` (at most 40 characters), `description` (at most 1024),
/// `target_name` (the user or organisation that owns the repositories),
/// `expires_in` (1 to 366 days, or `none`) and one parameter per permission
/// (`contents=write`, `metadata=read`). The repositories themselves cannot
/// be named in the URL: the user selects them under Repository access.
library;

import 'service_connection.dart';

/// GitHub's page for a new fine-grained token.
const String tomSecretsNewTokenPage =
    'https://github.com/settings/personal-access-tokens/new';

/// GitHub's list of fine-grained tokens, where the old one is deleted.
const String tomSecretsTokenListPage =
    'https://github.com/settings/personal-access-tokens';

/// The expiry lengths offered, in days (GitHub takes 1 to 366).
const List<int> tomSecretsTokenExpiryDays = [30, 60, 90, 180, 366];

/// GitHub's limits on the template parameters.
abstract final class TomSecretsTokenTemplateLimits {
  /// `name`: at most 40 characters.
  static const int name = 40;

  /// `description`: at most 1024 characters.
  static const int description = 1024;

  /// `expires_in`: 1 to 366 days.
  static const int minDays = 1;

  /// `expires_in`: 1 to 366 days.
  static const int maxDays = 366;
}

final RegExp _slug = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$');

/// The new-token page for the vault repositories [repositories]
/// (`owner/name`, one owner) of this machine [device], expiring in
/// [expiresInDays]: name and description say what it is for, the owner is
/// set, and the permissions are those the vaults need (Contents: read and
/// write; Metadata: read). Throws [ArgumentError] for a value GitHub would
/// not take (several owners, an owner that is no slug, an expiry outside
/// 1..366).
Uri tomSecretsNewTokenUrl({
  required List<String> repositories,
  required String device,
  required int expiresInDays,
}) {
  if (repositories.isEmpty) {
    throw ArgumentError.value(repositories, 'repositories', 'none');
  }
  final owners = {for (final r in repositories) r.split('/').first};
  if (owners.length != 1) {
    throw ArgumentError.value(repositories, 'repositories', 'several owners');
  }
  final owner = owners.single;
  if (!_slug.hasMatch(owner)) {
    throw ArgumentError.value(owner, 'owner', 'not a GitHub user or org');
  }
  if (expiresInDays < TomSecretsTokenTemplateLimits.minDays ||
      expiresInDays > TomSecretsTokenTemplateLimits.maxDays) {
    throw ArgumentError.value(expiresInDays, 'expiresInDays', '1..366');
  }
  final names = repositories.map((r) => r.split('/').last).join(', ');
  var name = 'Tom Secrets Manager $device';
  if (name.length > TomSecretsTokenTemplateLimits.name) {
    name = name.substring(0, TomSecretsTokenTemplateLimits.name);
  }
  var description =
      'The Tom Secrets Manager on $device reads and writes its vaults in '
      '${repositories.join(', ')}. Under Repository access choose '
      '"Only select repositories" and select: $names.';
  if (description.length > TomSecretsTokenTemplateLimits.description) {
    description = description.substring(
      0,
      TomSecretsTokenTemplateLimits.description,
    );
  }
  return Uri.parse(tomSecretsNewTokenPage).replace(
    queryParameters: {
      'name': name,
      'description': description,
      'target_name': owner,
      'expires_in': '$expiresInDays',
      'contents': 'write',
      'metadata': 'read',
    },
  );
}

/// What `token.set` answered.
final class TomSecretsTokenRenewed {
  /// The answer for [repository]: kept in [where] (`keychain` or `primary`),
  /// expiring at [expiresAt] (null: no expiry).
  const TomSecretsTokenRenewed({
    required this.repository,
    required this.where,
    this.expiresAt,
  });

  /// The repository (`owner/name`).
  final String repository;

  /// Where the service keeps it: `keychain` or `primary`.
  final String where;

  /// The expiry GitHub reported, or null.
  final DateTime? expiresAt;

  /// The result in words.
  String get description {
    final place = where == 'keychain'
        ? 'this machine\'s keychain'
        : 'the primary vault';
    final until = expiresAt == null
        ? 'it does not expire'
        : 'it expires on ${expiresAt!.toLocal().toIso8601String().substring(0, 10)}';
    return 'The new token for $repository works and is kept in $place; '
        '$until.';
  }
}

/// Hands [token] for [repository] to the service (`token.set`). Throws
/// `TomSecretsAdminException` when the service refuses it.
Future<TomSecretsTokenRenewed> tomSecretsRenewToken(
  TomSecretsServiceConnection connection, {
  required String repository,
  required String token,
}) async {
  final answer = await connection.request('token.set', {
    'repository': repository,
    'token': token,
  });
  final at = answer['expiresAt'];
  return TomSecretsTokenRenewed(
    repository: repository,
    where: answer['where'] as String,
    expiresAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
  );
}
