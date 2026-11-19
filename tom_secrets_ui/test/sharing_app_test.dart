// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Sharing screen against the fake service (part-sharing, phase C): the
/// member key made the first time the screen opens and kept in the primary
/// vault, shown as text, QR code and fingerprint, copied and saved as a key
/// file; members added from a pasted key and a file, a classical key marked
/// for exports only, the refusals, the fingerprint compared, a member
/// removed. Demo keys only.
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

final class _Files implements TomSecretsFiles {
  ({String name, Uint8List bytes})? next;
  final List<({String name, Uint8List bytes})> saved = [];

  @override
  Future<({String name, Uint8List bytes})?> pick() async => next;

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    saved.add((name: name, bytes: bytes));
    return true;
  }

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => null;

  @override
  Future<Uint8List> read(String path) async => Uint8List(0);

  @override
  Future<bool> delete(String path) async => false;
}

/// A classical age recipient filippo.io/age v1.3.2 made (demo).
const _classical =
    'age1vg68yht8qxg2p0tedkg4pp9f6tqu4zpm55n52zca7mzy0rw7lvwq73k9ju';

void main() {
  late FakeService service;
  late _Files files;
  late TomSecretsHost host;
  late TomSecretsMemberKey bob;
  final clipboard = <String>[];

  setUpAll(() async {
    bob = await TomSecretsMemberKey.generate();
  });
  tearDownAll(() => bob.dispose());

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Servers/Box', password: 'demo-box-pw');
    });
    service = FakeService([FakeStore('primary', demoPassword, primary)]);
    files = _Files();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      files: files,
    );
    clipboard.clear();
  });

  Future<void> wait(WidgetTester tester, [int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<TomSecretsSession> sharing(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
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
    return tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
  }

  /// The primary vault as the service holds it now.
  Future<KdbxFile> stored() async => KdbxFormat().read(
    service.stores.single.stored,
    tomSecretsVaultCredentials(password: demoPassword),
  );

  testWidgets('the first visit makes the member key into the primary; it is '
      'shown, copied and saved as an age key file, and made only once', (
    tester,
  ) async {
    final session = await sharing(tester);
    final key = session.memberKeyRecipient!;
    expect(key.isHybrid, isTrue);
    expect(key.encoded, startsWith('age1pq1'));
    expect(service.saves, hasLength(1));

    final file = await stored();
    final entries = tomSecretsMemberKeyEntries(file);
    expect(entries, hasLength(1));
    final back = await tomSecretsMemberKeyOf(entries.single);
    expect(back.recipient, key);
    back.dispose();

    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('tsm-member-key-fingerprint')),
          )
          .data,
      key.shortFingerprint,
    );
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-member-key-text')))
          .data,
      key.encoded,
    );
    expect(find.byKey(const Key('tsm-member-key-qr')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('tsm-member-key-copy')));
    await wait(tester, 2);
    expect(clipboard, [key.encoded]);

    await tester.enterText(find.byKey(const Key('tsm-member-name')), 'Alice');
    await tester.tap(find.byKey(const Key('tsm-member-name-save')));
    await wait(tester, 5);
    expect(session.memberName, 'Alice');
    await tester.tap(find.byKey(const Key('tsm-member-key-save')));
    await wait(tester, 2);
    expect(files.saved.single.name, 'alice.age-recipient.txt');
    final published = tomSecretsReadMemberKeys(
      utf8.decode(files.saved.single.bytes),
    );
    expect(published.single.recipient, key);
    expect(published.single.name, 'Alice');

    // Leaving and opening Sharing again keeps the key.
    await tester.tap(find.text('Vaults'));
    await wait(tester, 2);
    await tester.tap(find.text('Sharing'));
    await wait(tester, 5);
    expect(tomSecretsMemberKeyEntries(await stored()), hasLength(1));
    expect(session.memberKeyRecipient, key);
  });

  testWidgets('members: a pasted key and a key file, a classical key for '
      'exports only, the refusals, the fingerprint compared, removed', (
    tester,
  ) async {
    final session = await sharing(tester);

    // Bob's key, pasted, his fingerprint compared at once.
    await tester.tap(find.byKey(const Key('tsm-member-add')));
    await wait(tester, 2);
    await tester.enterText(
      find.byKey(const Key('tsm-add-member-key')),
      bob.recipient.encoded,
    );
    await tester.pump();
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('tsm-add-member-fingerprint')),
          )
          .data,
      bob.recipient.shortFingerprint,
    );
    final go = find.byKey(const Key('tsm-add-member-go'));
    expect(tester.widget<FilledButton>(go).onPressed, isNull); // no name yet
    await tester.enterText(find.byKey(const Key('tsm-add-member-name')), 'Bob');
    await tester.tap(find.byKey(const Key('tsm-add-member-checked')));
    await tester.pump();
    await tester.tap(go);
    await wait(tester, 5);
    expect(session.members.single.name, 'Bob');
    expect(session.members.single.checked, isNotNull);

    // Carol's classical key from a file: named by the file, exports only.
    files.next = (
      name: 'carol.age-recipient.txt',
      bytes: Uint8List.fromList(utf8.encode('# name: Carol\n$_classical\n')),
    );
    await tester.tap(find.byKey(const Key('tsm-member-add')));
    await wait(tester, 2);
    await tester.tap(find.byKey(const Key('tsm-add-member-open')));
    await wait(tester, 2);
    expect(find.byKey(const Key('tsm-add-member-classical')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-add-member-go')));
    await wait(tester, 5);
    final carol = session.members.firstWhere((m) => m.name == 'Carol');
    expect(carol.canJoinSharedVaults, isFalse);
    expect(carol.checked, isNull);
    expect(find.textContaining('A classical key: for exports'), findsOneWidget);

    // Refused: Bob again, the user's own key, a broken key.
    Future<String> refusal(String text) async {
      await tester.tap(find.byKey(const Key('tsm-member-add')));
      await wait(tester, 2);
      await tester.enterText(find.byKey(const Key('tsm-add-member-key')), text);
      await tester.enterText(
        find.byKey(const Key('tsm-add-member-name')),
        'Again',
      );
      await tester.pump();
      if (tester.widget<FilledButton>(go).onPressed != null) {
        await tester.tap(go);
        await wait(tester, 5);
      }
      final problem = tester
          .widget<Text>(find.byKey(const Key('tsm-add-member-problem')))
          .data!;
      await tester.tap(find.text('Cancel'));
      await wait(tester, 2);
      return problem;
    }

    expect(await refusal(bob.recipient.encoded), contains('as Bob'));
    expect(
      await refusal(session.memberKeyRecipient!.encoded),
      'this is your own member key',
    );
    expect(await refusal('age1pq1broken'), contains('Bech32'));
    expect(session.members, hasLength(2));

    // Carol's fingerprint compared, then Carol removed.
    final fp = carol.recipient.fingerprint;
    await tester.tap(find.byKey(Key('tsm-member-check-$fp')));
    await wait(tester, 2);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('tsm-check-fingerprint')),
          )
          .data,
      carol.recipient.shortFingerprint,
    );
    await tester.tap(find.byKey(const Key('tsm-check-same')));
    await wait(tester, 5);
    expect(
      session.members.firstWhere((m) => m.name == 'Carol').checked,
      isNotNull,
    );
    expect(find.byKey(Key('tsm-member-check-$fp')), findsNothing);

    await tester.tap(find.byKey(Key('tsm-member-remove-$fp')));
    await wait(tester, 2);
    await tester.tap(find.byKey(const Key('tsm-remove-member-go')));
    await wait(tester, 5);
    expect(session.members.map((m) => m.name), ['Bob']);
    expect(tomSecretsMembers(await stored()).map((m) => m.name), ['Bob']);
  });
}
