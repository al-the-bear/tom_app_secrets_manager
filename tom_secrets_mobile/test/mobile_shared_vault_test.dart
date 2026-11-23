// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A shared vault on the phone (part-sharing, part-mobile) against a fake
/// GitHub: another member removed someone and re-keyed it, so the keys the
/// primary lists no longer open it; the phone's session reads the
/// recipients file through the engine (`vault.recipients`), opens it with
/// the member key from the primary, lists the new keys in the primary and
/// writes it to GitHub; the next unlock opens the vault at once. A share in
/// the phone's inbox folder is found at the unlock, imported and deleted
/// with an expired one. Joining, managing members and sending shares stay
/// the desktop app's. Demo keys only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart'
    show TomSecretsAdminException;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/demo_vaults.dart';

const _crew = 'github:$demoRepo/shared/crew.kdbx';
const _crewKeys = 'github:$demoRepo/shared/crew.keys.age';

void main() {
  late FakeGitHubServer server;
  late TomInMemorySecretStore keychain;
  late DemoVaults demo;
  late TomSecretsMemberKey phone;
  late TomSecretsMemberKey bob;
  late TomSecretsMemberKey carol;
  late TomSecretsSharedVaultKeys keys;

  setUpAll(() async {
    phone = await TomSecretsMemberKey.generate();
    bob = await TomSecretsMemberKey.generate();
    carol = await TomSecretsMemberKey.generate();
  });
  tearDownAll(() {
    phone.dispose();
    bob.dispose();
    carol.dispose();
  });

  /// The demo vaults, and a shared vault `crew` for the user, Bob and Carol
  /// listed in the primary with its key file, its recipients file beside it;
  /// the user's member key in the primary.
  setUp(() async {
    server = FakeGitHubServer();
    demo = DemoVaults(server);
    await demo.seed();
    keychain = TomInMemorySecretStore();
    await demo.fillKeychain(keychain);
    keys = TomSecretsSharedVaultKeys.generate(
      'crew',
      members: [
        (name: 'Me', recipient: phone.recipient),
        (name: 'Bob', recipient: bob.recipient),
        (name: 'Carol', recipient: carol.recipient),
      ],
    );
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials);
    tomSecretsAddMemberKey(primary, phone);
    TomSecretsPrimaryVaults(primary, primaryLocator: demoPrimary).put(
      TomSecretsVaultKeys(name: 'crew', locator: _crew, keyFile: keys.keyFile),
    );
    await demo.put(demoPrimary, primary);
    final crew = tomSecretsNewSharedVault('crew', keys);
    crew.body.rootGroup.addEntry(
      KdbxEntry.create(crew, crew.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Shared login'))
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('crew-pw-1'),
        ),
    );
    await demo.put(_crew, crew);
    await demo.putBytes(_crewKeys, await tomSecretsWriteRecipientsFile(keys));
  });

  /// The phone's app: an engine, the connection and the session over it,
  /// unlocked and loaded.
  Future<(TomSecretsMobileEngine, TomSecretsSession)> unlock({
    TomSecretsRelay Function(TomSecretsRelayId id)? mailboxRelayFor,
  }) async {
    final engine = TomSecretsMobileEngine(
      primaryLocator: demoPrimary,
      device: 'demo-phone',
      platform: 'ios',
      keychain: keychain,
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
    final session = TomSecretsSession(
      connection,
      TomSecretsMemoryPreferences(),
      systemVaultsReadOnly: true,
      mailboxRelayFor: mailboxRelayFor,
    );
    addTearDown(session.dispose);
    await session.load();
    return (engine, session);
  }

  bool holds(TomSecretsSession session, String store, String title) =>
      session.index.any((v) => v.ref.store == store && v.title == title);

  test('the shared vault opens with the keys the primary lists; the engine '
      'answers vault.recipients by store only', () async {
    final (engine, session) = await unlock();
    expect(holds(session, 'crew', 'Shared login'), isTrue);
    expect(session.sharedVaults, ['crew']);
    expect(session.sharedKeysTakenUp, isEmpty);

    final read = await engine.request('vault.recipients', {'store': 'crew'});
    expect(read['location'], _crew);
    final opened = await tomSecretsReadRecipientsFile(
      base64.decode(read['bytes']! as String),
      phone,
    );
    expect(opened.keyFile, keys.keyFile);

    final none = isA<TomSecretsAdminException>();
    await expectLater(
      engine.request('vault.recipients', {'store': 'team'}),
      throwsA(
        none.having((e) => e.details['reason'], 'reason', 'no_recipients'),
      ),
    );
    await expectLater(
      engine.request('vault.recipients', {'location': _crew}),
      throwsA(none.having((e) => e.kind, 'kind', 'unsupported')),
    );
    for (final op in ['vault.recipients.set', 'vault.create']) {
      await expectLater(
        engine.request(op, {'store': 'crew'}),
        throwsA(none.having((e) => e.kind, 'kind', 'unsupported')),
      );
    }
  });

  test('another member re-keyed the vault: the phone takes up the new keys '
      'from the recipients file, writes them into the primary on GitHub, and '
      'the next unlock opens the vault at once', () async {
    // Bob removes Carol on his desktop: the vault re-keyed, the recipients
    // file written for the members left; the phone's primary still lists
    // the old key file.
    final next = keys.withoutMember(carol.recipient);
    final crew = await demo.fetch(_crew, keys.credentials)
      ..credentials = next.credentials;
    await demo.put(_crew, crew);
    await demo.putBytes(_crewKeys, await tomSecretsWriteRecipientsFile(next));

    final (_, session) = await unlock();
    expect(session.sharedKeysTakenUp, {'crew'});
    expect(holds(session, 'crew', 'Shared login'), isTrue);
    expect(session.failures, isEmpty);
    final onGitHub = await demo.fetch(demoPrimary, demo.primaryCredentials);
    final listed = TomSecretsPrimaryVaults(onGitHub).byName('crew')!;
    expect(listed.keyFile, next.keyFile);
    expect(listed.locator, _crew);

    // The next unlock: the primary lists the new key file, nothing to take
    // up, the vault opens.
    final (_, again) = await unlock();
    expect(again.sharedKeysTakenUp, isEmpty);
    expect(again.failures, isEmpty);
    expect(holds(again, 'crew', 'Shared login'), isTrue);
  });

  test(
    'a vault no longer shared with the phone\'s key stays as it is',
    () async {
      final next = keys.withoutMember(phone.recipient);
      final crew = await demo.fetch(_crew, keys.credentials)
        ..credentials = next.credentials;
      await demo.put(_crew, crew);
      await demo.putBytes(_crewKeys, await tomSecretsWriteRecipientsFile(next));

      final (_, session) = await unlock();
      expect(session.sharedKeysTakenUp, isEmpty);
      expect(holds(session, 'crew', 'Shared login'), isFalse);
      final listed = TomSecretsPrimaryVaults(
        await demo.fetch(demoPrimary, demo.primaryCredentials),
      ).byName('crew')!;
      expect(listed.keyFile, keys.keyFile);
    },
  );

  test('the inbox: a share for the phone found at the unlock ("1 entry from '
      'Bob"), imported and deleted, an expired package deleted; sending is '
      'refused', () async {
    final share = await tomSecretsWriteShare(
      TomSecretsShare(
        created: DateTime.utc(2026, 11, 20),
        from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
        entries: const [
          TomSecretsSharedEntry(
            fields: {
              'Title': (value: 'Door code', protected: false),
              'Password': (value: 'demo-4711', protected: true),
            },
          ),
        ],
      ),
      recipients: [phone.recipient],
    );
    final name = tomSecretsNewInboxName();
    const old = '2026-01-02-00112233aabbccdd.age';
    final mine = phone.recipient.fingerprint;
    await demo.putBytes('github:$demoRepo/shared/inbox/$mine/$name', share);
    await demo.putBytes(
      'github:$demoRepo/shared/inbox/${carol.recipient.fingerprint}/$old',
      share,
    );

    final (engine, session) = await unlock();
    final inbox = session.inbox.single;
    expect(inbox.title, '1 entry from Bob');
    expect(
      server.bytesAt(
        demoRepo,
        'shared/inbox/${carol.recipient.fingerprint}/$old',
      ),
      isNull,
    );

    await session.acceptInboxPackage(inbox, 'crew', null);
    expect(holds(session, 'crew', 'Door code'), isTrue);
    expect(session.inbox, isEmpty);
    expect(server.bytesAt(demoRepo, 'shared/inbox/$mine/$name'), isNull);

    await expectLater(
      engine.request('inbox.put', {
        'store': 'crew',
        'members': [mine],
        'bytes': base64.encode(share),
      }),
      throwsA(
        isA<TomSecretsAdminException>().having(
          (e) => e.kind,
          'kind',
          'unsupported',
        ),
      ),
    );
  });

  test('a vault whose mailbox is a relay server: the phone reads its items '
      'there with its member key, imports one and deletes it there', () async {
    final mailbox = _MemoryMailbox(
      TomSecretsRelayId.parse('tsm:https://relay.example'),
    );
    final share = await tomSecretsWriteShare(
      TomSecretsShare(
        created: DateTime.utc(2026, 11, 20),
        from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
        entries: const [
          TomSecretsSharedEntry(
            fields: {
              'Title': (value: 'Gate code', protected: false),
              'Password': (value: 'demo-0815', protected: true),
            },
          ),
        ],
      ),
      recipients: [phone.recipient],
    );
    final name = tomSecretsNewInboxName();
    final mine = phone.recipient.fingerprint;
    mailbox.items[mine] = {name: share};
    final (_, session) = await unlock(mailboxRelayFor: (id) => mailbox);
    await session.setVaultMailboxRelay('crew', mailbox.id);
    await session.checkInbox();
    final package = session.inbox.single;
    expect(package.relay, 'tsm:https://relay.example');
    expect(package.title, '1 entry from Bob');
    await session.acceptInboxPackage(package, 'crew', null);
    expect(holds(session, 'crew', 'Gate code'), isTrue);
    expect(session.inbox, isEmpty);
    expect(mailbox.items[mine], isEmpty);
  });
}

