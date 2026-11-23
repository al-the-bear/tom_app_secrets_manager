// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Single-entry exports in the app against the fake service (part-sharing,
/// BP-34): marked entries shared to a member's key (the armoured text, the
/// QR code, into a shared vault's inbox) and read back by the member's key;
/// a share under a passphrase pasted and imported into a chosen group; the
/// inbox found at the sync ("1 entry from Alice"), imported and deleted, an
/// expired package deleted, one declined. Demo keys only.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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

/// A relay server's mailbox in memory: each recipient reads only its own
/// items (the proof is the member key handed in).
final class _MemoryMailbox implements TomSecretsRelay {
  _MemoryMailbox(this.id);

  @override
  final TomSecretsRelayId id;

  /// The items by recipient and item id.
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
  Future<void> put(TomSecretsMailboxItem item) async =>
      (items[item.recipient] ??= {})[item.itemId] = item.bytes;

  @override
  Future<TomSecretsPairingChannel> host() => throw UnimplementedError();
  @override
  Future<TomSecretsPairingChannel> join(String nameplate) =>
      throw UnimplementedError();
  @override
  Future<TomSecretsPairingChannel> link(String linkId) =>
      throw UnimplementedError();
}

void main() {
  late FakeService service;
  late TomSecretsHost host;
  late _MemoryMailbox mailbox;
  late TomSecretsMemberKey bob;

  setUpAll(() async => bob = await TomSecretsMemberKey.generate());
  tearDownAll(() => bob.dispose());

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Servers/Box', password: 'demo-box-pw');
    });
    service = FakeService([FakeStore('primary', demoPassword, primary)]);
    mailbox = _MemoryMailbox(
      TomSecretsRelayId.parse('tsm:https://relay.example'),
    );
    // The service's relay.put lands in the same mailbox the app reads.
    service.onRelayPut = (relay, members, name, bytes) async {
      for (final m in members) {
        (mailbox.items[m] ??= {})[name] = bytes;
      }
    };
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      mailboxRelayFor: (id) => mailbox,
    );
  });

  Future<void> wait(WidgetTester tester, [int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  /// Unlocked, Sharing open (Alice's member key made), Bob a member.
  Future<TomSecretsSession> sharing(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1600);
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
    await tester.tap(find.text('Sharing'));
    await wait(tester, 15);
    final session = tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
    await tester.runAsync(() async {
      await session.setMemberName('Alice');
      await session.addMember('Bob', bob.recipient);
    });
    await wait(tester, 5);
    return session;
  }

  /// The shared vault `crew` for Alice and Bob.
  Future<void> crew(WidgetTester tester) async {
    await tap(tester, find.byKey(const Key('tsm-shared-new')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-shared-new-name')),
      'crew',
    );
    await tap(tester, find.byKey(const Key('tsm-shared-new-place')));
    await wait(tester, 2);
    await tap(tester, find.text('Beside my primary vault').last);
    await wait(tester, 2);
    await tap(
      tester,
      find.byKey(Key('tsm-shared-new-member-${bob.recipient.fingerprint}')),
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-shared-new-go')));
    await wait(tester, 15);
  }

  TomSecretsEntryRef box(TomSecretsSession session) =>
      session.index.firstWhere((v) => v.title == 'Box').ref;

  testWidgets('marked entries shared to Bob: the text, the QR code, the '
      'inbox of the shared vault; Bob\'s key reads it', (tester) async {
    final session = await sharing(tester);
    await crew(tester);
    expect(session.sharedVaults, ['crew']);

    await tester.tap(find.text('Vaults'));
    await wait(tester, 5);
    session.toggleMarked(box(session));
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-share-marked')));
    await wait(tester, 2);
    expect(find.byKey(const Key('tsm-share-dialog')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('tsm-share-make')))
          .onPressed,
      isNull,
    );
    await tap(
      tester,
      find.byKey(Key('tsm-share-member-${bob.recipient.fingerprint}')),
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-share-make')));
    await wait(tester, 15);

    final text = tester
        .widget<SelectableText>(find.byKey(const Key('tsm-share-text')))
        .data!;
    expect(text, startsWith('-----BEGIN AGE ENCRYPTED FILE-----'));
    expect(find.byKey(const Key('tsm-share-qr')), findsOneWidget);
    final read = await tester.runAsync(
      () => tomSecretsReadShare(utf8.encode(text), [
        TomSecretsAgeHybridIdentity(bob),
      ]),
    );
    expect(read!.entries.single.title, 'Box');
    expect(read.entries.single.fields['Password']?.value, 'demo-box-pw');
    expect(read.from?.name, 'Alice');
    expect(read.from?.fingerprint, session.memberKeyRecipient!.fingerprint);

    await tap(tester, find.byKey(const Key('tsm-share-inbox-crew')));
    await wait(tester, 5);
    expect(find.byKey(const Key('tsm-share-sent')), findsOneWidget);
    final packages = service.inboxes['crew']!;
    expect(packages.keys.single, startsWith('${bob.recipient.fingerprint}/'));
    final inInbox = await tester.runAsync(
      () => tomSecretsReadShare(packages.values.single, [
        TomSecretsAgeHybridIdentity(bob),
      ]),
    );
    expect(inInbox!.entries.single.title, 'Box');

    // Copy puts the text on the clipboard.
    final clip = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tap(tester, find.byKey(const Key('tsm-share-copy')));
    await wait(tester, 2);
    expect(clip.single, text);
  });

  testWidgets('a share under a passphrase: pasted, the passphrase typed, '
      'imported into a chosen group as a new entry', (tester) async {
    final session = await sharing(tester);
    final incoming = TomSecretsShare(
      created: DateTime.utc(2026, 11, 20),
      from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
      entries: const [
        TomSecretsSharedEntry(
          fields: {
            'Title': (value: 'Office Wi-Fi', protected: false),
            'Password': (value: 'demo-wifi-pw', protected: true),
          },
        ),
      ],
    );
    final file = (await tester.runAsync(
      () => tomSecretsWriteShare(
        incoming,
        passphrase: 'demo passphrase',
        workFactor: 10,
      ),
    ))!;

    await tap(tester, find.byKey(const Key('tsm-import-share')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-import-share-text')),
      'not a share',
    );
    await tap(tester, find.byKey(const Key('tsm-import-share-paste')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-import-share-error')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('tsm-import-share-text')),
      tomSecretsAgeArmor(file),
    );
    await tap(tester, find.byKey(const Key('tsm-import-share-paste')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-import-share-passphrase')),
      'wrong passphrase',
    );
    await tap(tester, find.byKey(const Key('tsm-import-share-unlock')));
    await wait(tester, 10);
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-import-share-error'))).data,
      contains('passphrase is wrong'),
    );
    await tester.enterText(
      find.byKey(const Key('tsm-import-share-passphrase')),
      'demo passphrase',
    );
    await tap(tester, find.byKey(const Key('tsm-import-share-unlock')));
    await wait(tester, 10);
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-import-share-from'))).data,
      'From Bob, a member whose key you have.',
    );
    expect(find.text('Office Wi-Fi'), findsOneWidget);

    await tap(tester, find.byKey(const Key('tsm-import-share-go')));
    await wait(tester, 2);
    await tap(
      tester,
      find.byKey(const Key('tsm-pick-group-primary / Servers')),
    );
    await wait(tester, 10);
    expect(find.byKey(const Key('tsm-import-share-dialog')), findsNothing);
    final wifi = session.index.firstWhere((v) => v.title == 'Office Wi-Fi');
    expect(wifi.ref.store, 'primary');
    expect(
      session.entryOf(wifi.ref)!.getString(KdbxKey('Password'))?.getText(),
      'demo-wifi-pw',
    );
    expect(session.entryOf(wifi.ref)!.parent?.name.get(), 'Servers');
  });

  testWidgets('the inbox at the sync: "1 entry from Bob" imported and '
      'deleted, an expired package deleted, one declined', (tester) async {
    final session = await sharing(tester);
    await crew(tester);
    final alice = session.memberKeyRecipient!;
    Future<Uint8List> fromBob(String title) async => (await tester.runAsync(
      () => tomSecretsWriteShare(
        TomSecretsShare(
          created: DateTime.utc(2026, 11, 20),
          from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
          entries: [
            TomSecretsSharedEntry(
              fields: {
                'Title': (value: title, protected: false),
                'Password': (value: 'demo-$title', protected: true),
              },
            ),
          ],
        ),
        recipients: [alice],
      ),
    ))!;
    final today = tomSecretsNewInboxName();
    final other = tomSecretsNewInboxName();
    const old = '2026-01-02-00112233aabbccdd.age';
    service.inboxes['crew'] = {
      '${alice.fingerprint}/$today': await fromBob('Api key'),
      '${alice.fingerprint}/$other': await fromBob('Unwanted'),
      '${bob.recipient.fingerprint}/$old': Uint8List.fromList([1, 2, 3]),
    };

    await tester.runAsync(session.checkInbox);
    await wait(tester, 5);
    expect(
      service.inboxes['crew']!.containsKey('${bob.recipient.fingerprint}/$old'),
      isFalse,
    );
    expect(session.inbox, hasLength(2));
    expect(find.text('Shares — 2 in your inbox'), findsOneWidget);
    // The rail's badge, seen from another screen.
    await tester.tap(find.text('Vaults'));
    await wait(tester, 3);
    expect(
      tester
          .widget<Badge>(find.byKey(const Key('tsm-sharing-badge')))
          .isLabelVisible,
      isTrue,
    );
    await tester.tap(find.text('Sharing'));
    await wait(tester, 5);
    final apiKey = session.inbox.firstWhere(
      (p) => p.share!.entries.single.title == 'Api key',
    );
    expect(apiKey.title, '1 entry from Bob');
    expect(find.text('1 entry from Bob'), findsNWidgets(2));

    await tap(tester, find.byKey(Key('tsm-inbox-open-${apiKey.name}')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-import-share-go')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-pick-group-crew')));
    await wait(tester, 10);
    expect(
      session.index.any((v) => v.ref.store == 'crew' && v.title == 'Api key'),
      isTrue,
    );
    expect(
      service.inboxes['crew']!.containsKey(
        '${alice.fingerprint}/${apiKey.name}',
      ),
      isFalse,
    );

    final unwanted = session.inbox.single;
    await tap(tester, find.byKey(Key('tsm-inbox-open-${unwanted.name}')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-import-share-decline')));
    await wait(tester, 5);
    expect(session.inbox, isEmpty);
    expect(service.inboxes['crew'], isEmpty);
    expect(find.text('Shares'), findsOneWidget);
    expect(session.index.any((v) => v.title == 'Unwanted'), isFalse);
  });

  testWidgets('a vault whose mailbox is a relay server: the share goes to '
      'Bob\'s mailbox there through the service; a refused put is said', (
    tester,
  ) async {
    final session = await sharing(tester);
    await crew(tester);
    await tester.runAsync(
      () => session.setVaultMailboxRelay(
        'crew',
        TomSecretsRelayId.parse('tsm:https://relay.example'),
      ),
    );
    await wait(tester, 5);
    await tester.tap(find.text('Vaults'));
    await wait(tester, 5);
    session.toggleMarked(box(session));
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-share-marked')));
    await wait(tester, 2);
    await tap(
      tester,
      find.byKey(Key('tsm-share-member-${bob.recipient.fingerprint}')),
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-share-make')));
    await wait(tester, 15);
    expect(
      find.text('Put into the mailboxes of crew (tsm:https://relay.example)'),
      findsOneWidget,
    );

    // Refused by the relay (no instance token): said in the dialog.
    service.relayPutRefusal =
        'the relay tsm:https://relay.example: it did not take the package: '
        'this relay accepts mailbox items only from holders of an instance '
        'token';
    await tap(tester, find.byKey(const Key('tsm-share-inbox-crew')));
    await wait(tester, 5);
    expect(find.textContaining('instance token'), findsOneWidget);
    expect(find.byKey(const Key('tsm-share-sent')), findsNothing);
    expect(mailbox.items, isEmpty);

    service.relayPutRefusal = null;
    await tap(tester, find.byKey(const Key('tsm-share-inbox-crew')));
    await wait(tester, 5);
    expect(find.byKey(const Key('tsm-share-sent')), findsOneWidget);
    expect(find.textContaining('In the mailboxes of crew'), findsOneWidget);
    final put = service.relayPuts.single;
    expect(put.relay, 'tsm:https://relay.example');
    expect(put.members, [bob.recipient.fingerprint]);
    expect(service.inboxes['crew'] ?? const {}, isEmpty);
    final bytes = mailbox.items[bob.recipient.fingerprint]![put.name]!;
    final read = await tester.runAsync(
      () => tomSecretsReadShare(bytes, [TomSecretsAgeHybridIdentity(bob)]),
    );
    expect(read!.entries.single.title, 'Box');
  });

  testWidgets('a vault whose mailbox is a relay server: Alice\'s items read '
      'there with her key, one imported and one declined, both deleted '
      'there; Bob\'s items and the inbox folders not read', (tester) async {
    final session = await sharing(tester);
    await crew(tester);
    await tester.runAsync(
      () => session.setVaultMailboxRelay(
        'crew',
        TomSecretsRelayId.parse('tsm:https://relay.example'),
      ),
    );
    await wait(tester, 5);
    final alice = session.memberKeyRecipient!;
    Future<Uint8List> fromBob(String title) async => (await tester.runAsync(
      () => tomSecretsWriteShare(
        TomSecretsShare(
          created: DateTime.utc(2026, 11, 20),
          from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
          entries: [
            TomSecretsSharedEntry(
              fields: {
                'Title': (value: title, protected: false),
                'Password': (value: 'demo-$title', protected: true),
              },
            ),
          ],
        ),
        recipients: [alice],
      ),
    ))!;
    final first = tomSecretsNewInboxName();
    final second = tomSecretsNewInboxName();
    mailbox.items[alice.fingerprint] = {
      first: await fromBob('Api key'),
      second: await fromBob('Unwanted'),
    };
    mailbox.items[bob.recipient.fingerprint] = {
      tomSecretsNewInboxName(): Uint8List.fromList([1, 2, 3]),
    };
    // A package in the inbox folder is not read for this vault.
    service.inboxes['crew'] = {
      '${alice.fingerprint}/${tomSecretsNewInboxName()}': await fromBob(
        'Folder',
      ),
    };

    await tester.runAsync(session.checkInbox);
    await wait(tester, 5);
    expect(session.inbox, hasLength(2));
    expect(session.inbox.map((p) => p.relay).toSet(), {
      'tsm:https://relay.example',
    });
    final apiKey = session.inbox.firstWhere(
      (p) => p.share!.entries.single.title == 'Api key',
    );
    await tap(tester, find.byKey(Key('tsm-inbox-open-${apiKey.name}')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-import-share-go')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-pick-group-crew')));
    await wait(tester, 10);
    expect(
      session.index.any((v) => v.ref.store == 'crew' && v.title == 'Api key'),
      isTrue,
    );
    expect(mailbox.items[alice.fingerprint]!.keys, [second]);

    final unwanted = session.inbox.single;
    await tap(tester, find.byKey(Key('tsm-inbox-open-${unwanted.name}')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-import-share-decline')));
    await wait(tester, 5);
    expect(session.inbox, isEmpty);
    expect(mailbox.items[alice.fingerprint], isEmpty);
    // Bob's mailbox untouched.
    expect(mailbox.items[bob.recipient.fingerprint], hasLength(1));
  });

  testWidgets('a phone does not share: no Share action', (tester) async {
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      sendsShares: false,
    );
    final session = await sharing(tester);
    await tester.tap(find.text('Vaults'));
    await wait(tester, 5);
    session.toggleMarked(box(session));
    await tester.pump();
    expect(find.byKey(const Key('tsm-marked-actions')), findsOneWidget);
    expect(find.byKey(const Key('tsm-share-marked')), findsNothing);
  });
}
