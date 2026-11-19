// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The guided rotations with a migration period in the app against the fake
/// service (part-key-rotation, phase C): a shared vault's key rotated for
/// the same members (the record in the vault, its lock, Finish now), and
/// the user's member key rotated (old and new key side by side in the
/// recipients files, the old one dropped and deleted at the finish), both
/// also from the Keys screen; and a store whose key changed on another
/// device, served read-only. Demo keys only.
library;

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
  const location = 'file:/demo/crew.kdbx';
  late FakeService service;
  late TomSecretsHost host;
  late TomSecretsMemberKey bob;

  setUpAll(() async => bob = await TomSecretsMemberKey.generate());
  tearDownAll(() => bob.dispose());

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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  /// Unlocked, Sharing open (the member key made), Bob in the directory and
  /// the shared vault `crew` made for Bob.
  Future<TomSecretsSession> crew(WidgetTester tester) async {
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
    expect(session.sharedVaults, ['crew']);
    return session;
  }

  Future<TomSecretsSharedVaultKeys> recipientsFor(TomSecretsMemberKey key) =>
      tomSecretsReadRecipientsFile(service.recipientsFiles[location]!, key);

  testWidgets('a shared vault\'s key rotated: new keys for the same members, '
      'the record in the vault (one at a time), Finish now', (tester) async {
    final session = await crew(tester);
    final before = (await tester.runAsync(() => recipientsFor(bob)))!;

    await tap(tester, find.byKey(const Key('tsm-shared-crew')));
    await wait(tester, 10);
    await tester.pump(const Duration(seconds: 1));
    await tap(tester, find.byKey(const Key('tsm-shared-rotate-crew')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-shared-rotate-go')));
    await wait(tester, 20);

    expect(service.rekeyedSaves, contains('crew'));
    final after = (await tester.runAsync(() => recipientsFor(bob)))!;
    expect(after.keyFile, isNot(before.keyFile));
    expect(after.members.map((m) => m.name), ['Alice', 'Bob']);
    expect(
      TomSecretsPrimaryVaults(
        session.vaults.first.file,
      ).byName('crew')!.keyFile,
      after.keyFile,
    );
    // The vault opens under the new keys and carries the record.
    final stored = await tester.runAsync(
      () => tomSecretsDecodeStored(
        location,
        service.store('crew').stored,
        after.credentials,
      ),
    );
    final record = TomSecretsRotations(
      stored!,
    ).of(TomSecretsRotationKind.sharedVault, 'crew')!;
    expect(record.oldKeyId, before.keyId);
    expect(record.newKeyId, after.keyId);
    expect(record.by, 'Alice');
    expect(record.pending, ['Bob']);
    expect(record.endsAt.difference(record.started), tomSecretsRotationPeriod);
    expect(session.sharedVaultRotation('crew'), isNotNull);
    expect(find.byKey(const Key('tsm-shared-rotation-crew')), findsOneWidget);
    expect(find.byKey(const Key('tsm-shared-rotate-crew')), findsNothing);

    // The record is the lock: a second rotation is refused.
    final again = await tester.runAsync(() async {
      try {
        await session.rotateSharedVaultKeys('crew');
        return 'rotated';
      } on TomSecretsRotationException catch (e) {
        return e.message;
      }
    });
    expect(again, contains('rotat'));

    // Finish is for after the period; Finish now ends it early.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('tsm-shared-finish-crew')))
          .onPressed,
      isNull,
    );
    await tap(tester, find.byKey(const Key('tsm-shared-finish-now-crew')));
    await wait(tester, 15);
    expect(session.sharedVaultRotation('crew'), isNull);
    expect(find.byKey(const Key('tsm-shared-rotation-crew')), findsNothing);
    final ended = await tester.runAsync(
      () => tomSecretsDecodeStored(
        location,
        service.store('crew').stored,
        after.credentials,
      ),
    );
    expect(TomSecretsRotations(ended!).list(), isEmpty);
  });

  testWidgets('the member key rotated: both keys in the recipients file '
      'during the period, the old one dropped and deleted at the finish', (
    tester,
  ) async {
    final session = await crew(tester);
    final oldRecipient = session.memberKeyRecipient!;
    final oldKey = (await tester.runAsync(
      () => tomSecretsMemberKeyOf(session.entryOf(session.memberKeyEntry!)!),
    ))!;
    addTearDown(oldKey.dispose);
    final keyFile = (await tester.runAsync(() => recipientsFor(bob)))!.keyFile;

    await tap(tester, find.byKey(const Key('tsm-member-key-rotate')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-member-key-rotate-go')));
    await wait(tester, 20);

    final fresh = session.memberKeyRecipient!;
    expect(fresh, isNot(oldRecipient));
    final primary = session.vaults.first.file;
    expect(tomSecretsMemberKeyEntries(primary), hasLength(2));
    final record = session.memberKeyRotation!;
    expect(record.target, oldRecipient.fingerprint);
    expect(record.newKeyId, fresh.fingerprint.substring(0, 16));
    expect(record.pending, isEmpty);
    expect(find.byKey(const Key('tsm-member-key-rotation')), findsOneWidget);
    // The vault's own keys stay; the old key and the new one both open the
    // recipients file, and so does Bob's.
    final during = (await tester.runAsync(() => recipientsFor(oldKey)))!;
    expect(during.keyFile, keyFile);
    expect(during.members.map((m) => m.recipient), contains(fresh));
    expect(during.members.map((m) => m.recipient), contains(oldRecipient));
    final read = (await tester.runAsync(
      () => session.readSharedVault(store: 'crew'),
    ))!;
    expect(read.keys.keyFile, keyFile);
    read.keys.dispose();

    await tap(tester, find.byKey(const Key('tsm-member-key-finish-now')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-member-key-finish-now-go')));
    await wait(tester, 20);

    expect(session.memberKeyRotation, isNull);
    expect(tomSecretsMemberKeyEntries(primary), hasLength(1));
    expect(session.memberKeyRecipient, fresh);
    final oldReads = await tester.runAsync(() async {
      try {
        await recipientsFor(oldKey);
        return 'opened';
      } on TomSecretsSharedVaultException catch (e) {
        return e.reason.name;
      }
    });
    expect(oldReads, 'notAMember');
    final finished = (await tester.runAsync(() => recipientsFor(bob)))!;
    expect(finished.keyFile, keyFile);
    expect(finished.members.map((m) => m.recipient), [bob.recipient, fresh]);
    expect(find.byKey(const Key('tsm-member-key-rotation')), findsNothing);
  });

  testWidgets('on the Keys screen: the member key\'s row rotates it, a '
      'shared vault\'s key row rotates with a migration period', (
    tester,
  ) async {
    final session = await crew(tester);
    final fingerprint = session.memberKeyRecipient!.fingerprint;
    Map<String, Object?> row(String kind, String key, {String? vault}) => {
      'kind': kind,
      'key': key,
      'vault': ?vault,
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(days: 400))
          .toIso8601String(),
      'daysLeft': 400,
      'reminding': false,
      'own': true,
    };
    service.keys = [
      row('member_key', 'member-key:${fingerprint.substring(0, 16)}'),
      row('vault_keys', 'vault-keys:crew', vault: 'crew'),
    ];
    await tester.tap(find.text('Keys'));
    await wait(tester, 10);
    expect(
      find.text('Your member key (${fingerprint.substring(0, 16)})'),
      findsOneWidget,
    );

    await tap(
      tester,
      find.byKey(
        Key('tsm-key-rotate-member-key:${fingerprint.substring(0, 16)}'),
      ),
    );
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-key-rotate-member-go')));
    await wait(tester, 20);
    expect(session.memberKeyRotation?.target, fingerprint);

    await tap(tester, find.byKey(const Key('tsm-key-rotate-vault-keys:crew')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-key-rotate-shared-go')));
    await wait(tester, 20);
    expect(session.sharedVaultRotation('crew'), isNotNull);
    expect(service.rekeyedSaves, contains('crew'));
  });

  test('a store whose key changed on another device: read-only, said so', () {
    final changed = TomSecretsStoreState.fromWire(const {
      'name': 'crew',
      'state': 'needs_unlock',
      'source': 'cache',
      'keyChanged': true,
    });
    expect(changed.keyChanged, isTrue);
    expect(changed.offlineReason, contains('its key changed'));
    final plain = TomSecretsStoreState.fromWire(const {
      'name': 'crew',
      'state': 'current',
      'source': 'github',
    });
    expect(plain.keyChanged, isFalse);
    expect(plain.offlineReason, isNull);
  });
}
