// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The relays in the app (part-relay) against the fake service: the relay
/// settings (the list in order, each kind's services, the pairing default);
/// the pairing QR code naming the relay; the Pairing screen's window also
/// waiting on a GitHub repository through the service's `relay.*` requests
/// (`tomSecretsAppRelay`, `TomSecretsAdminRelayFolder`), its code built
/// from the nameplate, a new machine pairing through the same repository;
/// a relay that cannot host said, the window open on the LAN; the First
/// run receiving through the relay with this machine's own token, after the
/// LAN when an address is typed; failures naming the relay. Demo data only.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_core_storage/settings.dart' show TomInMemorySecretStore;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

/// The repository's files as a relay folder (the joining machine reaching
/// them directly).
final class _MapFolder implements TomSecretsRelayFolder {
  _MapFolder(this.files);

  final Map<String, Uint8List> files;

  Map<String, Uint8List> _under(String folder) => {
    for (final e in files.entries)
      if (e.key.startsWith('$folder/'))
        e.key.substring(folder.length + 1): e.value,
  };

  @override
  Future<String?> revisionOf(String folder) async {
    final under = _under(folder);
    if (under.isEmpty) return null;
    final keys = under.keys.toList()..sort();
    return keys.map((k) => '$k${under[k]!.length}').join(';');
  }

  @override
  Future<Map<String, String>> list(String folder) async => {
    for (final e in _under(folder).entries) e.key: '${e.value.length}',
  };

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<void> create(
    String path,
    Uint8List bytes, {
    required String message,
  }) async {
    if (files.containsKey(path)) throw TomSecretsRelayFileExists(path);
    files[path] = bytes;
  }

  @override
  Future<void> deleteFolder(String folder) async =>
      files.removeWhere((k, _) => k.startsWith('$folder/'));

  @override
  Future<void> deleteFile(String path) async => files.remove(path);
}

