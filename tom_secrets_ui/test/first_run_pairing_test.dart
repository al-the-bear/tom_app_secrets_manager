// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A new desktop set up by pairing (part-sharing, First run "Pair with
/// another desktop") against a giving `TomSecretsPairingWindow` on loopback
/// and the fake service: the protection step left out, nothing stored
/// before the setup, the machine set up from the bundle (the primary's key
/// file and the further vault's repository key and token in the keychain,
/// the trust material with the giving device recorded, `bootstrap.yaml`),
/// the service started and unlocked; a wrong code told; the last step's
/// "Pair another desktop" opening the Pairing screen. Demo data only.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart' show TomInMemorySecretStore;
import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

Directory _scratch() {
  final root = Directory('.dart_tool/first_run_pairing_test')
    ..createSync(recursive: true);
  final dir = root.createTempSync('run');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return Directory(dir.absolute.path);
}

void main() {
  late Directory dir;
  late TomInMemorySecretStore keychain;
  late TomSecretsFirstRun firstRun;
  late FakeService service;
  late FakeHost host;
  late TomSecretsServiceConnection connection;
  late TomSecretsKeyFile keyFile;
  late TomSecretsRepositoryKey teamKey;
  late TomSecretsPairingPeerKeys giverKeys;
  late String primaryPath;

  Future<void> prepare() async {
    dir = _scratch();
    keychain = TomInMemorySecretStore();
    firstRun = TomSecretsFirstRun(
      dataDirectory: '${dir.path}/data',
      keychain: keychain,
      argon2: _argon2,
    );
    service = FakeService(await demoStores(), locked: true);
    host = FakeHost(service, running: false, setup: firstRun);
    connection = TomSecretsServiceConnection(host);
    keyFile = TomSecretsKeyFile.generate();
    teamKey = TomSecretsRepositoryKey.generate();
    primaryPath = '${dir.path}/primary.kdbx';
    File(primaryPath).writeAsBytesSync(
      await tomSecretsNewVault(
        tomSecretsVaultCredentials(
          password: demoPassword,
          keyFile: keyFile.toBytes(),
        ),
        'primary',
        argon2: _argon2,
      ).save(),
    );
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
      linkAddress: '10.8.0.7:47731',
    );
  }

  Future<(TomSecretsPairingWindow, TomSecretsPairingCode)> window() async {
    final code = TomSecretsPairingCode.generate();
    final w = await TomSecretsPairingWindow.open(
      addresses: [InternetAddress.loopbackIPv4],
      allowLoopback: true,
      code: code,
      device: 'mbp',
      bundleFor: (_) async => TomSecretsPairingBundle(
        vaults: [
          TomSecretsPairingVault(
            name: 'primary',
            locator: 'file:$primaryPath',
            primary: true,
            keyFile: keyFile.toBytes(),
          ),
          TomSecretsPairingVault(
            name: 'team',
            locator: 'github:al-the-bear/demo-vaults/team.kdbx.tsmx',
            primary: false,
            repositoryKey: teamKey.toBase64(),
          ),
        ],
        giverKeys: giverKeys,
        tokens: const [
          TomSecretsPairingToken(
            repository: 'al-the-bear/demo-vaults',
            token: 'github_pat_demo_for_this_desktop',
          ),
        ],
      ),
    );
    return (w, code);
  }

  /// What the setup wrote, checked: the keys in the keychain, the giver in
  /// the trust material, the bootstrap.
  Future<void> expectSetUp(String device) async {
    final primary = TomSecretsVaultLocator.parse('file:$primaryPath');
    final team =
        TomSecretsVaultLocator.parse(
              'github:al-the-bear/demo-vaults/team.kdbx.tsmx',
            )
            as TomSecretsGitHubLocator;
    expect(await keychain.read(primary.keyFileHandle), isNotNull);
    expect(await keychain.read(team.repositoryKeyHandle), teamKey.toBase64());
    expect(
      await keychain.read(team.tokenHandle),
      'github_pat_demo_for_this_desktop',
    );
    final bootstrap = File(firstRun.bootstrapPath).readAsStringSync();
    expect(bootstrap, contains('primary: "file:$primaryPath"'));
    final container = await TomSecretsDeviceContainer.open(
      firstRun.deviceContainerPath,
      (await keychain.read('tsm.device-settings.$device'))!,
    );
    final trust = await container.trust(device);
    expect(trust.approvers.single.device, 'mbp');
    expect(
      trust.approvers.single.approverKey.keyId,
      giverKeys.approverKey!.keyId,
    );
    expect(trust.hosts.single.address, '10.8.0.7:47731');
  }

  test('the model: received, nothing stored; the protection step left out; '
      'set up from the bundle, the service started and unlocked', () async {
    await prepare();
    await connection.connect();
    final m = TomSecretsFirstRunModel(
      firstRun: firstRun,
      connection: connection,
    );
    m
      ..byPairing = true
      ..host = 'newdesk';
    expect(m.blocker, contains('Receive the pairing'));
    final (w, code) = await window();
    m
      ..pairAddress = '127.0.0.1:${w.port}'
      ..pairCode = code.text;
    await m.receive();
    expect(m.error, isNull);
    expect((await w.result).receiver, 'newdesk');
    expect(m.receipt!.giver, 'mbp');
    expect(Directory(firstRun.dataDirectory).existsSync(), isFalse);
    expect(m.blocker, 'Type the master password.');
    m.password = demoPassword;
    m.next();
    expect(m.step, TomSecretsFirstRunStep.machine, reason: 'no protection');
    m.back();
    expect(m.step, TomSecretsFirstRunStep.primary);
    m
      ..next()
      ..deviceKey = TomSecretsDeviceKeyMode.keychain;
    await m.setUp();
    expect(m.error, isNull);
    expect(m.step, TomSecretsFirstRunStep.done);
    expect(m.primaryLocatorText, 'file:$primaryPath');
    await expectSetUp('newdesk');
    expect(host.starts, 1);
    expect(connection.locked, isFalse);
  });

  test('the model: a wrong code is told; nothing is received', () async {
    await prepare();
    final m = TomSecretsFirstRunModel(
      firstRun: firstRun,
      connection: connection,
    )..byPairing = true;
    final (w, code) = await window();
    final failed = expectLater(
      w.result,
      throwsA(isA<TomSecretsPairingException>()),
    );
    final [first, second] = code.words;
    m
      ..pairAddress = '127.0.0.1:${w.port}'
      ..pairCode = first == second
          ? '${code.number == 999 ? 1 : code.number + 1}-$first-$second'
          : '${code.number}-$second-$first';
    await m.receive();
    await failed;
    expect(m.error, startsWith('Wrong code'));
    expect(m.receipt, isNull);
    m.pairAddress = 'no port';
    await m.receive();
    expect(m.error, contains('host:port'));
  });

  testWidgets('the wizard: Pair with another desktop, then the last step '
      'opens the Pairing screen', (tester) async {
    await tester.runAsync(prepare);
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomSecretsApp(
        host: TomSecretsHost(
          service: host,
          preferences: TomSecretsMemoryPreferences(),
          firstRunActions: {
            TomSecretsFirstRunActions.pair: tomSecretsShowPairing,
          },
        ),
      ),
    );
    Future<void> settle([int rounds = 5]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    await settle();
    await tester.tap(find.byKey(const Key('tsm-fr-pair')));
    await tester.pump();
    final (w, code) = (await tester.runAsync(window))!;
    await tester.enterText(
      find.byKey(const Key('tsm-fr-pair-address')),
      '127.0.0.1:${w.port}',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-fr-pair-code')),
      code.text,
    );
    await tester.enterText(
      find.byKey(const Key('tsm-fr-pair-host')),
      'newdesk',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-fr-pair-receive')));
    for (
      var i = 0;
      i < 50 &&
          find.byKey(const Key('tsm-fr-pair-received')).evaluate().isEmpty;
      i++
    ) {
      await settle(1);
    }
    expect(find.textContaining('Paired with mbp'), findsOneWidget);
    expect(
      find.textContaining('a GitHub token for al-the-bear/demo-vaults'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('tsm-fr-pair-password')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-fr-next')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-fr-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-fr-setup')));
    await settle(30);
    expect(find.textContaining('set up by pairing with mbp'), findsOneWidget);
    await tester.runAsync(() => expectSetUp('newdesk'));

    await tester.tap(find.byKey(const Key('tsm-fr-offer-pair')));
    await settle(5);
    expect(find.byKey(const Key('tsm-pairing')), findsOneWidget);
    expect(find.byKey(const Key('tsm-pair-open')), findsOneWidget);
  });
}
