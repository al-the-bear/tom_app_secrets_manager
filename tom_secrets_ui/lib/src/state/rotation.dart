// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A key rotation by hand (part-key-rotation): what the user asks to change
/// and what it changed. `TomSecretsSession.rotateKeys` carries it out
/// through the service (DP-13): the new keys into the primary first, then
/// every affected vault saved re-keyed, then the `github:` repositories'
/// history cut (retention 0).
library;

import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart';

/// What becomes of a vault's key file.
enum TomSecretsKeyFileChange {
  /// Kept as it is (or still none).
  keep,

  /// A new key file, replacing the old one or added where there was none.
  renew,

  /// Removed: the vault opens with its master password alone.
  remove,
}

/// The changes a rotation of one vault makes.
final class TomSecretsRotation {
  /// A rotation: a new master password ([password], null keeps it), the key
  /// file [keyFile], a new repository key for a `.tsmx` vault and every
  /// file of its repository under the same key ([newRepositoryKey]), and the
  /// outer cipher the re-encrypted `.tsmx` files get ([cipher], null keeps
  /// each file's).
  const TomSecretsRotation({
    this.password,
    this.keyFile = TomSecretsKeyFileChange.keep,
    this.newRepositoryKey = false,
    this.cipher,
  });

  /// The new master password, or null.
  final String? password;

  /// The key file change.
  final TomSecretsKeyFileChange keyFile;

  /// Whether the repository key is replaced.
  final bool newRepositoryKey;

  /// The outer cipher of the re-encrypted `.tsmx` files, or null.
  final TomSecretsOuterCipher? cipher;

  /// Whether anything changes.
  bool get isEmpty =>
      password == null &&
      keyFile == TomSecretsKeyFileChange.keep &&
      !newRepositoryKey &&
      cipher == null;
}

/// What a rotation did: the new key material to keep copies of (shown once,
/// for the user's recovery copies), the vaults written re-keyed, and the
/// repositories whose history was cut.
final class TomSecretsRotated {
  /// The result.
  const TomSecretsRotated({
    required this.store,
    required this.primary,
    required this.rekeyed,
    this.keyFile,
    this.repositoryKey,
    this.compacted = const [],
    this.compactFailures = const {},
  });

  /// The vault rotated.
  final String store;

  /// The primary's store name (its own key file or repository key reaches
  /// other devices by pairing or by hand).
  final String primary;

  /// The vaults written re-keyed, in order (the primary first when it was).
  final List<String> rekeyed;

  /// The new key file's bytes, or null when none was made.
  final Uint8List? keyFile;

  /// The new repository key (base64), or null when none was made.
  final String? repositoryKey;

  /// The `github:` repositories (`owner/name`) whose history was cut.
  final List<String> compacted;

  /// The repositories whose cut failed, with why: `tsm compact` or the next
  /// rotation cuts them later.
  final Map<String, String> compactFailures;

  /// Whether the primary's own keys changed.
  bool get primaryRekeyed => rekeyed.contains(primary);
}

/// A rotation whose re-keyed save is still to be made: the primary lists
/// [store]'s new keys, the service still holds the old ones.
typedef TomSecretsPendingRotation = ({String store, String location});

/// The repository a vault at [locator] belongs to for a repository-key
/// rotation: `github:<owner>/<name>`, or the folder of a `file:` vault.
String tomSecretsRepositoryOf(String locator) {
  final parsed = TomSecretsVaultLocator.parse(locator);
  return switch (parsed) {
    TomSecretsGitHubLocator() => 'github:${parsed.repositorySlug}',
    TomSecretsFileLocator() => 'file:${_folderOf(parsed.path)}',
    _ => locator,
  };
}

String _folderOf(String path) {
  final i = path.replaceAll(r'\', '/').lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// The `github:` repository slug (`owner/name`) of [locator], or null.
String? tomSecretsGitHubRepositoryOf(String locator) {
  final parsed = TomSecretsVaultLocator.parse(locator);
  return parsed is TomSecretsGitHubLocator ? parsed.repositorySlug : null;
}

/// [from] + [months] calendar months, in UTC.
DateTime tomSecretsAddMonths(DateTime from, int months) {
  final at = from.toUtc();
  return DateTime.utc(at.year, at.month + months, at.day, at.hour, at.minute);
}
