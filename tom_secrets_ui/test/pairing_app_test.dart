// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Pairing screen, giving side (part-sharing), against the fake service
/// with a real receiving side over loopback (`tomSecretsReceivePairingAt`;
/// the host's `pairingAllowsLoopback` test switch): the code, addresses and
/// countdown; the bundle chosen arriving (vaults with their keys, the shared
/// configuration, a token pasted for the device); `pair.record`; declined
/// and wrong code; the device list and Revoke. Demo data only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

void main() {
  late FakeService service;
  late TomSecretsHost host;
  late TomSecretsKeyFile keyFile;
  late TomSecretsRepositoryKey repositoryKey;
  late TomSecretsPairingPeerKeys giverKeys;
  late TomSecretsPairingPeerKeys receiverKeys;
  late FakePairingDiscovery lan;

  setUpAll(() async {
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
      linkAddress: '10.8.0.7:47731',
    );
    final receiver = TomSecretsTrust.create('bigbeast');
    receiverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await receiver.linkKey()).publicKey,
      approverKey: (await receiver.approverKey()).publicKey,
      linkAddress: '10.8.0.1:47731',
    );
  });

  setUp(() async {
    lan = FakePairingDiscovery();
    final stores = await demoStores();
    keyFile = TomSecretsKeyFile.generate();
    repositoryKey = TomSecretsRepositoryKey.generate();
    stores[1]
      ..location = 'github:al-the-bear/demo-vaults/team.kdbx.tsmx'
      ..keyFile = keyFile.toBytes()
      ..outerKey = repositoryKey.toBase64();
    service = FakeService(stores)
      ..pairIdentity = {'device': 'mbp', ...giverKeys.toJson()};
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      pairingAddresses: () async => [InternetAddress.loopbackIPv4],
      pairingAllowsLoopback: true,
      pairingDiscovery: lan,
    );
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> pairingScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
    await tester.tap(find.text('Pairing'));
    await wait(tester, 3);
    expect(find.byKey(const Key('tsm-pairing')), findsOneWidget);
  }

  /// Opens the window; answers the code shown and the port.
  Future<(TomSecretsPairingCode, int)> openWindow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tsm-pair-open')));
    await wait(tester, 5);
    final code = TomSecretsPairingCode.parse(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-pair-code')))
          .data!,
    );
    final addresses = tester
        .widget<Text>(find.byKey(const Key('tsm-pair-addresses')))
        .data!;
    final port = int.parse(
      RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(addresses)!.group(1)!,
    );
    expect(find.byKey(const Key('tsm-pair-countdown')), findsOneWidget);
    expect(find.textContaining('Windows Defender'), findsOneWidget);
    // The QR code a phone scans holds the same addresses, port and code.
    final qr = tester.widget<TomSecretsQrCode>(
      find.byKey(const Key('tsm-pair-qr')),
    );
    final invitation = TomSecretsPairingInvitation.parse(qr.data);
    expect(invitation.code.text, code.text);
    expect(invitation.port, port);
    expect(invitation.addresses, contains('127.0.0.1'));
    return (code, port);
  }

  /// A real receiving side, started outside the fake clock.
  Future<Future<TomSecretsPairingReceived>> receive(
    WidgetTester tester,
    TomSecretsPairingCode code,
    int port,
  ) async {
    late Future<TomSecretsPairingReceived> received;
    await tester.runAsync(() async {
      received = tomSecretsReceivePairingAt(
        '127.0.0.1',
        port,
        code: code,
        device: 'bigbeast',
        keysFor: (_, _) async => receiverKeys,
      );
      // Errors are awaited by the test; keep them from escaping meanwhile.
      unawaited(received.then((_) {}, onError: (_) {}));
    });
    return received;
  }

  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await wait(tester, 1);
    }
    expect(finder, findsOneWidget);
  }

  testWidgets('the bundle chosen arrives; pair.record is sent; the device '
      'is listed', (tester) async {
    final primary = service.stores.first
      ..stored = await demoVault('primary', demoPassword, (f) {
        TomSecretsMetadata(
          store: 'primary',
          kind: TomSecretsVaultKind.system,
          configYaml: systemConfig,
        ).writeTo(f);
      });
    primary.revision = tomSecretsBlobId(primary.stored);
    await pairingScreen(tester);
    final (code, port) = await openWindow(tester);
    // Announced on the LAN while the window is open.
    final announced = lan.adverts.single;
    expect(announced.device, 'mbp');
    expect(announced.number, code.number);
    expect(announced.port, port);
    expect(announced.addresses, ['127.0.0.1']);
    expect(find.byKey(const Key('tsm-pair-announced')), findsOneWidget);
    final received = await receive(tester, code, port);
    await until(tester, find.byKey(const Key('tsm-pair-choosing')));
    expect(find.textContaining('bigbeast proved the code'), findsOneWidget);
    expect(find.byKey(const Key('tsm-pair-vault-primary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-pair-vault-team')), findsOneWidget);
    expect(find.byKey(const Key('tsm-pair-config')), findsOneWidget);

    // Without the primary; with the team vault, its keys and a token.
    await tester.tap(find.byKey(const Key('tsm-pair-vault-primary')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-pair-token-al-the-bear/demo-vaults')),
      ' github_pat_demo_for_bigbeast ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-pair-confirm')));
    await until(tester, find.textContaining('bigbeast is paired'));
    expect(lan.adverts, isEmpty, reason: 'no longer announced');

    late TomSecretsPairingReceived got;
    await tester.runAsync(() async => got = await received);
    expect(got.giver, 'mbp');
    final bundle = got.bundle;
    expect(bundle.vaults.map((v) => v.name), ['team']);
    final team = bundle.vaults.single;
    expect(team.locator, 'github:al-the-bear/demo-vaults/team.kdbx.tsmx');
    expect(team.primary, isFalse);
    expect(team.keyFile, keyFile.toBytes());
    expect(team.repositoryKey, repositoryKey.toBase64());
    expect(bundle.configYaml, systemConfig);
    expect(bundle.tokens.single.repository, 'al-the-bear/demo-vaults');
    expect(bundle.tokens.single.token, 'github_pat_demo_for_bigbeast');
    expect(bundle.giverKeys.linkKey.toJson(), giverKeys.linkKey.toJson());
    expect(bundle.giverKeys.approverKey!.keyId, giverKeys.approverKey!.keyId);

    final record = service.pairRecords.single;
    expect(record['device'], 'bigbeast');
    expect(
      Uint8List.fromList(base64.decode(record['tokenKey']! as String)),
      got.tokenKey,
    );
    expect(record['host'], {
      'linkKey': receiverKeys.linkKey.toJson(),
      'address': '10.8.0.1:47731',
    });
    expect(record['approver'], {
      'approverKey': receiverKeys.approverKey!.toJson(),
      'linkKey': receiverKeys.linkKey.toJson(),
    });
    expect(record['record'], {
      'keyIds': [keyFile.hash, repositoryKey.keyIdHex],
    });
    await until(tester, find.byKey(const Key('tsm-paired-bigbeast')));
    expect(find.textContaining(keyFile.hash), findsOneWidget);
  });

  testWidgets('declined: nothing is sent, nothing recorded', (tester) async {
    await pairingScreen(tester);
    final (code, port) = await openWindow(tester);
    final received = await receive(tester, code, port);
    await until(tester, find.byKey(const Key('tsm-pair-choosing')));
    await tester.tap(find.byKey(const Key('tsm-pair-decline')));
    await until(tester, find.textContaining('Declined: nothing was sent.'));
    await tester.runAsync(
      () => expectLater(
        received,
        throwsA(
          isA<TomSecretsPairingException>().having(
            (e) => e.failure,
            'failure',
            TomSecretsPairingFailure.declined,
          ),
        ),
      ),
    );
    expect(service.pairRecords, isEmpty);
  });

  testWidgets('a wrong code closes the window with a message', (tester) async {
    await pairingScreen(tester);
    final (code, port) = await openWindow(tester);
    final [first, second] = code.words;
    final wrong = TomSecretsPairingCode.parse(
      first == second
          ? '${code.number + 1}-$first-$second'
          : '${code.number}-$second-$first',
    );
    final received = await receive(tester, wrong, port);
    await until(tester, find.textContaining('Wrong code'));
    await tester.runAsync(
      () => expectLater(received, throwsA(isA<TomSecretsPairingException>())),
    );
    expect(find.byKey(const Key('tsm-pair-open')), findsOneWidget);
    expect(service.pairRecords, isEmpty);
  });

  testWidgets('the device list and Revoke, the confirmation naming the keys '
      'to rotate', (tester) async {
    service.pairedDevices.add(
      TomSecretsDeviceRecord(
        device: 'legiondary01',
        platform: 'windows',
        paired: DateTime.utc(2026, 11, 2),
        pairedBy: 'mbp',
        keyIds: const ['0a1b2c3d', 'deadbeefcafe'],
        approverKeyId: 'a1b2c3d4',
        approverKeySince: DateTime.utc(2026, 11, 2),
        linkKeySince: DateTime.utc(2026, 11, 2),
      ),
    );
    await pairingScreen(tester);
    expect(find.textContaining('legiondary01 · windows'), findsOneWidget);
    expect(find.textContaining('paired 2026-11-02 by mbp'), findsOneWidget);
    expect(
      find.textContaining('approver key since 2026-11-02'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tsm-paired-revoke-legiondary01')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-paired-revoke')), findsOneWidget);
    expect(
      find.textContaining('the keys 0a1b2c3d, deadbeefcafe'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tsm-paired-revoke-go')));
    await wait(tester, 3);
    expect(service.requests.where((r) => r['op'] == 'pair.revoke').single, {
      'op': 'pair.revoke',
      'device': 'legiondary01',
    });
    expect(find.textContaining('revoked 2026-11-16'), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-paired-revoke-legiondary01')),
      findsNothing,
    );
  });

  testWidgets("a device's GitHub kind in the list, and the revoke says what "
      'cuts it off GitHub (DP-83)', (tester) async {
    service.pairedDevices
      ..add(
        TomSecretsDeviceRecord(
          device: 'phone',
          paired: DateTime.utc(2026, 11, 2),
          githubAuth: TomSecretsGitHubAuth.app,
        ),
      )
      ..add(
        TomSecretsDeviceRecord(
          device: 'bigbeast',
          paired: DateTime.utc(2026, 11, 2),
          githubAuth: TomSecretsGitHubAuth.token,
          githubTokenExpires: DateTime.utc(2027, 2, 1),
        ),
      );
    await pairingScreen(tester);
    expect(
      find.textContaining('GitHub: signed in with the App'),
      findsOneWidget,
    );
    expect(
      find.textContaining('GitHub: a pasted token until 2027-02-01'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tsm-paired-revoke-phone')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('every signed-in device must sign in again'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-paired-revoke-bigbeast')));
    await tester.pumpAndSettle();
    expect(find.textContaining("delete this device's token"), findsOneWidget);
  });

  testWidgets('locking closes the window', (tester) async {
    await pairingScreen(tester);
    final (_, port) = await openWindow(tester);
    await tester.runAsync(() async {
      await service.request('lock');
    });
    await wait(tester, 5);
    expect(find.byKey(const Key('tsm-pairing')), findsNothing);
    expect(lan.adverts, isEmpty, reason: 'the announcement ends too');
    await tester.runAsync(() async {
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
