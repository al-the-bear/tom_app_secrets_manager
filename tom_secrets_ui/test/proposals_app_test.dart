// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Proposals screen (part-app, BP-28, DP-43, DP-52): the service's
/// `proposal` events listed with a badge; a changed password updates the
/// existing login of that site and user (the old one in its history); a new
/// login saved into a vault chosen; a known one said so; drop and the lock
/// forget them. Demo data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  setUp(() async {
    service = FakeService(await demoStores());
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomSecretsApp(
        host: TomSecretsHost(
          service: FakeHost(service),
          preferences: TomSecretsMemoryPreferences(),
          clipboard: _Clipboard(),
        ),
      ),
    );
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
  }

  Future<KdbxFile> stored(WidgetTester tester, String store) async =>
      (await tester.runAsync(
        () => KdbxFormat().read(
          service.store(store).stored,
          tomSecretsVaultCredentials(
            password: store == 'primary' ? demoPassword : 'team-demo-pw',
          ),
        ),
      ))!;

  KdbxEntry byTitle(KdbxFile file, String title) =>
      file.body.rootGroup.getAllEntries().firstWhere((e) => e.label == title);

  testWidgets('a changed password updates the login of that site and user; '
      'the old one stays in its history', (tester) async {
    await unlocked(tester);
    service.emit({
      'op': 'proposal',
      'url': 'https://db.example/login?next=%2F',
      'title': 'Db sign-in',
      'userName': 'demo-user',
      'password': 'demo-db-pw-2',
    });
    await wait(tester);
    final badge = tester.widget<Badge>(
      find.byKey(const Key('tsm-proposals-badge')),
    );
    expect(badge.isLabelVisible, isTrue);
    await tester.tap(find.text('Proposals'));
    await wait(tester);
    expect(find.text('db.example'), findsOneWidget);
    expect(find.text('User name: demo-user'), findsOneWidget);
    expect(find.textContaining('demo-db-pw-2'), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-proposal-update-primary-Main')));
    await wait(tester, 5);
    expect(service.saves.single['store'], 'primary');
    final main = byTitle(await stored(tester, 'primary'), 'Main');
    expect(main.getString(KdbxKeyCommon.PASSWORD)?.getText(), 'demo-db-pw-2');
    expect(
      main.history.map((h) => h.getString(KdbxKeyCommon.PASSWORD)?.getText()),
      contains('demo-db-pw'),
    );
    expect(find.byKey(const Key('tsm-proposals-none')), findsOneWidget);
  });

  testWidgets("git's proposal of a new host saved as a new login in the "
      'vault chosen; a known password said so; drop and the lock forget '
      'them', (tester) async {
    await unlocked(tester);
    service.emit({
      'op': 'proposal',
      'url': 'https://git.example.com/',
      'title': 'git.example.com',
      'userName': 'demo',
      'password': 'demo-git-token',
    });
    await wait(tester);
    await tester.tap(find.text('Proposals'));
    await wait(tester);
    expect(find.byKey(const Key('tsm-proposal-known')), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-proposal-vault')));
    await wait(tester, 1);
    await tester.tap(find.text('team').last);
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-proposal-title')),
      'Git demo',
    );
    await tester.tap(find.byKey(const Key('tsm-proposal-save')));
    await wait(tester, 5);
    expect(service.saves.single['store'], 'team');
    final git = byTitle(await stored(tester, 'team'), 'Git demo');
    expect(git.getString(KdbxKeyCommon.USER_NAME)?.getText(), 'demo');
    expect(git.getString(KdbxKeyCommon.PASSWORD)?.getText(), 'demo-git-token');
    expect(
      git.getString(KdbxKeyCommon.URL)?.getText(),
      'https://git.example.com',
    );

    // The same password as the vault holds: said so, nothing to update.
    service.emit({
      'op': 'proposal',
      'url': 'https://db.example/',
      'userName': 'demo-user',
      'password': 'demo-db-pw',
    });
    await wait(tester);
    expect(find.byKey(const Key('tsm-proposal-known')), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-proposal-update-primary-Main')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('tsm-proposal-drop')));
    await wait(tester);
    expect(find.byKey(const Key('tsm-proposals-none')), findsOneWidget);

    service.emit({
      'op': 'proposal',
      'url': 'https://shop.example.org/',
      'userName': 'demo',
      'password': 'demo-shop-pw',
    });
    await wait(tester);
    expect(find.byKey(const Key('tsm-proposal-list')), findsOneWidget);
    expect(find.text('shop.example.org'), findsWidgets);
    service.emit({'op': 'locked'});
    await wait(tester);
    service.emit({'op': 'unlocked'});
    await wait(tester, 5);
    await tester.tap(find.text('Proposals'));
    await wait(tester);
    expect(find.text('shop.example.org'), findsNothing);
    expect(find.byKey(const Key('tsm-proposals-none')), findsOneWidget);
  });
}
