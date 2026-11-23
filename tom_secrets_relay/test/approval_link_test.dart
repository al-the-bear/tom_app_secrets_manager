// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The approval link through this relay (part-relay), end to end: two real
// secrets services on one primary vault — `bigbeast` the host, `mbp` its
// approver — paired with a relay link, no address between them, the relay
// in token mode. A prompt on bigbeast reaches mbp's app through the relay
// and its answer goes back; without the instance token the link is
// refused and said so; after bigbeast relocked the link opens again.
// Demo data under demo keys only.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_secrets_client/tom_secrets_client.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart';

import 'relay_harness.dart';

const _password = 'primary-demo-pw';
const _token = 'team-token-0123456789';

/// One machine: its folder, bootstrap and admin key.
final class _Machine {
  _Machine(this.dir, this.bootstrap);

  final String dir;
  final TomSecretsBootstrap bootstrap;
  final Uint8List adminKey = tomSecretsRandomBytes();
  final TomInMemorySecretStore keychain = TomInMemorySecretStore();

  TomSecretsRuntime get runtime =>
      TomSecretsRuntime('$dir/run', transport: TomSecretsTransport.unix);

  Future<TomSecretsService> start(String host) async {
    final s = await TomSecretsService.launch(
      TomSecretsServiceConfig(
        runtime: runtime,
        bootstrap: bootstrap,
        adminKey: adminKey,
        keychain: keychain,
        host: host,
        approverLinkRetry: const Duration(milliseconds: 200),
      ),
    );
    addTearDown(s.stop);
    return s;
  }

  Future<TomSecretsAdminClient> admin() async {
    final c = await TomSecretsAdminClient.connect(runtime, adminKey);
    addTearDown(c.close);
    await c.unlock(_password);
    return c;
  }
}

