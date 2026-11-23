// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Shared vaults in the app against the fake service (part-sharing, phase
/// C): a new shared vault for a chosen member, its members read from the
/// recipients file, a member added and one removed (the vault re-keyed,
/// the recipients file written with it) with the rotation offer; another
/// person's vault joined by its location; and the new keys taken up after
/// another member re-keyed a vault. Demo keys only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

void main() {
  late FakeService service;
  late TomSecretsHost host;
  late TomSecretsMemberKey bob;
  late TomSecretsMemberKey carol;

  setUpAll(() async {
    bob = await TomSecretsMemberKey.generate();
    carol = await TomSecretsMemberKey.generate();
  });
  tearDownAll(() {
    bob.dispose();
    carol.dispose();
  });

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Servers/Box', password: 'demo-box-pw');
    });
    service = FakeService([FakeStore('primary', demoPassword, primary)]);
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
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

  /// Taps [finder] after scrolling it into view.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  /// Unlocked, Sharing open (the member key made), Bob and Carol in the
  /// directory.
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
      await session.addMember('Carol', carol.recipient);
    });
    await wait(tester, 5);
    return session;
  }

  Future<TomSecretsSharedVaultKeys> recipientsFor(
    String location,
    TomSecretsMemberKey key,
  ) => tomSecretsReadRecipientsFile(service.recipientsFiles[location]!, key);

  testWidgets('a new shared vault for Bob; Carol added; Bob removed: the '
      'vault re-keyed with its recipients file, the rotation offer', (
    tester,
  ) async {
    final session = await sharing(tester);
    final alice = session.memberKeyRecipient!;

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

    const location = 'file:/demo/crew.kdbx';
    final created = service.creations.single;
    expect(created['location'], location);
    expect((created['keys']! as Map).containsKey('password'), isFalse);
    final first = await tester.runAsync(() => recipientsFor(location, bob));
    expect(first!.members.map((m) => m.name), ['Alice', 'Bob']);
    expect(first.members.first.recipient, alice);
    expect(session.sharedVaults, ['crew']);
    expect(session.kindOf('crew'), TomSecretsVaultKind.shared);
    expect(
      TomSecretsPrimaryVaults(
        session.vaults.first.file,
      ).byName('crew')!.keyFile,
      first.keyFile,
    );

    // The members, read from the recipients file.
    await tap(tester, find.byKey(const Key('tsm-shared-crew')));
    await wait(tester, 10);
    // The tile's opening animation runs on the test clock.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Alice (you)'), findsOneWidget);
    expect(find.text('Bob'), findsWidgets);

    // Carol added: the keys stay.
    await tap(tester, find.byKey(const Key('tsm-shared-add-member-crew')));
    await wait(tester, 2);
    await tap(
      tester,
      find.byKey(Key('tsm-shared-add-${carol.recipient.fingerprint}')),
    );
    await wait(tester, 10);
    final added = await tester.runAsync(() => recipientsFor(location, carol));
    expect(added!.members.map((m) => m.name), ['Alice', 'Bob', 'Carol']);
    expect(added.keyFile, first.keyFile);

    // An entry in the vault, then Bob removed.
    await tester.runAsync(() async {
      final ref = await session.createEntry(
        'crew',
        title: 'Shared login',
        select: false,
      );
      await session.setField(ref, 'Password', 'demo-shared-pw');
    });
    await wait(tester, 5);
    await tap(
      tester,
      find.byKey(Key('tsm-shared-remove-crew-${bob.recipient.fingerprint}')),
    );
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-shared-remove-go')));
    await wait(tester, 20);

    expect(service.rekeyedSaves, contains('crew'));
    final after = await tester.runAsync(() => recipientsFor(location, carol));
    expect(after!.members.map((m) => m.name), ['Alice', 'Carol']);
    expect(after.keyFile, isNot(first.keyFile));
    final bobReads = await tester.runAsync(() async {
      try {
        await recipientsFor(location, bob);
        return 'opened';
      } on TomSecretsSharedVaultException catch (e) {
        return e.reason.name;
      }
    });
    expect(bobReads, 'notAMember');
    final stored = service.store('crew').stored;
    await tester.runAsync(
      () => tomSecretsDecodeStored(location, stored, after.credentials),
    );
    expect(
      TomSecretsPrimaryVaults(
        session.vaults.first.file,
      ).byName('crew')!.keyFile,
      after.keyFile,
    );

    // The rotation offer: the shared login marked.
    final login = session.index.firstWhere((v) => v.title == 'Shared login');
    await tap(
      tester,
      find.byKey(Key('tsm-rotate-${tomSecretsUuidHex(login.ref.uuid)}')),
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-rotate-go')));
    await wait(tester, 10);
    final marked = session.index.firstWhere((v) => v.title == 'Shared login');
    expect(marked.tags, contains(tomSecretsRotateTag));
    expect(marked.expires, isNotNull);
  });

  testWidgets('the Relays section: a relay added with its services, the '
      'pairing default; a shared vault\'s mailbox relay kept in its metadata '
      '(part-relay)', (tester) async {
    final session = await sharing(tester);
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
    await tap(tester, find.byKey(const Key('tsm-shared-new-go')));
    await wait(tester, 15);
    expect(session.sharedVaults, ['crew']);

    // Relays: a wrong id said; a GitHub repository and a relay server.
    await tester.enterText(
      find.byKey(const Key('tsm-relay-add-text')),
      'ftp:nothing',
    );
    await tap(tester, find.byKey(const Key('tsm-relay-add')));
    await wait(tester, 2);
    expect(find.byKey(const Key('tsm-relay-error')), findsOneWidget);
    for (final r in [
      'github:al-the-bear/demo-vaults',
      'tsm:https://relay.example',
    ]) {
      await tester.enterText(find.byKey(const Key('tsm-relay-add-text')), r);
      await tap(tester, find.byKey(const Key('tsm-relay-add')));
      await wait(tester, 2);
    }
    expect(find.byKey(const Key('tsm-relay-error')), findsNothing);
    expect(
      find.byKey(const Key('tsm-relay-github:al-the-bear/demo-vaults')),
      findsOneWidget,
    );
    expect(find.textContaining('pairing, mailbox · a GitHub'), findsOneWidget);
    expect(find.textContaining('the default for pairing'), findsOneWidget);
    final settings = TomSecretsRelaySettings(host.preferences);
    expect(settings.pairingRelay?.text, 'github:al-the-bear/demo-vaults');
    await tap(
      tester,
      find.byKey(const Key('tsm-relay-default-tsm:https://relay.example')),
    );
    await wait(tester, 2);
    expect(settings.pairingRelay?.text, 'tsm:https://relay.example');

    // A relay server's instance token: kept through the service, never on
    // the screen; a GitHub repository has no token field.
    expect(find.textContaining('no instance token'), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-relay-token-github:al-the-bear/demo-vaults')),
      findsNothing,
    );
    await tap(
      tester,
      find.byKey(const Key('tsm-relay-token-tsm:https://relay.example')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('tsm-relay-token-text')),
      'team-token-0123456789',
    );
    await tap(tester, find.byKey(const Key('tsm-relay-token-keep')));
    await wait(tester, 4);
    expect(service.relayTokens, {
      'tsm:https://relay.example': 'team-token-0123456789',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('instance token kept'), findsOneWidget);
    expect(find.byKey(const Key('tsm-relay-token-text')), findsNothing);
    expect(find.textContaining('team-token-0123456789'), findsNothing);
    await tap(
      tester,
      find.byKey(const Key('tsm-relay-token-tsm:https://relay.example')),
    );
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('tsm-relay-token-remove')));
    await wait(tester, 4);
    expect(service.relayTokens, isEmpty);
    expect(find.textContaining('no instance token'), findsOneWidget);

    // The vault's mailbox relay: its own repository first, a relay server
    // chosen, kept in the metadata (and saved).
    await tap(tester, find.byKey(const Key('tsm-shared-crew')));
    await wait(tester, 10);
    await tester.pump(const Duration(seconds: 1));
    expect(session.mailboxRelayOf('crew'), isNull);
    expect(find.text('This vault\'s repository'), findsOneWidget);
    final saves = service.saves.length;
    await tap(tester, find.byKey(const Key('tsm-shared-mailbox-crew')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tsm:https://relay.example').last);
    await wait(tester, 10);
    expect(session.mailboxRelayOf('crew')?.text, 'tsm:https://relay.example');
    expect(service.saves.length, greaterThan(saves));
    expect(
      find.byKey(const Key('tsm-shared-mailbox-note-crew')),
      findsOneWidget,
    );
    expect(
      find.textContaining('go to their mailboxes on tsm:https://relay.example'),
      findsOneWidget,
    );
    // A GitHub repository is not offered as another vault's mailbox.
    await tap(tester, find.byKey(const Key('tsm-shared-mailbox-crew')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(DropdownMenuItem<String>),
        matching: find.text('github:al-the-bear/demo-vaults'),
      ),
      findsNothing,
    );
    await tester.tap(find.text('This vault\'s repository').last);
    await wait(tester, 10);
    expect(session.mailboxRelayOf('crew'), isNull);
  });

  testWidgets('another person\'s vault joined by its location; the new keys '
      'taken up after another member re-keyed it', (tester) async {
    final session = await sharing(tester);
    final alice = session.memberKeyRecipient!;
    const location = 'github:bob-demo/team-vaults/team.kdbx';

    // Bob's vault, shared with Alice.
    final keys = TomSecretsSharedVaultKeys.generate(
      'team',
      members: [
        (name: 'Bob', recipient: bob.recipient),
        (name: 'Alice', recipient: alice),
      ],
    );
    final file = tomSecretsNewSharedVault('team', keys, argon2: testArgon2);
    addEntry(file, 'Api/Token', password: 'team-token-1');
    final bytes = await tester.runAsync(file.save);
    service.elsewhere[location] = Uint8List.fromList(bytes!);
    service.recipientsFiles[location] = (await tester.runAsync(
      () => tomSecretsWriteRecipientsFile(keys),
    ))!;

    await tap(tester, find.byKey(const Key('tsm-shared-join')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-shared-join-location')),
      location,
    );
    await tester.enterText(
      find.byKey(const Key('tsm-shared-join-token')),
      'demo-team-token',
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-shared-join-go')));
    await wait(tester, 20);

    expect(service.recipientReads.last['githubToken'], 'demo-team-token');
    expect(session.vaults.map((v) => v.store), contains('team'));
    expect(session.sharedVaults, ['team']);
    final listed = TomSecretsPrimaryVaults(
      session.vaults.first.file,
    ).byName('team')!;
    expect(listed.locator, location);
    expect(listed.keyFile, keys.keyFile);
    expect(listed.githubToken, 'demo-team-token');
    expect(
      session.index.any((v) => v.ref.store == 'team' && v.title == 'Token'),
      isTrue,
    );

    // Bob removes Carol (never a member here) — any re-key: new keys, the
    // file re-keyed, the recipients file written; Alice's listed keys no
    // longer open it.
    final next = keys.withoutMember(bob.recipient);
    final rekeyed = await tester.runAsync(() async {
      final f = await tomSecretsDecodeStored(
        location,
        service.store('team').stored,
        keys.credentials,
      );
      f.credentials = next.credentials;
      return f.save();
    });
    service.store('team')
      ..stored = Uint8List.fromList(rekeyed!)
      ..revision = tomSecretsBlobId(rekeyed);
    service.recipientsFiles[location] = (await tester.runAsync(
      () => tomSecretsWriteRecipientsFile(next),
    ))!;

    await tester.runAsync(session.load);
    await wait(tester, 10);
    expect(session.sharedKeysTakenUp, {'team'});
    expect(
      TomSecretsPrimaryVaults(
        session.vaults.first.file,
      ).byName('team')!.keyFile,
      next.keyFile,
    );
    expect(session.vaults.map((v) => v.store), contains('team'));
    expect(session.failures, isEmpty);
    expect(find.byKey(const Key('tsm-shared-taken-up')), findsOneWidget);
  });

  testWidgets('a vault not shared with the user\'s key: joining it says so', (
    tester,
  ) async {
    final session = await sharing(tester);
    const location = 'file:/elsewhere/theirs.kdbx';
    final keys = TomSecretsSharedVaultKeys.generate(
      'theirs',
      members: [(name: 'Bob', recipient: bob.recipient)],
    );
    service.recipientsFiles[location] = (await tester.runAsync(
      () => tomSecretsWriteRecipientsFile(keys),
    ))!;
    await tap(tester, find.byKey(const Key('tsm-shared-join')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-shared-join-location')),
      location,
    );
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-shared-join-go')));
    await wait(tester, 10);
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-shared-error'))).data,
      'the vault is not shared with your member key',
    );
    expect(session.vaults.map((v) => v.store), isNot(contains('theirs')));
    expect(base64.encode(service.recipientsFiles[location]!), isNotEmpty);
  });
}
