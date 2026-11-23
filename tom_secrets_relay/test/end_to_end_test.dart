// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The relay with its client: tom_secrets_core's TomSecretsServerRelay
// (`tsm:<url>`) against this server in the test's process. The pairing
// protocol runs unchanged over the relay's channel; the mailbox carries a
// share to a member; the approval link's channel holds and reconnects.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import 'relay_harness.dart';

const _config = TomSecretsRelayConfig(
  requestsPerSecond: 10000,
  requestsPerMinute: 10000,
  requestsPerDay: 100000,
  tokens: {'team': 'team-token-0123456789'},
);

void main() {
  late RelayHarness h;
  late TomSecretsRelayId id;
  late TomSecretsPairingPeerKeys keys;

  setUpAll(() async {
    keys = TomSecretsPairingPeerKeys(
      linkKey: (await TomSecretsTrust.create('demo').linkKey()).publicKey,
    );
  });

  setUp(() async {
    h = await RelayHarness.start(_config);
    id = TomSecretsRelayId.parse('tsm:http://127.0.0.1:${h.port}');
  });
  tearDown(() => h.stop());

  TomSecretsServerRelay relay({String? token}) {
    final r = TomSecretsServerRelay(id, token: token);
    addTearDown(r.close);
    return r;
  }

  test('a pairing through the relay: the protocol runs unchanged', () async {
    final channel = await relay().host();
    final number = int.parse(channel.nameplate);
    final code = TomSecretsPairingCode(number, ['guitar', 'orbit']);
    final window = await TomSecretsPairingWindow.open(
      addresses: const [],
      relayChannel: channel,
      code: code,
      device: 'mbp',
      bundleFor: (receiver) async => TomSecretsPairingBundle(
        vaults: const [
          TomSecretsPairingVault(
            name: 'primary',
            locator: 'github:demo-owner/demo-vaults/primary.kdbx',
            primary: true,
          ),
        ],
        giverKeys: keys,
      ),
    );
    final received = await tomSecretsReceivePairingVia(
      relay(),
      code: TomSecretsPairingCode.parse('$number guitar orbit'),
      device: 'bigbeast',
      keysFor: (giver, bundle) async {
        expect(giver, 'mbp');
        return keys;
      },
    );
    final given = await window.result;
    expect(given.receiver, 'bigbeast');
    expect(received.giver, 'mbp');
    expect(received.bundle.vaults.single.name, 'primary');
    expect(received.tokenKey, given.tokenKey);
  });

  test('a wrong code fails at the key confirmation', () async {
    final channel = await relay().host();
    final number = int.parse(channel.nameplate);
    final window = await TomSecretsPairingWindow.open(
      addresses: const [],
      relayChannel: channel,
      code: TomSecretsPairingCode(number, ['guitar', 'orbit']),
      device: 'mbp',
      bundleFor: (_) async =>
          TomSecretsPairingBundle(vaults: const [], giverKeys: keys),
    );
    final outcome = expectLater(
      window.result,
      throwsA(isA<TomSecretsPairingException>()),
    );
    await expectLater(
      tomSecretsReceivePairingVia(
        relay(),
        code: TomSecretsPairingCode(number, ['guitar', 'ocean']),
        device: 'intruder',
        keysFor: (_, _) async => keys,
      ),
      throwsA(isA<TomSecretsPairingException>()),
    );
    await outcome;
  });

  test('a nameplate that is not open is said, naming the relay', () async {
    await expectLater(
      relay().join('999'),
      throwsA(
        isA<TomSecretsRelayException>()
            .having((e) => e.relay, 'relay', id.text)
            .having((e) => e.message, 'message', contains('no pairing')),
      ),
    );
  });

  group('the mailbox', () {
    late TomSecretsMemberKey bob;
    setUpAll(() async => bob = await TomSecretsMemberKey.generate());
    tearDownAll(() => bob.dispose());

    test('a share put for a member, read with the proof', () async {
      final package = await tomSecretsAgeEncrypt(utf8.encode('a share'), [
        bob.recipient,
      ]);
      final name = tomSecretsNewInboxName();
      await relay(token: 'team-token-0123456789').put(
        TomSecretsMailboxItem(
          recipient: bob.recipient.fingerprint,
          itemId: name,
          bytes: package,
          expires: DateTime.now().add(const Duration(days: 30)),
        ),
      );
      final mine = relay();
      final waiting = await mine.list(bob);
      expect(waiting.single.itemId, name);
      expect(waiting.single.size, package.length);
      final bytes = await mine.fetch(bob, name);
      expect(
        utf8.decode(
          await tomSecretsAgeDecrypt(bytes, [TomSecretsAgeHybridIdentity(bob)]),
        ),
        'a share',
      );
      await mine.delete(bob, name);
      expect(await mine.list(bob), isEmpty);
    });

    test('a put without the instance token is refused, saying so', () async {
      await expectLater(
        relay().put(
          TomSecretsMailboxItem(
            recipient: bob.recipient.fingerprint,
            itemId: 'x',
            bytes: Uint8List(1),
            expires: DateTime.now().add(const Duration(days: 1)),
          ),
        ),
        throwsA(
          isA<TomSecretsRelayException>().having(
            (e) => e.message,
            'message',
            contains('instance token'),
          ),
        ),
      );
    });

    test('another member\'s key opens no mailbox but its own', () async {
      final eve = await TomSecretsMemberKey.generate();
      addTearDown(eve.dispose);
      await relay(token: 'team-token-0123456789').put(
        TomSecretsMailboxItem(
          recipient: bob.recipient.fingerprint,
          itemId: 'for-bob',
          bytes: Uint8List.fromList([1]),
          expires: DateTime.now().add(const Duration(days: 1)),
        ),
      );
      // Eve proves her own key only: her mailbox is empty.
      expect(await relay().list(eve), isEmpty);
    });
  });

  test('the approval link holds, and both sides reconnect', () async {
    final a = await relay(token: 'team-token-0123456789').link('link-e2e-01');
    final b = await relay(token: 'team-token-0123456789').link('link-e2e-01');
    final atB = StreamIterator(b.incoming);
    a.send([1, 2, 3]);
    expect(await atB.moveNext(), isTrue);
    expect(atB.current, [1, 2, 3]);
    await a.close();
    expect(await atB.moveNext(), isFalse);

    final a2 = await relay(token: 'team-token-0123456789').link('link-e2e-01');
    final b2 = await relay(token: 'team-token-0123456789').link('link-e2e-01');
    final atA2 = StreamIterator(a2.incoming);
    b2.send([4]);
    expect(await atA2.moveNext(), isTrue);
    expect(atA2.current, [4]);
    await a2.close();
    await b2.close();

    await expectLater(
      relay().link('link-e2e-02'),
      throwsA(
        isA<TomSecretsRelayException>().having(
          (e) => e.message,
          'message',
          contains('instance token'),
        ),
      ),
    );
  });
}
