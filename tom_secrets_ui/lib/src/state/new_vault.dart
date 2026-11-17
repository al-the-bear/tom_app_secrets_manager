// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A further vault created beside the primary (part-app, the New vault
/// action of the vault browser, the Environments screen and the Import
/// screen; protocol.md 6.4 `vault.create`): what the user chooses, where the
/// vault goes, and what the creation answers.
library;

import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart';

/// Where a new vault lives.
enum TomSecretsNewVaultPlace {
  /// Beside the primary: in its GitHub repository, or its folder on the disk
  /// (the default).
  besidePrimary,

  /// In another `github:` repository.
  github,

  /// A file on this machine's disk.
  file,
}

/// The key file of a new vault.
enum TomSecretsNewKeyFile {
  /// No key file: the master password alone.
  none,

  /// The primary's key file.
  primary,

  /// A new key file.
  generate,
}

/// What the user chooses for a new vault.
final class TomSecretsNewVaultSpec {
  /// A new vault [name] of [kind]; a system vault serves in [environment]
  /// (its file binding `env=<environment>`). It goes [place]: in
  /// [repository] (`owner/name`, or `owner/name@branch`) for
  /// [TomSecretsNewVaultPlace.github], under [folder] (the folder in the
  /// repository, or the absolute folder on the disk). With [outer] it is a
  /// `.kdbx.tsmx` file under [repositoryKey] (a key the repository already
  /// uses, base64; null: a new one) with [cipher]. Its master password is
  /// [password] (null: one generated and kept in the primary only), its key
  /// file [keyFile]. [githubToken] is the token of another repository the
  /// device keychain does not hold.
  const TomSecretsNewVaultSpec({
    required this.name,
    this.kind = TomSecretsVaultKind.personal,
    this.environment,
    this.purpose,
    this.place = TomSecretsNewVaultPlace.besidePrimary,
    this.repository,
    this.folder,
    this.outer = false,
    this.repositoryKey,
    this.cipher = TomSecretsOuterCipher.xchacha20Poly1305,
    this.password,
    this.keyFile = TomSecretsNewKeyFile.none,
    this.githubToken,
  });

  /// The store name.
  final String name;

  /// What the vault is for.
  final TomSecretsVaultKind kind;

  /// The environment a system vault serves in, or null.
  final String? environment;

  /// Free text shown in the app, or null.
  final String? purpose;

  /// Where it lives.
  final TomSecretsNewVaultPlace place;

  /// The `github:` repository of [TomSecretsNewVaultPlace.github].
  final String? repository;

  /// The folder it goes into, or null (the repository's root; for a file,
  /// required).
  final String? folder;

  /// Whether it is outer encrypted (`.kdbx.tsmx`).
  final bool outer;

  /// A repository key the repository already uses (base64), or null.
  final String? repositoryKey;

  /// The outer cipher.
  final TomSecretsOuterCipher cipher;

  /// The master password, or null (generated).
  final String? password;

  /// The key file.
  final TomSecretsNewKeyFile keyFile;

  /// The token of another repository, or null.
  final String? githubToken;

  /// The file binding the vault's metadata carries.
  Map<String, String> get binding =>
      kind == TomSecretsVaultKind.system &&
          (environment?.trim().isNotEmpty ?? false)
      ? {'env': environment!.trim()}
      : const {};
}

/// A store name (protocol.md 3).
final RegExp tomSecretsStoreNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

/// The locator a new vault of [spec] gets, the primary being at
/// [primaryLocation]. Throws [ArgumentError] for a place that cannot be
/// named (no repository, no folder, a primary that is neither a file nor on
/// GitHub, a name that is no store name).
String tomSecretsNewVaultLocation(
  TomSecretsNewVaultSpec spec,
  String primaryLocation,
) {
  if (!tomSecretsStoreNamePattern.hasMatch(spec.name) ||
      spec.name.length > 64) {
    throw ArgumentError.value(
      spec.name,
      'name',
      'a store name is lower-case letters, digits, - and _',
    );
  }
  final fileName =
      '${spec.name}.kdbx${spec.outer ? tomSecretsOuterSuffix : ''}';
  String inFolder(String prefix, String? folder) {
    final f = (folder ?? '').trim();
    if (f.isEmpty) return '$prefix$fileName';
    final separator = f.contains(r'\') && !f.contains('/') ? r'\' : '/';
    return f.endsWith(separator)
        ? '$prefix$f$fileName'
        : '$prefix$f$separator$fileName';
  }

  final String location;
  switch (spec.place) {
    case TomSecretsNewVaultPlace.besidePrimary:
      final at = primaryLocation.lastIndexOf(RegExp(r'[/\\]'));
      if (at < 0) {
        throw ArgumentError.value(primaryLocation, 'primaryLocation');
      }
      location = '${primaryLocation.substring(0, at + 1)}$fileName';
    case TomSecretsNewVaultPlace.github:
      final repository = (spec.repository ?? '').trim();
      if (!RegExp(
        r'^[A-Za-z0-9-]+/[A-Za-z0-9._-]+(@[^/\s]+)?$',
      ).hasMatch(repository)) {
        throw ArgumentError.value(
          repository,
          'repository',
          'a GitHub repository is owner/name',
        );
      }
      final folder = (spec.folder ?? '').trim().replaceAll(
        RegExp(r'^/+|/+$'),
        '',
      );
      location = inFolder('github:$repository/', folder);
    case TomSecretsNewVaultPlace.file:
      final folder = (spec.folder ?? '').trim();
      if (folder.isEmpty) {
        throw ArgumentError.value(folder, 'folder', 'name the folder');
      }
      location = inFolder('file:', folder);
  }
  // Read back as the service reads it: a location it would refuse is
  // refused here first.
  try {
    TomSecretsVaultLocator.parse(location);
  } on TomSecretsLocatorException catch (e) {
    throw ArgumentError.value(location, 'location', e.message);
  }
  return location;
}

/// What creating a vault did (`vault.create`).
final class TomSecretsVaultCreated {
  /// The result.
  const TomSecretsVaultCreated({
    required this.store,
    required this.location,
    this.keyFile,
    this.repositoryKey,
    this.passwordGenerated = false,
  });

  /// The new vault.
  final String store;

  /// Where it lives.
  final String location;

  /// A new key file made for it (its bytes), for the user's copy; null when
  /// it has none or takes the primary's.
  final Uint8List? keyFile;

  /// A new repository key made for it (base64), for the user's copy; null
  /// when it has no outer encryption or takes a key the repository uses.
  final String? repositoryKey;

  /// Whether its master password was generated (kept in the primary only).
  final bool passwordGenerated;
}
