// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_age/tom_secrets_age.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

Matcher _refused(int status) => throwsA(
  isA<TomSecretsRelayRefused>().having((e) => e.status, 'status', status),
);

void main() {
  late DateTime now;
  late Directory dir;
  late TomSecretsRelayMailbox mailbox;
  final r = 'a' * 52;

  setUp(() async {
    now = DateTime.utc(2026, 11, 23, 12);
    dir = await Directory.systemTemp.createTemp('relay_mailbox');
    mailbox = TomSecretsRelayMailbox(
      TomDirectoryBlobStore(dir),
      const TomSecretsRelayConfig(itemsPerRecipient: 3, bytesPerRecipient: 10),
      clock: () => now,
    );
  });
  tearDown(() => dir.delete(recursive: true));

  Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

  group('the mailbox', () {
    test('put, list, fetch, delete', () async {
      final expires = now.add(const Duration(days: 30));
      await mailbox.put(r, 'one', bytes(3), expires);
      final items = await mailbox.list(r);
      expect(items.single.id, 'one');
      expect(items.single.size, 3);
      expect(items.single.received, now);
      expect(items.single.expires, expires);
      expect(await mailbox.fetch(r, 'one'), bytes(3));
      expect(await mailbox.delete(r, 'one'), isTrue);
      expect(await mailbox.delete(r, 'one'), isFalse);
      expect(await mailbox.list(r), isEmpty);
      expect(await mailbox.fetch(r, 'one'), isNull);
    });

    test('an existing item id is refused', () async {
      await mailbox.put(r, 'one', bytes(1), now.add(const Duration(days: 1)));
      await expectLater(
        mailbox.put(r, 'one', bytes(1), now.add(const Duration(days: 1))),
        _refused(409),
      );
    });

    test('at most 30 days, never in the past', () async {
      expect(
        () => mailbox.put(r, 'x', bytes(1), now.add(const Duration(days: 31))),
        _refused(400),
      );
      expect(
        () => mailbox.put(
          r,
          'x',
          bytes(1),
          now.subtract(const Duration(seconds: 1)),
        ),
        _refused(400),
      );
    });

    test('1 MB per item', () {
      final m = TomSecretsRelayMailbox(
        TomDirectoryBlobStore(dir),
        const TomSecretsRelayConfig(),
        clock: () => now,
      );
      expect(
        () => m.put(
          r,
          'x',
          bytes(1024 * 1024 + 1),
          now.add(const Duration(days: 1)),
        ),
        _refused(413),
      );
    });

    test('the items and bytes per recipient', () async {
      final e = now.add(const Duration(days: 1));
      await mailbox.put(r, 'a', bytes(4), e);
      await mailbox.put(r, 'b', bytes(4), e);
      // 4 + 4 + 4 > 10 bytes.
      await expectLater(mailbox.put(r, 'c', bytes(4), e), _refused(429));
      await mailbox.put(r, 'c', bytes(1), e);
      // Three items.
      await expectLater(mailbox.put(r, 'd', bytes(1), e), _refused(429));
      // Another recipient has its own.
      await mailbox.put('b' * 52, 'd', bytes(1), e);
    });

    test('the expiry job deletes expired items', () async {
      await mailbox.put(
        r,
        'short',
        bytes(1),
        now.add(const Duration(hours: 1)),
      );
      await mailbox.put(r, 'long', bytes(1), now.add(const Duration(days: 2)));
      now = now.add(const Duration(hours: 2));
      expect((await mailbox.list(r)).map((i) => i.id), ['long']);
      expect(await mailbox.expire(), 1);
      now = now.add(const Duration(days: 3));
      expect(await mailbox.expire(), 1);
      expect(await mailbox.list(r), isEmpty);
    });

    test('ids are checked', () {
      expect(() => mailbox.list('X' * 52), _refused(400));
      expect(
        () =>
            mailbox.put(r, '../x', bytes(1), now.add(const Duration(days: 1))),
        _refused(400),
      );
      expect(() => mailbox.fetch(r, '.hidden'), _refused(400));
    });
  });

  group('the recipient\'s proof', () {
    late TomSecretsMemberKey key;
    late TomSecretsRelayProofs proofs;
    setUpAll(() async => key = await TomSecretsMemberKey.generate());
    tearDownAll(() => key.dispose());
    setUp(
      () => proofs = TomSecretsRelayProofs(
        const TomSecretsRelayConfig(),
        clock: () => now,
      ),
    );

    test('only the key holder reads the token, valid 5 minutes', () async {
      final id = key.recipient.fingerprint;
      final file = await proofs.challenge(id, key.recipient.encoded);
      final token = utf8.decode(
        await tomSecretsAgeDecrypt(file, [TomSecretsAgeHybridIdentity(key)]),
      );
      expect(proofs.verify(id, token), isTrue);
      expect(proofs.verify('b' * 52, token), isFalse);
      expect(proofs.verify(id, 'guessed'), isFalse);
      now = now.add(const Duration(minutes: 5, seconds: 1));
      expect(proofs.verify(id, token), isFalse);
    });

    test('a recipient that does not hash to the id is refused', () async {
      await expectLater(
        proofs.challenge('a' * 52, key.recipient.encoded),
        _refused(400),
      );
      await expectLater(
        proofs.challenge(key.recipient.fingerprint, 'age1nothing'),
        _refused(400),
      );
    });

    test('20 challenges per recipient per hour', () async {
      final id = key.recipient.fingerprint;
      for (var i = 0; i < 20; i++) {
        await proofs.challenge(id, key.recipient.encoded);
      }
      await expectLater(
        proofs.challenge(id, key.recipient.encoded),
        _refused(429),
      );
    });
  });
}