/// A relay server's mailbox in memory: each recipient reads only its own
/// items (the proof is the member key handed in).
final class _MemoryMailbox implements TomSecretsRelay {
  _MemoryMailbox(this.id);

  @override
  final TomSecretsRelayId id;

  final Map<String, Map<String, Uint8List>> items = {};

  @override
  Set<TomSecretsRelayService> get services => id.services;

  @override
  Future<List<TomSecretsMailboxEntry>> list(TomSecretsMemberKey me) async => [
    for (final e in (items[me.recipient.fingerprint] ?? const {}).entries)
      TomSecretsMailboxEntry(itemId: e.key, size: e.value.length),
  ];

  @override
  Future<Uint8List> fetch(TomSecretsMemberKey me, String itemId) async =>
      items[me.recipient.fingerprint]![itemId]!;

  @override
  Future<void> delete(TomSecretsMemberKey me, String itemId) async =>
      items[me.recipient.fingerprint]?.remove(itemId);

  @override
  Future<void> put(TomSecretsMailboxItem item) => throw UnimplementedError();
  @override
  Future<TomSecretsPairingChannel> host() => throw UnimplementedError();
  @override
  Future<TomSecretsPairingChannel> join(String nameplate) =>
      throw UnimplementedError();
  @override
  Future<TomSecretsPairingChannel> link(String linkId) =>
      throw UnimplementedError();
}