void main() {
  late RelayHarness relay;
  late _Machine mbpMachine;
  late _Machine bigbeastMachine;
  late TomSecretsService mbp;
  late TomSecretsService bigbeast;
  late TomSecretsAdminClient adminA;
  late TomSecretsAdminClient adminB;

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: what);
  }

  Map<String, Object?>? link(TomSecretsService s, String device) =>
      s.linkStates.where((l) => l['device'] == device).firstOrNull;

  setUp(() async {
    relay = await RelayHarness.start(
      const TomSecretsRelayConfig(
        requestsPerSecond: 10000,
        requestsPerMinute: 10000,
        requestsPerDay: 100000,
        tokens: {'team': _token},
      ),
    );
    addTearDown(relay.stop);
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('relay_link');
    addTearDown(() => root.delete(recursive: true));
    // A primary vault both machines serve, as the fleet shares it.
    final primary = tomSecretsNewVault(
      Credentials(ProtectedValue.fromString(_password)),
      'primary',
    );
    final group = primary.createGroup(
      parent: primary.body.rootGroup,
      name: 'Db',
    );
    group.addEntry(
      KdbxEntry.create(primary, group)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Main'))
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('demo-db-pw'),
        ),
    );
    final primaryPath = '${root.path}/primary.kdbx';
    await File(primaryPath).writeAsBytes(await primary.save());
    _Machine machine(String name) {
      final dir = Directory('${root.path}/$name')..createSync();
      return _Machine(
        dir.path,
        TomSecretsBootstrap(
          primary: 'file:$primaryPath',
          dataDirectory: '${dir.path}/data',
          deviceKey: TomSecretsDeviceKeyMode.keyfile,
        ),
      );
    }

    mbpMachine = machine('mbp');
    bigbeastMachine = machine('bigbeast');
    mbp = await mbpMachine.start('mbp');
    bigbeast = await bigbeastMachine.start('bigbeast');
    adminA = await mbpMachine.admin();
    adminB = await bigbeastMachine.admin();
    await adminA.request('subscribe');
  });

  /// Pairs them as the app and the First run record a pairing given by mbp
  /// through this relay: mbp's identity names the relay link, mbp keeps
  /// bigbeast with `pair.record`, bigbeast keeps mbp from the pairing
  /// (the receiving side). Neither has an address of the other.
  Future<void> pair() async {
    final relayId = 'tsm:http://127.0.0.1:${relay.port}';
    final identity = await adminA.request('pair.identity', {'relay': relayId});
    final giverKeys = TomSecretsPairingPeerKeys.fromJson(identity);
    final receiverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await bigbeast.trust.linkKey()).publicKey,
      approverKey: (await bigbeast.trust.approverKey()).publicKey,
    );
    final agreed = tomSecretsPairingLink(giverKeys, receiverKeys)!;
    expect(agreed.relay, relayId);
    final tokenKey = Uint8List(32)..[0] = 9;
    // bigbeast, the receiving side: mbp approves for it.
    bigbeast.trust.recordPeer(
      device: 'mbp',
      tokenKey: tokenKey,
      at: DateTime.now(),
      approverKey: giverKeys.approverKey,
      approverLinkKey: giverKeys.linkKey,
      link: agreed,
      peerIsGiver: true,
    );
    await bigbeast.writeTrust();
    await bigbeast.approvals!.reload();
    bigbeast.relayLinkHost!.refresh();
    // mbp, the giving side, through its app's pair.record.
    await adminA.request('pair.record', {
      'device': 'bigbeast',
      'tokenKey': base64.encode(tokenKey),
      'host': {'linkKey': receiverKeys.linkKey.toJson()},
      'link': {'relay': agreed.relay, 'linkId': agreed.linkId},
    });
  }

  test('a prompt on bigbeast is answered on mbp through the relay', () async {
    for (final a in [adminA, adminB]) {
      await a.request('relay.token.set', {
        'relay': 'tsm:http://127.0.0.1:${relay.port}',
        'token': _token,
      });
    }
    await pair();
    await until(
      () => mbp.approverLinks!.connected.contains('bigbeast'),
      'mbp reached bigbeast through the relay',
    );
    expect(link(mbp, 'bigbeast'), containsPair('via', 'relay'));
    await until(
      () => link(bigbeast, 'mbp')?['state'] == 'connected',
      'bigbeast took mbp\'s session from the relay',
    );
    expect(relay.app.state.rendezvous.openLinks, 1);

    final needed = adminA.events.firstWhere(
      (e) => e['op'] == 'approval_needed',
    );
    final client = await TomSecretsClient.connect(
      clientName: 'demo-client',
      environment: {'TSM_RUNTIME_DIR': '${bigbeastMachine.dir}/run'},
    );
    addTearDown(client.close);
    final answer = client.get('primary/Db/Main');
    final event = await needed;
    expect(event['host'], 'bigbeast');
    expect(event['approvalId'], startsWith('bigbeast/'));
    await adminA.request('approve', {
      'approvalId': event['approvalId'],
      'decision': 'once',
      'secret': 'ref',
    });
    expect((await answer).text, 'demo-db-pw');

    // bigbeast relocks: the link ends, and opens again at its unlock.
    await adminB.request('lock');
    await until(
      () => !mbp.approverLinks!.connected.contains('bigbeast'),
      'the link ended with the lock',
    );
    await adminB.unlock(_password);
    await until(
      () => mbp.approverLinks!.connected.contains('bigbeast'),
      'the link opened again through the relay',
    );
  }, skip: Platform.isWindows ? 'the services run on Unix sockets here' : null);

  test('without the instance token the relay refuses the link, and the '
      'link is said unreachable with the relay\'s reason', () async {
    await pair();
    await until(
      () =>
          link(mbp, 'bigbeast')?['state'] == 'unreachable' &&
          '${link(mbp, 'bigbeast')?['reason']}'.contains('instance token'),
      'the refusal is said',
    );
    final status = await adminA.request('status');
    final links = (status['links']! as List).cast<Map>();
    expect(links.single['via'], 'relay');
    expect(links.single['state'], 'unreachable');
    expect(mbp.approverLinks!.connected, isEmpty);
  }, skip: Platform.isWindows ? 'the services run on Unix sockets here' : null);
}