final _repo = TomSecretsRelayId.parse('github:al-the-bear/demo-vaults');
const _fast = Duration(milliseconds: 10);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  late TomSecretsPairingPeerKeys giverKeys;
  late TomSecretsPairingPeerKeys receiverKeys;

  setUpAll(() async {
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
    );
    final receiver = TomSecretsTrust.create('bigbeast');
    receiverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await receiver.linkKey()).publicKey,
      approverKey: (await receiver.approverKey()).publicKey,
    );
  });

  group('the relay settings', () {
    test('relays in order with their services; the first that pairs is the '
        'default; duplicates and other text refused', () async {
      final prefs = TomSecretsMemoryPreferences();
      final settings = TomSecretsRelaySettings(prefs);
      expect(settings.relays, isEmpty);
      expect(settings.pairingRelay, isNull);
      await settings.add('tsm:https://relay.example');
      await settings.add(' github:al-the-bear/demo-vaults ');
      await settings.add('wormhole:wss://relay.example:4000/v1');
      expect(settings.relays.map((r) => r.text), [
        'tsm:https://relay.example',
        'github:al-the-bear/demo-vaults',
        'wormhole:wss://relay.example:4000/v1',
      ]);
      expect(settings.pairingRelay?.text, 'tsm:https://relay.example');
      expect(
        settings.offering(TomSecretsRelayService.mailbox).map((r) => r.text),
        ['tsm:https://relay.example', 'github:al-the-bear/demo-vaults'],
      );
      await expectLater(
        settings.add('github:al-the-bear/demo-vaults'),
        throwsStateError,
      );
      await expectLater(settings.add('ftp:x'), throwsFormatException);
      await settings.setPairingRelay(_repo);
      await settings.move(_repo, -1);
      expect(settings.relays.first, _repo);
      // Kept in the preferences: another settings object reads the same.
      final again = TomSecretsRelaySettings(prefs);
      expect(again.pairingRelay, _repo);
      await again.remove(_repo);
      expect(again.pairingRelay, isNull);
      expect(again.relays, hasLength(2));
    });
  });

  group('the pairing QR code', () {
    test('names the relay beside the addresses, or alone', () {
      final code = TomSecretsPairingCode(42, ['guitar', 'orbit']);
      final both = TomSecretsPairingInvitation(
        addresses: ['192.168.1.20'],
        port: 47900,
        code: code,
        relay: _repo,
      );
      expect(both.text, contains('relay=github%3Aal-the-bear%2Fdemo-vaults'));
      final read = TomSecretsPairingInvitation.parse(both.text);
      expect(read.relay, _repo);
      expect(read.addresses, ['192.168.1.20']);
      final alone = TomSecretsPairingInvitation(
        addresses: const [],
        port: 0,
        code: code,
        relay: _repo,
      );
      expect(alone.text, startsWith('tsm-pair:relay?code=42-guitar-orbit'));
      final readAlone = TomSecretsPairingInvitation.parse(alone.text);
      expect(readAlone.addresses, isEmpty);
      expect(readAlone.relay, _repo);
      expect(() => readAlone.addressFor(const []), throwsStateError);
      expect(
        () => TomSecretsPairingInvitation.parse(
          'tsm-pair:relay?code=42-guitar-orbit',
        ),
        throwsFormatException,
      );
      expect(
        () => TomSecretsPairingInvitation.parse(
          'tsm-pair:relay?code=42-guitar-orbit&relay=nothing',
        ),
        throwsFormatException,
      );
      expect(
        () => TomSecretsPairingInvitation(
          addresses: const [],
          port: 0,
          code: code,
        ),
        throwsArgumentError,
      );
    });
  });

  group('giving a pairing through GitHub', () {
    late FakeService service;
    late TomSecretsServiceConnection connection;

    setUp(() async {
      final stores = await demoStores();
      stores[1].location = 'github:al-the-bear/demo-vaults/team.kdbx';
      service = FakeService(stores)
        ..pairIdentity = {'device': 'mbp', ...giverKeys.toJson()};
      connection = TomSecretsServiceConnection(FakeHost(service));
      await connection.connect();
      await connection.unlock(demoPassword);
    });

    TomSecretsPairingModel model(List<InternetAddress> addresses) =>
        TomSecretsPairingModel(
          connection,
          addresses: () async => addresses,
          allowLoopback: true,
          relayFor: (id, stores, device) => tomSecretsAppRelay(
            id,
            connection,
            stores: stores,
            device: device,
            pollInterval: _fast,
          ),
        );

    test('the window waits on the repository through relay.*; a new machine '
        'pairs through it; the folder is gone afterwards', () async {
      final m = model(const [])..pairingRelay = _repo;
      addTearDown(m.dispose);
      await m.open();
      expect(m.stage, TomSecretsPairingStage.waiting, reason: '${m.message}');
      expect(m.relay, _repo);
      expect(m.relayProblem, isNull);
      expect(m.listening, isEmpty);
      final number = m.code!.number;
      expect(service.relayFiles.keys, ['relay/pair/$number/offer']);
      expect(
        service.relayRequests,
        everyElement(endsWith(' team')),
        reason: 'through the served store in that repository',
      );
      final invitation = m.invitation!;
      expect(invitation.addresses, isEmpty);
      expect(invitation.relay, _repo);

      final received = tomSecretsReceivePairingVia(
        TomSecretsGitHubRelay(
          _repo,
          _MapFolder(service.relayFiles),
          pollInterval: _fast,
        ),
        code: invitation.code,
        device: 'bigbeast',
        keysFor: (_, _) async => receiverKeys,
      );
      await _until(() => m.stage == TomSecretsPairingStage.choosing);
      expect(m.receiver, 'bigbeast');
      m.confirm();
      expect((await received).giver, 'mbp');
      await _until(() => m.stage == TomSecretsPairingStage.paired);
      await _until(() => service.relayFiles.isEmpty);
    });

    test(
      'a relay that cannot host is said; the window opens on the LAN',
      () async {
        final m = model([InternetAddress.loopbackIPv4])
          ..pairingRelay = TomSecretsRelayId.parse('github:someone/else');
        addTearDown(m.dispose);
        await m.open();
        expect(m.stage, TomSecretsPairingStage.waiting);
        expect(m.relay, isNull);
        expect(m.relayProblem, contains('github:someone/else'));
        expect(m.relayProblem, contains('serves no vault'));
        expect(m.listening, isNotEmpty);
        expect(m.invitation!.relay, isNull);

        final server = model([InternetAddress.loopbackIPv4])
          ..pairingRelay = TomSecretsRelayId.parse('tsm:https://relay.example');
        addTearDown(server.dispose);
        await server.open();
        expect(server.relayProblem, contains('not available'));
      },
    );

    test('no address and a relay that cannot host: nothing opens', () async {
      final m = model(const [])
        ..pairingRelay = TomSecretsRelayId.parse('github:someone/else');
      addTearDown(m.dispose);
      await m.open();
      expect(m.stage, TomSecretsPairingStage.failed);
      expect(m.message, contains('github:someone/else'));
    });
  });

  group('the First run receiving through GitHub', () {
    late Directory dir;
    late TomSecretsFirstRun firstRun;
    late TomSecretsServiceConnection connection;
    late Map<String, Uint8List> repository;

    setUp(() async {
      dir = Directory('.dart_tool/relay_app_test')..createSync(recursive: true);
      dir = dir.createTempSync('run');
      addTearDown(() => dir.deleteSync(recursive: true));
      firstRun = TomSecretsFirstRun(
        dataDirectory: '${dir.absolute.path}/data',
        keychain: TomInMemorySecretStore(),
      );
      final service = FakeService(await demoStores(), locked: true);
      connection = TomSecretsServiceConnection(
        FakeHost(service, running: false, setup: firstRun),
      );
      repository = {};
    });

    TomSecretsFirstRunModel firstRunModel() => TomSecretsFirstRunModel(
      firstRun: firstRun,
      connection: connection,
      relayFor: (id, token, host) {
        expect(token, 'github_pat_demo_own');
        return TomSecretsGitHubRelay(
          id,
          _MapFolder(repository),
          pollInterval: _fast,
        );
      },
    );

    /// The giving side's window on the repository (a relay only).
    Future<(TomSecretsPairingWindow, TomSecretsPairingCode)> give() async {
      final channel = await TomSecretsGitHubRelay(
        _repo,
        _MapFolder(repository),
        pollInterval: _fast,
      ).host();
      final code = TomSecretsPairingCode(int.parse(channel.nameplate), [
        'guitar',
        'orbit',
      ]);
      final window = await TomSecretsPairingWindow.open(
        addresses: const [],
        relayChannel: channel,
        code: code,
        device: 'mbp',
        bundleFor: (_) async => TomSecretsPairingBundle(
          vaults: [
            const TomSecretsPairingVault(
              name: 'primary',
              locator: 'github:al-the-bear/demo-vaults/primary.kdbx',
              primary: true,
            ),
          ],
          giverKeys: giverKeys,
        ),
      );
      return (window, code);
    }

    test('the relay and this machine\'s own token: received; the primary\'s '
        'token is the machine\'s own', () async {
      final m = firstRunModel()
        ..byPairing = true
        ..host = 'newdesk';
      final (window, code) = await give();
      m
        ..pairCode = code.text
        ..pairRelay = 'github:al-the-bear/demo-vaults'
        ..pairRelayToken = 'github_pat_demo_own';
      await m.receive();
      expect(m.error, isNull);
      expect((await window.result).receiver, 'newdesk');
      expect(m.pairedThrough, 'github:al-the-bear/demo-vaults');
      expect(
        m.receipt!.tokenFor('al-the-bear/demo-vaults')!.token,
        'github_pat_demo_own',
      );
    });

    test(
      'the LAN first: an address that does not answer, then the relay',
      () async {
        final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = unused.port;
        await unused.close();
        final m = firstRunModel()
          ..byPairing = true
          ..host = 'newdesk';
        final (window, code) = await give();
        m
          ..pairAddress = '127.0.0.1:$port'
          ..pairCode = code.text
          ..pairRelay = 'github:al-the-bear/demo-vaults'
          ..pairRelayToken = 'github_pat_demo_own';
        await m.receive();
        expect(m.error, isNull);
        expect(m.pairedThrough, 'github:al-the-bear/demo-vaults');
        await window.result;
      },
    );

    test('no token, a relay kind not available, a pairing that is not there: '
        'said, naming the relay', () async {
      final m = firstRunModel()..byPairing = true;
      m
        ..pairCode = '42-guitar-orbit'
        ..pairRelay = 'github:al-the-bear/demo-vaults';
      await m.receive();
      expect(m.error, contains('token'));
      m.pairRelay = 'tsm:https://relay.example';
      await m.receive();
      expect(m.error, contains('not available'));
      m
        ..pairRelay = 'github:al-the-bear/demo-vaults'
        ..pairRelayToken = 'github_pat_demo_own';
      await m.receive();
      expect(m.error, contains('github:al-the-bear/demo-vaults'));
      expect(m.receipt, isNull);
    });
  });

  test(
    'the relay folder of the service refuses a store not on GitHub',
    () async {
      final service = FakeService(await demoStores());
      final connection = TomSecretsServiceConnection(FakeHost(service));
      await connection.connect();
      await connection.unlock(demoPassword);
      final folder = TomSecretsAdminRelayFolder(connection, 'primary');
      await expectLater(
        folder.list('relay/pair'),
        throwsA(
          isA<TomSecretsAdminException>().having(
            (e) => e.details['reason'],
            'reason',
            'not_github',
          ),
        ),
      );
    },
  );
}
