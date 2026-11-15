// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The force-push question against the fake service: a save to a vault
/// whose branch was rewritten without a compaction is refused and the state
/// reported; the vault's header and the Status screen name it, and the
/// dialog's answers (take the file on GitHub, merge this copy over it) go
/// to the service and the vault is read again. Demo data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
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

const _head = 'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';

void main() {
  late FakeService service;
  late TomSecretsHost host;

  setUp(() async {
    service = FakeService(await demoStores());
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
    );
    // The team file as the rewritten branch holds it: another entry.
    final remote = await demoVault('team', 'team-demo-pw', (f) {
      addEntry(f, 'Api/Token', password: 'demo-api-token');
      addEntry(f, 'Rewritten meanwhile', password: 'demo-remote');
    });
    service.forcePush('team', remote, _head);
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<TomSecretsSession> unlockedWithRefusedSave(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1100);
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
    final session = tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
    final token = session.index.firstWhere((v) => v.title == 'Token');
    TomSecretsAdminException? refused;
    await tester.runAsync(() async {
      try {
        await session.updateEntry(
          token.ref,
          (e) => e.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('demo-api-token-2'),
          ),
        );
      } on TomSecretsAdminException catch (e) {
        refused = e;
      }
    });
    await wait(tester);
    expect(refused?.details['reason'], 'history_rewritten');
    expect(tomSecretsDescribeAdminError(refused!), contains('rewritten'));
    return session;
  }

  Future<List<String?>> titlesOnTheService() async {
    final file = await KdbxFormat().read(
      service.store('team').stored,
      tomSecretsVaultCredentials(password: 'team-demo-pw'),
    );
    return file.body.rootGroup.getAllEntries().map((e) => e.label).toList();
  }

  testWidgets('the refused save is reported on the vault and the Status '
      'screen; merging this copy over it keeps the change', (tester) async {
    final session = await unlockedWithRefusedSave(tester);
    expect(find.byKey(const Key('tsm-rewritten-team')), findsOneWidget);
    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('its branch on GitHub was rewritten'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tsm-status-rewritten-team')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-rewritten-question')), findsOneWidget);
    expect(find.textContaining('f0f0f0f0f0f0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-rewritten-merge')));
    await wait(tester, 5);
    await tester.pumpAndSettle();
    expect(service.resolutions.single, {'store': 'team', 'take': 'merge'});
    expect(find.byKey(const Key('tsm-rewritten-question')), findsNothing);
    expect(
      find.textContaining('its branch on GitHub was rewritten'),
      findsNothing,
    );
    final token = session.index.firstWhere((v) => v.title == 'Token');
    expect(
      token.entry.getString(KdbxKeyCommon.PASSWORD)!.getText(),
      'demo-api-token-2',
      reason: 'read again after the answer',
    );
  });

  testWidgets('taking the file on GitHub drops the change and serves the '
      'rewritten file', (tester) async {
    final session = await unlockedWithRefusedSave(tester);
    await tester.tap(find.byKey(const Key('tsm-vault-team')));
    await tester.pump();
    final menu = find.descendant(
      of: find.byKey(const Key('tsm-vault-team')),
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('The rewritten branch…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-rewritten-remote')));
    await wait(tester, 5);
    await tester.pumpAndSettle();
    expect(service.resolutions.single['take'], 'remote');
    expect(
      await tester.runAsync(titlesOnTheService),
      contains('Rewritten meanwhile'),
    );
    expect(find.byKey(const Key('tsm-rewritten-team')), findsNothing);
    expect(session.index.map((v) => v.title), contains('Rewritten meanwhile'));
    expect(
      session.index
          .firstWhere((v) => v.title == 'Token')
          .entry
          .getString(KdbxKeyCommon.PASSWORD)!
          .getText(),
      'demo-api-token',
    );
  });
}
