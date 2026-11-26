// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The quick unlock in the app (part-app, Unlocking; protocol.md 6.4): the
/// Unlock screen's PIN, "Use a PIN next time" and the PIN step, the PIN
/// once more after a restart, 5 wrong PINs, and Settings › Unlock. Against
/// the fake service; demo data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

const _pin = 'tiger7';

void main() {
  late FakeService service;
  late TomInMemoryGatedSecretStore gated;

  setUp(() async {
    service = FakeService(await demoStores());
    gated = TomInMemoryGatedSecretStore();
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> start(WidgetTester tester, {bool osUnlock = false}) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomSecretsApp(
        host: TomSecretsHost(
          service: FakeHost(service),
          preferences: TomSecretsMemoryPreferences(),
          osUnlock: osUnlock
              ? TomSecretsOsUnlockHost(store: gated, label: 'Touch ID')
              : null,
        ),
      ),
    );
    await wait(tester, 2);
  }

  Future<void> typePassword(WidgetTester tester, {bool pinNext = false}) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    if (pinNext) {
      await tester.tap(find.byKey(const Key('tsm-unlock-pin-next')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 8);
  }

  Future<void> lockService(WidgetTester tester) async {
    service.locked = true;
    service.emit({'op': 'locked'});
    await wait(tester, 6);
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    await tester.enterText(find.byKey(const Key('tsm-unlock-pin')), pin);
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock-with-pin')));
    await wait(tester, 6);
  }

  Future<void> setPinInStep(WidgetTester tester, {bool confirm = true}) async {
    await tester.enterText(find.byKey(const Key('tsm-pin-step')), _pin);
    if (confirm) {
      await tester.enterText(
        find.byKey(const Key('tsm-pin-step-confirm')),
        _pin,
      );
    }
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-pin-step-save')));
    await wait(tester, 6);
  }

  testWidgets('"Use a PIN next time": the PIN step after the unlock, then '
      'the PIN undoes the lock; a wrong one says the attempts left; "Use '
      'the master password" switches', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('tsm-unlock-pin')), findsNothing);
    await typePassword(tester, pinNext: true);
    expect(find.byKey(const Key('tsm-pin-step')), findsOneWidget);
    // Too short, and two that differ, are refused here already.
    await tester.enterText(find.byKey(const Key('tsm-pin-step')), '123');
    await tester.tap(find.byKey(const Key('tsm-pin-step-save')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-pin-step-problem')), findsOneWidget);
    await setPinInStep(tester);
    expect(service.quickPin, _pin);
    expect(find.byType(TomSecretsMainShell), findsOneWidget);

    await lockService(tester);
    expect(find.byKey(const Key('tsm-unlock-pin')), findsOneWidget);
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsNothing);
    await typePin(tester, 'wrong1');
    expect(service.locked, isTrue);
    expect(find.textContaining('4 attempts left'), findsWidgets);
    await typePin(tester, _pin);
    expect(service.locked, isFalse);
    expect(find.byType(TomSecretsMainShell), findsOneWidget);

    await lockService(tester);
    await tester.tap(find.byKey(const Key('tsm-unlock-use-password')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
    expect(find.byKey(const Key('tsm-unlock-use-pin')), findsOneWidget);
  });

  testWidgets('5 wrong PINs: the master password, and the PIN asked again '
      'after it', (tester) async {
    await start(tester);
    await typePassword(tester, pinNext: true);
    await setPinInStep(tester);
    await lockService(tester);
    for (var i = 0; i < 5; i++) {
      await typePin(tester, 'wrong1');
    }
    expect(service.quickPin, isNull);
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
    expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
    await typePassword(tester);
    expect(find.text('Your PIN'), findsWidgets, reason: 'the switch is on');
    await setPinInStep(tester, confirm: false);
    expect(service.quickPin, _pin);
  });

  testWidgets('after a restart: the master password once, then "Your PIN" '
      'once; "Not now" leaves the PIN to be typed in Settings', (tester) async {
    service.quickPinOn = true;
    await start(tester);
    expect(
      find.byKey(const Key('tsm-unlock-pin')),
      findsNothing,
      reason: 'nothing sealed after a restart',
    );
    await typePassword(tester);
    expect(find.byKey(const Key('tsm-pin-step-text')), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-pin-step-confirm')),
      findsNothing,
      reason: 'the PIN again, typed once',
    );
    await tester.tap(find.byKey(const Key('tsm-pin-step-skip')));
    await wait(tester);
    expect(find.byType(TomSecretsMainShell), findsOneWidget);
    expect(service.quickPin, isNull);

    await tester.tap(find.text('Settings'));
    await wait(tester);
    final rearm = find.byKey(const Key('tsm-settings-pin-rearm'));
    await tester.ensureVisible(rearm);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-settings-pin-state'))).data,
      contains('typed once more'),
    );
    await tester.tap(rearm);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tsm-pin-dialog')), _pin);
    await tester.enterText(
      find.byKey(const Key('tsm-pin-dialog-confirm')),
      _pin,
    );
    await tester.tap(find.byKey(const Key('tsm-pin-dialog-save')));
    await wait(tester, 6);
    expect(service.quickPin, _pin);
  });

  testWidgets('Settings › Unlock: set, change and remove the PIN; the '
      'attempts left; what each way survives; "Remember" warns', (
    tester,
  ) async {
    await start(tester, osUnlock: true);
    await typePassword(tester);
    await tester.tap(find.text('Settings'));
    await wait(tester);
    final set = find.byKey(const Key('tsm-settings-pin-set'));
    await tester.ensureVisible(set);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('tsm-settings-unlock-survives')))
          .data,
      allOf(contains('idle or screen lock'), contains('restart')),
    );
    expect(
      find.byKey(const Key('tsm-settings-quick-biometric')),
      findsOneWidget,
    );
    await tester.tap(set);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tsm-pin-dialog')), _pin);
    await tester.enterText(
      find.byKey(const Key('tsm-pin-dialog-confirm')),
      _pin,
    );
    await tester.tap(find.byKey(const Key('tsm-pin-dialog-save')));
    await wait(tester, 6);
    expect(service.quickPin, _pin);
    service.quickAttempts = 3;
    await tester.tap(find.byKey(const Key('tsm-settings-pin-change')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tsm-pin-dialog')), 'lion88');
    await tester.enterText(
      find.byKey(const Key('tsm-pin-dialog-confirm')),
      'lion88',
    );
    await tester.tap(find.byKey(const Key('tsm-pin-dialog-save')));
    await wait(tester, 6);
    expect(service.quickPin, 'lion88');
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-settings-pin-state'))).data,
      contains('5 attempts left'),
    );
    await tester.tap(find.byKey(const Key('tsm-settings-pin-remove')));
    await wait(tester, 6);
    expect(service.quickPin, isNull);
    expect(service.quickPinOn, isFalse);
    expect(find.byKey(const Key('tsm-settings-pin-set')), findsOneWidget);
    final warning = find.byKey(const Key('tsm-settings-remember-warning'));
    await tester.ensureVisible(warning);
    expect(
      tester.widget<Text>(warning).data,
      contains('skips the one master-password unlock after a restart'),
    );
  });

  testWidgets('the Unlock screen\'s "Remember" checkbox warns', (tester) async {
    await start(tester, osUnlock: true);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('tsm-unlock-remember-warning')))
          .data,
      contains('you may forget it'),
    );
  });
}
