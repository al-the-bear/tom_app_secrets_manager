// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The phone as a device of the guided rotation of the own vaults
/// (part-key-rotation, protocol.md 6.4) against a fake GitHub: at its unlock
/// it takes a further vault's next key (its device record gets the key id,
/// it leaves the record's pending) and the primary's own next key file (into
/// its keychain beside the primary's, `<handle>.next`); after the desktop
/// switched the primary, the phone's refresh and its next unlock open it
/// with that key and keep it as the primary's key file; a phone stopped
/// before the switch opens it at its next start. Demo keys only.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/demo_vaults.dart';

const _phone = 'demo-phone';

void main() {
  late FakeGitHubServer server;
  late TomInMemorySecretStore keychain;
  late DemoVaults demo;
  final handle = TomSecretsVaultLocator.parse(demoPrimary).keyFileHandle;

  setUp(() async {
    server = FakeGitHubServer();
    demo = DemoVaults(server);
    await demo.seed();
    keychain = TomInMemorySecretStore();
    await demo.fillKeychain(keychain);
  });

  /// The phone's engine over [keys] (default the phone's keychain),
  /// unlocked through a connection as the app does.
  Future<TomSecretsMobileEngine> unlock({
    TomInMemorySecretStore? keys,
    String primaryLocator = demoPrimary,
  }) async {
    final engine = TomSecretsMobileEngine(
      primaryLocator: primaryLocator,
      device: _phone,
      platform: 'ios',
      keychain: keys ?? keychain,
      preferences: TomSecretsMemoryPreferences(),
      httpClient: server.client,
      githubBaseUrl: FakeGitHubServer.baseUrl,
    );
    addTearDown(engine.close);
    final connection = TomSecretsServiceConnection(
      TomSecretsMobileServiceHost(engine),
    );
    addTearDown(connection.dispose);
    await connection.connect();
    await connection.unlock(demoPassword);
    return engine;
  }

  /// The desktop editing the primary on GitHub with [change], opened with
  /// [credentials] (default the primary's).
  Future<void> desktop(
    void Function(KdbxFile primary) change, {
    Credentials? credentials,
  }) async {
    final primary = await demo.fetch(
      demoPrimary,
      credentials ?? demo.primaryCredentials,
    );
    change(primary);
    await demo.put(demoPrimary, primary);
  }

  TomSecretsRotation record(String target, String newKeyId) {
    final now = DateTime.now().toUtc();
    return TomSecretsRotation(
      kind: TomSecretsRotationKind.vaultKeys,
      target: target,
      oldKeyId: 'none',
      newKeyId: newKeyId,
      started: now,
      endsAt: now.add(tomSecretsRotationPeriod),
      by: 'mbp',
      pending: const [_phone],
    );
  }

  test('a further vault\'s next key: the phone\'s device record gets its id '
      'at the unlock, and it leaves the pending', () async {
    final next = TomSecretsKeyFile.generate().toBytes();
    final id = TomSecretsKeyFile.parse(next).hash;
    await desktop((p) {
      final list = TomSecretsPrimaryVaults(p, primaryLocator: demoPrimary);
      list.put(list.byName('team')!.copyWith(nextKeyFile: next));
      TomSecretsDeviceRecords(p).put(
        TomSecretsDeviceRecord(
          device: _phone,
          paired: DateTime.utc(2026, 11, 1),
          pairedBy: 'mbp',
        ),
      );
      TomSecretsRotations(p).start(record('team', id));
    });
    expect(
      TomSecretsDeviceRecords(
        await demo.fetch(demoPrimary, demo.primaryCredentials),
      ).missingKey(id).map((r) => r.device),
      [_phone],
    );

    await unlock();
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials);
    final mine = TomSecretsDeviceRecords(primary).byDevice(_phone)!;
    expect(mine.keyIds, contains(id));
    expect(mine.pairedBy, 'mbp');
    expect(TomSecretsDeviceRecords(primary).missingKey(id), isEmpty);
    expect(
      TomSecretsRotations(
        primary,
      ).of(TomSecretsRotationKind.vaultKeys, 'team')!.pending,
      isEmpty,
    );
  });

  test('the primary\'s own next key file: into the keychain at the unlock; '
      'after the desktop switched, the refresh and a new unlock open the '
      'primary with it', () async {
    final next = TomSecretsKeyFile.generate();
    final id = next.hash;
    await desktop((p) {
      TomSecretsPrimaryNextKeys(keyFile: next.toBytes()).writeTo(p);
      TomSecretsRotations(p).start(record('primary', id));
    });

    final engine = await unlock();
    expect(await keychain.read('$handle.next'), base64.encode(next.toBytes()));
    expect(
      TomSecretsDeviceRecords(
        await demo.fetch(demoPrimary, demo.primaryCredentials),
      ).byDevice(_phone)!.keyIds,
      contains(id),
    );

    // The desktop switches: the primary re-keyed with the new key file.
    final newCredentials = next.credentials(demoPassword);
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials)
      ..credentials = newCredentials;
    await demo.put(demoPrimary, primary);

    await engine.refresh(force: true);
    final status = await engine.request('status', const {});
    final stores = (status['stores']! as List).cast<Map>();
    expect(
      stores.firstWhere((s) => s['name'] == 'primary')['state'],
      'current',
    );
    expect(await keychain.read(handle), base64.encode(next.toBytes()));

    // A new unlock with the master password finds the new key file.
    engine.lock();
    await engine.request('unlock', {'password': demoPassword});
    expect(engine.isLocked, isFalse);

    // The finish: the next keys leave the primary, and the phone's keychain.
    await desktop(TomSecretsPrimaryNextKeys.clear, credentials: newCredentials);
    await engine.refresh(force: true);
    expect(await keychain.read('$handle.next'), isNull);
  });

  test('a phone stopped before the switch: its next start opens the '
      're-keyed primary with the key it took', () async {
    final next = TomSecretsKeyFile.generate();
    final kept = TomInMemorySecretStore();
    await demo.fillKeychain(kept);
    await kept.write('$handle.next', base64.encode(next.toBytes()));
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials)
      ..credentials = next.credentials(demoPassword);
    await demo.put(demoPrimary, primary);

    final engine = await unlock(keys: kept);
    expect(engine.isLocked, isFalse);
    expect(await kept.read(handle), base64.encode(next.toBytes()));
  });

  test('the primary\'s repository key rotated alone: the phone takes the '
      'new key up while the old one still reads the two-slot file, and '
      'drops the old one after the finish', () async {
    const tsmx = 'github:$demoRepo/primary.kdbx$tomSecretsOuterSuffix';
    final repoHandle = TomSecretsVaultLocator.parse(tsmx).repositoryKeyHandle;
    final keyHandle = TomSecretsVaultLocator.parse(tsmx).keyFileHandle;
    final oldKey = TomSecretsRepositoryKey.generate().toBase64();
    final newKey = TomSecretsRepositoryKey.generate().toBase64();
    Future<void> write(KdbxFile file, String outerKey) async => demo.putBytes(
      tsmx,
      await tomSecretsEncodeStored(tsmx, file, outerKey: outerKey),
    );
    Future<KdbxFile> read() async => tomSecretsDecodeStored(
      tsmx,
      await demo.fetchStored(tsmx),
      demo.primaryCredentials,
      outerKey: tomSecretsJoinOuterKeys([newKey, oldKey]),
    );
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials);
    await write(primary, oldKey);
    final keys = TomInMemorySecretStore();
    await demo.fillKeychain(keys);
    await keys.write(keyHandle, base64.encode(demo.keyFile.toBytes()));
    await keys.write(repoHandle, oldKey);

    // Prepare: the next repository key in next-keys.
    var p = await read();
    TomSecretsPrimaryNextKeys(outerKey: newKey).writeTo(p);
    await write(p, oldKey);
    final engine = await unlock(keys: keys, primaryLocator: tsmx);
    expect(await keys.read('$repoHandle.next'), newKey);

    // Switch: both slots, the old key named as the one kept.
    p = await read();
    TomSecretsPrimaryNextKeys(
      outerKey: newKey,
      previousOuterKey: oldKey,
    ).writeTo(p);
    await write(p, tomSecretsJoinOuterKeys([newKey, oldKey])!);
    await engine.refresh(force: true);
    expect(await keys.read(repoHandle), newKey);

    // Finish: one slot, the next keys gone.
    p = await read();
    TomSecretsPrimaryNextKeys.clear(p);
    await write(p, newKey);
    await engine.refresh(force: true);
    expect(engine.isLocked, isFalse);
    expect(await keys.read('$repoHandle.next'), isNull);
    final status = await engine.request('status', const {});
    final stores = (status['stores']! as List).cast<Map>();
    expect(
      stores.firstWhere((s) => s['name'] == 'primary')['state'],
      'current',
    );
  });
}
