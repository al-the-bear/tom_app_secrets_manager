// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Demo vaults on a fake GitHub for the mobile tests: a primary with a key
/// file listing a personal vault `team` and a system vault `fleet`, the
/// phone's token and the primary's key file in a keychain. Demo data only.
library;

import 'dart:convert';

import 'package:tom_core_storage/github.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_core_storage/tom_core_storage.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_github_api/tom_github_api.dart';
import 'package:tom_kdbx_store/tom_kdbx_store.dart' show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_core/tom_secrets_core.dart';

const demoRepo = 'al-the-bear/demo-vaults';
const demoPrimary = 'github:$demoRepo/primary.kdbx';
const demoTeam = 'github:$demoRepo/team.kdbx';
const demoSystem = 'github:$demoRepo/fleet.kdbx';
const demoPassword = 'primary-demo-pw';
const demoToken = 'demo-phone-token';

const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

/// The demo vaults on [server].
final class DemoVaults {
  DemoVaults(this.server);

  final FakeGitHubServer server;
  final keyFile = TomSecretsKeyFile.generate();
  late final primaryCredentials = keyFile.credentials(demoPassword);
  final teamCredentials = Credentials(ProtectedValue.fromString('team-pw'));
  final systemCredentials = Credentials(ProtectedValue.fromString('sys-pw'));

  static KdbxFile vault(
    String name,
    Credentials credentials,
    Map<String, String> entries, {
    TomSecretsVaultKind kind = TomSecretsVaultKind.personal,
  }) {
    final file = tomSecretsNewVault(credentials, name, argon2: _argon2);
    TomSecretsMetadata(store: name, kind: kind).writeTo(file);
    for (final MapEntry(:key, :value) in entries.entries) {
      final entry = KdbxEntry.create(file, file.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue(key))
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('demo'))
        ..setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString(value));
      file.body.rootGroup.addEntry(entry);
    }
    return file;
  }

  TomGitHubStorage storage() => TomGitHubStorage.withClient(
    GitHubApiClient(
      token: 'demo-seed',
      httpClient: server.client,
      baseUrl: FakeGitHubServer.baseUrl,
      minMutativeInterval: Duration.zero,
    ),
    committer: tomSecretsDeviceCommitter('mbp'),
  );

  /// Another device writing [file] to [locator].
  Future<void> put(String locator, KdbxFile file) async {
    final s = storage();
    try {
      String? head;
      try {
        head = await s.headOf(locator);
      } on TomStorageException {
        head = null;
      }
      await s.commit(
        locator,
        TomChangeset.singleFile(await file.save()),
        expectedHead: head,
        message: 'seed',
      );
    } finally {
      s.close();
    }
  }

  /// [locator]'s file on GitHub.
  Future<KdbxFile> fetch(String locator, Credentials credentials) async {
    final s = storage();
    try {
      final (bytes, _) = await TomSecretsVaultUnit.readAtHead(s, locator);
      return await KdbxFormat().read(bytes, credentials);
    } finally {
      s.close();
    }
  }

  /// Writes the three vaults to GitHub.
  Future<void> seed() async {
    server.repo(demoRepo);
    final primary = vault('primary', primaryCredentials, {'Main': 'demo-db'});
    TomSecretsPrimaryVaults(primary, primaryLocator: demoPrimary)
      ..put(
        TomSecretsVaultKeys(name: 'team', locator: demoTeam, password: 'team-pw'),
      )
      ..put(
        TomSecretsVaultKeys(name: 'fleet', locator: demoSystem, password: 'sys-pw'),
      );
    await put(demoPrimary, primary);
    await put(demoTeam, vault('team', teamCredentials, {'Api': 'token-1'}));
    await put(
      demoSystem,
      vault('fleet', systemCredentials, {
        'Db': 'fleet-db',
      }, kind: TomSecretsVaultKind.system),
    );
  }

  /// The phone's token and the primary's key file, as a pairing leaves them.
  Future<void> fillKeychain(TomSecretStore keychain) async {
    await keychain.write(
      tomSecretsGitHubTokenHandle('al-the-bear', 'demo-vaults'),
      demoToken,
    );
    await keychain.write(
      TomSecretsVaultLocator.parse(demoPrimary).keyFileHandle,
      base64.encode(keyFile.toBytes()),
    );
  }
}
