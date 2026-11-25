// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// A share through a shared vault's mailbox on this relay (part-relay), end
// to end: a real secrets service puts it with `relay.put` and the instance
// token its keychain keeps for the relay, into the mailboxes of two
// members; each member lists, fetches, reads and deletes their own item
// with the proof of their member key, as the app's Shares do, and sees no
// other member's. Without the token the put is refused and said so.
// Demo data under demo keys only.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

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
  late TomSecretsAdminClient admin;
  late TomSecretsMemberKey bob;
  late TomSecretsMemberKey carol;
  late TomSecretsMemberKey eve;
  late String relayId;

  setUpAll(() async {
    bob = await TomSecretsMemberKey.generate();
    carol = await TomSecretsMemberKey.generate();
    eve = await TomSecretsMemberKey.generate();
  });
  tearDownAll(() {
    bob.dispose();
    carol.dispose();
    eve.dispose();
  });

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
    relayId = 'tsm:http://127.0.0.1:${relay.port}';
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('relay_mailbox');
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
    admin = await TomSecretsAdminClient.connect(runtime, adminKey);
    addTearDown(admin.close);
    await admin.unlock(_password);
  });

  Future<Uint8List> share() => tomSecretsWriteShare(
    TomSecretsShare(
      created: DateTime.now(),
      entries: const [
        TomSecretsSharedEntry(
          fields: {
            'Title': (value: 'Demo login', protected: false),
            'Password': (value: 'demo-shared-pw', protected: true),
          },
        ),
      ],
    ),
    recipients: [bob.recipient, carol.recipient],
  );

  Future<Map<String, Object?>> put(Uint8List bytes) =>
      admin.request('relay.put', {
        'relay': relayId,
        'members': [bob.recipient.fingerprint, carol.recipient.fingerprint],
        'bytes': base64.encode(bytes),
      });

  test(
    'a share put by the service arrives in each member\'s mailbox, is '
    'read with their key and deleted there; no member sees another\'s',
    () async {
      await admin.request('relay.token.set', {
        'relay': relayId,
        'token': _token,
      });
      final sent = await put(await share());
      final name = sent['name']! as String;
      expect(tomSecretsIsInboxName(name), isTrue);

      final reader = TomSecretsServerRelay(TomSecretsRelayId.parse(relayId));
      for (final member in [bob, carol]) {
        final waiting = await reader.list(member);
        expect(waiting.single.itemId, name);
        expect(
          waiting.single.expires!.difference(DateTime.now()).inDays,
          inInclusiveRange(29, 30),
        );
        final opened = await tomSecretsReadShare(
          await reader.fetch(member, name),
          [TomSecretsAgeHybridIdentity(member)],
        );
        expect(
          opened.entries.single.fields['Password']!.value,
          'demo-shared-pw',
        );
      }
      // A key that is no member's opens its own, empty mailbox only, and
      // cannot fetch or delete another member's item.
      expect(await reader.list(eve), isEmpty);
      await expectLater(
        reader.fetch(eve, name),
        throwsA(isA<TomSecretsRelayException>()),
      );
      // Bob imports (or declines) his: deleted there, Carol's stays.
      await reader.delete(bob, name);
      expect(await reader.list(bob), isEmpty);
      expect((await reader.list(carol)).single.itemId, name);
    },
    skip: Platform.isWindows ? 'the service runs on a Unix socket here' : null,
  );

  test(
    'without the instance token the put is refused, naming the relay '
    'and the token',
    () async {
      await expectLater(
        put(await share()),
        throwsA(
          isA<TomSecretsAdminException>()
              .having((e) => e.kind, 'kind', 'unavailable')
              .having((e) => e.message, 'message', contains(relayId))
              .having((e) => e.message, 'message', contains('instance token')),
        ),
      );
      final reader = TomSecretsServerRelay(TomSecretsRelayId.parse(relayId));
      expect(await reader.list(bob), isEmpty);
    },
    skip: Platform.isWindows ? 'the service runs on a Unix socket here' : null,
  );
}
