// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// A device's normal use against this relay with its DEFAULT per-address
// limits (part-relay, DP-65): a real secrets service puts four shares to six
// members (relay.put), one member reads, fetches and deletes four items, a
// pairing and an approval link open — all from one address, paced by the
// client (tom_secrets_core's TomSecretsServerRelay), and the address is
// never blocked. The same use unpaced is blocked, so the test measures
// the pacing. Demo data under demo keys only.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart';

import 'relay_harness.dart';

const _password = 'primary-demo-pw';
const _token = 'team-token-0123456789';

void main() {
  late RelayHarness relay;
  late String relayId;
  late List<TomSecretsMemberKey> members;

  setUpAll(() async {
    members = [
      for (var i = 0; i < 6; i++) await TomSecretsMemberKey.generate(),
    ];
  });
  tearDownAll(() {
    for (final m in members) {
      m.dispose();
    }
  });

  setUp(() async {
    // The defaults, only the token added: 10 a second, 120 a minute, 2,000
    // a day per address.
    relay = await RelayHarness.start(
      const TomSecretsRelayConfig(tokens: {'team': _token}),
    );
    addTearDown(relay.stop);
    relayId = 'tsm:http://127.0.0.1:${relay.port}';
  });

  DateTime? blocked() => relay.app.state.guard.blockedUntil('127.0.0.1');

  test('the defaults are 10 a second, 120 a minute, 2,000 a day', () {
    const c = TomSecretsRelayConfig();
    expect(
      [c.requestsPerSecond, c.requestsPerMinute, c.requestsPerDay],
      [10, 120, 2000],
    );
  });

  test(
    'four shares to six members, a mailbox read of four items, a pairing '
    'and '
    'a link, paced, never block the address',
    () async {
      final root = await Directory.systemTemp.createTemp('relay_pacing');
      addTearDown(() => root.delete(recursive: true));
      final primary = tomSecretsNewVault(
        Credentials(ProtectedValue.fromString(_password)),
        'primary',
      );
      final primaryPath = '${root.path}/primary.kdbx';
      await File(primaryPath).writeAsBytes(await primary.save());
      final runtime = TomSecretsRuntime(
        '${root.path}/run',
        transport: TomSecretsTransport.unix,
      );
      final adminKey = tomSecretsRandomBytes();
      final service = await TomSecretsService.launch(
        TomSecretsServiceConfig(
          runtime: runtime,
          bootstrap: TomSecretsBootstrap(
            primary: 'file:$primaryPath',
            dataDirectory: '${root.path}/data',
            deviceKey: TomSecretsDeviceKeyMode.keyfile,
          ),
          adminKey: adminKey,
          keychain: TomInMemorySecretStore(),
          host: 'alice-host',
        ),
      );
      addTearDown(service.stop);
      trustTestServices();
      final admin = await TomSecretsAdminClient.connect(runtime, adminKey);
      addTearDown(admin.close);
      await admin.unlock(_password);
      await admin.request('relay.token.set', {
        'relay': relayId,
        'token': _token,
      });

      // Four shares, each to all six members: 24 puts (the relay takes 30 per
      // token an hour).
      final names = <String>[];
      for (var i = 0; i < 4; i++) {
        final package = await tomSecretsAgeEncrypt(utf8.encode('share $i'), [
          for (final m in members) m.recipient,
        ]);
        final put = await admin.request('relay.put', {
          'relay': relayId,
          'members': [for (final m in members) m.recipient.fingerprint],
          'bytes': base64.encode(package),
        });
        names.add(put['name']! as String);
      }
      expect(blocked(), isNull, reason: 'the puts');

      // The first member reads, fetches and deletes their four items.
      final reader = TomSecretsServerRelay(TomSecretsRelayId.parse(relayId));
      addTearDown(reader.close);
      final me = members.first;
      final waiting = await reader.list(me);
      expect(waiting.map((e) => e.itemId).toSet(), names.toSet());
      for (final e in waiting) {
        final bytes = await reader.fetch(me, e.itemId);
        expect(
          utf8.decode(
            await tomSecretsAgeDecrypt(Uint8List.fromList(bytes), [
              TomSecretsAgeHybridIdentity(me),
            ]),
          ),
          startsWith('share '),
        );
        await reader.delete(me, e.itemId);
      }
      expect(await reader.list(me), isEmpty);
      expect(blocked(), isNull, reason: 'the mailbox read');

      // A pairing and an approval link.
      final host = await reader.host();
      final joiner = await reader.join(host.nameplate);
      final atHost = StreamIterator(host.incoming);
      joiner.send([1]);
      expect(await atHost.moveNext(), isTrue);
      await host.close();
      await joiner.close();
      final withToken = TomSecretsServerRelay(
        TomSecretsRelayId.parse(relayId),
        token: _token,
      );
      addTearDown(withToken.close);
      final a = await withToken.link('pacing-link-01');
      final b = await withToken.link('pacing-link-01');
      final atB = StreamIterator(b.incoming);
      a.send([2]);
      expect(await atB.moveNext(), isTrue);
      await a.close();
      await b.close();
      expect(blocked(), isNull, reason: 'the pairing and the link');
    },
    skip: Platform.isWindows ? 'the service runs on a Unix socket here' : null,
  );

  test('the same mailbox read unpaced is blocked', () async {
    final put = TomSecretsServerRelay(
      TomSecretsRelayId.parse(relayId),
      token: _token,
    );
    addTearDown(put.close);
    for (var i = 0; i < 6; i++) {
      await put.put(
        TomSecretsMailboxItem(
          recipient: members.first.recipient.fingerprint,
          itemId: 'item-$i',
          bytes: Uint8List.fromList([i]),
          expires: DateTime.now().add(const Duration(days: 1)),
        ),
      );
    }
    final unpaced = TomSecretsServerRelay(
      TomSecretsRelayId.parse(relayId),
      pacer: TomSecretsRelayPacer(
        budgets: const [(limit: 1000000, window: Duration(seconds: 1))],
      ),
    );
    addTearDown(unpaced.close);
    await expectLater(() async {
      final waiting = await unpaced.list(members.first);
      for (final e in waiting) {
        await unpaced.fetch(members.first, e.itemId);
        await unpaced.delete(members.first, e.itemId);
      }
    }(), throwsA(isA<TomSecretsRelayException>()));
    expect(blocked(), isNotNull);
  });
}
