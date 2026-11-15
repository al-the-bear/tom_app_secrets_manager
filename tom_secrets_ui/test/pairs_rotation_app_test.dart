// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Rotating this device's approver and approval-link key pairs from the
/// Keys screen (part-key-rotation §4) against the fake service: Rotate… on
/// the device's own rows only, the confirmation, `keys.rotate` with both
/// pairs, and the result naming the hosts reached and not reached. Demo
/// data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

Map<String, Object?> _pair(String kind, String key, {bool own = false}) => {
  'kind': kind,
  'key': key,
  'expiresAt': DateTime.now()
      .toUtc()
      .add(const Duration(days: 20, hours: 2))
      .toIso8601String(),
  'daysLeft': 20,
  'reminding': true,
  if (own) 'own': true,
};

void main() {
  late FakeService service;

  setUp(() async {
    service = FakeService(await demoStores())
      ..keys = [
        _pair('approver_key', 'approver-key:demo-host', own: true),
        _pair('link_key', 'link-key:demo-host', own: true),
        _pair('approver_key', 'approver-key:bigbeast'),
      ];
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  testWidgets('Rotate… on this device\'s own pairs: confirmed, both rotated, '
      'the hosts reached and not reached named', (tester) async {
    tester.view.physicalSize = const Size(1700, 1200);
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
    await tester.tap(find.text('Keys'));
    await wait(tester, 5);

    expect(
      find.byKey(const Key('tsm-key-rotate-approver-key:demo-host')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tsm-key-rotate-link-key:demo-host')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tsm-key-rotate-approver-key:bigbeast')),
      findsNothing,
      reason: 'a peer\'s pair is rotated on that device',
    );

    // Cancelled: nothing sent.
    await tester.tap(
      find.byKey(const Key('tsm-key-rotate-link-key:demo-host')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.pairRotations, isEmpty);

    await tester.tap(
      find.byKey(const Key('tsm-key-rotate-approver-key:demo-host')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-pairs-rotate')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-pairs-rotate-go')));
    await wait(tester, 5);
    await tester.pumpAndSettle();
    expect(service.pairRotations.single, {'approver': true, 'link': true});
    final message = tester
        .widget<Text>(find.byKey(const Key('tsm-pairs-message')))
        .data!;
    expect(message, contains('Taken over the approval link by bigbeast'));
    expect(message, contains('Not reached: legiondary01'));
    expect(message, contains('2 grants and revocations signed again'));
  });
}
