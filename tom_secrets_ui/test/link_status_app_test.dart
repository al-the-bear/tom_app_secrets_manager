// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The approval links on the Status screen (part-relay): each paired
/// device's link with its state and way, a link the relay refused (no
/// instance token) read like an unreachable link with the relay's reason.
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

void main() {
  test('a link\'s state in words', () {
    expect(
      tomSecretsLinkStateText({'state': 'connected', 'via': 'relay'}),
      'connected through the relay server',
    );
    expect(
      tomSecretsLinkStateText({'state': 'waiting', 'via': 'relay'}),
      'waiting through the relay server for the other device',
    );
    expect(
      tomSecretsLinkStateText({
        'state': 'unreachable',
        'via': 'relay',
        'reason':
            'the relay tsm:https://relay.example: it opens approval '
            'links only for holders of an instance token',
      }),
      startsWith('unreachable through the relay server: the relay'),
    );
    expect(
      tomSecretsLinkStateText({'state': 'connected', 'via': 'address'}),
      'connected over the network or the VPN',
    );
  });

  testWidgets('the Status screen lists the approval links', (tester) async {
    final service = FakeService(await demoStores())
      ..links = [
        {
          'device': 'bigbeast',
          'role': 'host',
          'state': 'unreachable',
          'via': 'relay',
          'reason':
              'the relay tsm:https://relay.example: it opens approval '
              'links only for holders of an instance token',
        },
        {
          'device': 'server1',
          'role': 'approver',
          'state': 'connected',
          'via': 'relay',
        },
      ];
    final host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
    );
    tester.view.physicalSize = const Size(1700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    Future<void> wait([int rounds = 3]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    await wait(1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(10);
    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    expect(find.text('Approval links'), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-status-link-host-bigbeast')),
      findsOneWidget,
    );
    expect(find.text('Approving for bigbeast'), findsOneWidget);
    expect(
      find.textContaining('unreachable through the relay server'),
      findsOneWidget,
    );
    expect(find.textContaining('instance token'), findsOneWidget);
    expect(find.text('server1 approves for this machine'), findsOneWidget);
    expect(find.text('connected through the relay server'), findsOneWidget);
  });
}
