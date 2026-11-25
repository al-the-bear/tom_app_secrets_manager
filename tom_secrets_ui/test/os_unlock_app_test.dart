// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The OS unlock in the app (part-os-unlock): "remember" keeps a saved item
/// and the next lock opens with Touch ID; lock mode (c) keeps a session
/// item, the screen lock locks the service, and an item of an older service
/// start is dropped; a re-keyed vault, a changed enrolment and a cancelled
/// prompt fall back to the master password; "Lock completely" and a service
/// stop forget the session; the settings name the gate-only form as the
/// weaker one and say when there is no OS unlock (Linux). A gated store in
/// memory, demo data only.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Session implements TomSecretsSessionEvents {
  final StreamController<TomSecretsSessionEvent> controller =
      StreamController.broadcast();

  @override
  Stream<TomSecretsSessionEvent> get events => controller.stream;
}

void main() {
  late FakeService service;
  late TomInMemoryGatedSecretStore gated;
  late TomSecretsMemoryPreferences preferences;
  late _Session session;

  setUp(() async {
    service = FakeService(await demoStores());
    gated = TomInMemoryGatedSecretStore();
    preferences = TomSecretsMemoryPreferences();
    session = _Session();
  });

  TomSecretsHost host({bool osUnlock = true}) => TomSecretsHost(
    service: FakeHost(service),
    preferences: preferences,
    osUnlock: osUnlock
        ? TomSecretsOsUnlockHost(store: gated, label: 'Touch ID')
        : null,
    sessionEvents: session,
  );

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> start(WidgetTester tester, {bool osUnlock = true}) async {
    tester.view.physicalSize = const Size(1700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host(osUnlock: osUnlock)));
    await wait(tester, 2);
  }

  Future<void> typePassword(
    WidgetTester tester, {
    bool remember = false,
  }) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    if (remember) {
      await tester.tap(find.byKey(const Key('tsm-unlock-remember')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
  }

  Future<void> lockService(WidgetTester tester) async {
    service.locked = true;
    service.emit({'op': 'locked'});
    await wait(tester, 6);
  }

  String handle() => TomSecretsOsUnlock.handleOf(service.stores.first.name);

  testWidgets('"Remember" keeps a saved item of the composite key; the next '
      'lock opens with Touch ID at once', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('tsm-unlock-os')), findsNothing);
    await typePassword(tester, remember: true);
    expect(service.locked, isFalse);
    expect(gated.lifetimeOf(handle()), TomGatedLifetime.saved);
    final item =
        jsonDecode((await gated.read(handle(), reason: 'test'))!) as Map;
    final bundle = jsonDecode(utf8.decode(base64.decode(item['bundle'])));
    expect(
      base64.decode(bundle['compositeKey'] as String),
      service.stores.first.compositeKey,
    );
    expect(bundle.containsKey('password'), isFalse);
    gated.prompts.clear();

    await lockService(tester);
    expect(service.bundles, hasLength(1));
    expect(service.bundles.single.vault, service.stores.first.name);
    expect(gated.prompts, [TomSecretsOsUnlock.unlockReason]);
    expect(service.locked, isFalse);
    expect(find.byKey(const Key('tsm-unlock')), findsNothing);
    // The editing path opened the primary with the composite key the
    // service now holds in place of the password.
    expect(service.stores.first.viaComposite, isTrue);
    await wait(tester, 4);
    expect(find.text('Recovery codes'), findsWidgets);
  });

  testWidgets('lock mode (c): a session item of this start; the screen lock '
      'locks the service and Touch ID opens it; "Lock completely" forgets the '
      'session', (tester) async {
    service.lockMode = 'c';
    await start(tester);
    await typePassword(tester);
    expect(gated.lifetimeOf(handle()), TomGatedLifetime.session);
    final recorded =
        jsonDecode(preferences.read(TomSecretsOsUnlockKeys.items)!) as Map;
    expect((recorded.values.single as Map)['start'], 1763100000000);

    session.controller.add(TomSecretsSessionEvent.screenLocked);
    await wait(tester, 2);
    expect(service.requests.map((r) => r['op']), contains('lock'));
    await wait(tester, 6);
    expect(service.locked, isFalse, reason: 'opened with the session item');
    expect(service.bundles, hasLength(1));

    final os = Provider.of<TomSecretsOsUnlock>(
      tester.element(find.byType(TomSecretsMainShell)),
      listen: false,
    );
    await tester.runAsync(os.lockCompletely);
    await wait(tester, 4);
    expect(gated.handles, isEmpty);
    expect(find.byKey(const Key('tsm-unlock-os')), findsNothing);
    expect(service.locked, isTrue);
  });

  testWidgets('a session item of an older service start is dropped, not '
      'used', (tester) async {
    await gated.write(handle(), '{}', lifetime: TomGatedLifetime.session);
    await preferences.write(
      TomSecretsOsUnlockKeys.items,
      jsonEncode({
        service.stores.first.name: {'lifetime': 'session', 'start': 42},
      }),
    );
    await start(tester);
    expect(find.byKey(const Key('tsm-unlock-os')), findsNothing);
    expect(gated.prompts, isEmpty);
    await wait(tester, 2);
    expect(gated.handles, isEmpty);
  });

  testWidgets('a vault re-keyed elsewhere: the bundle is refused, forgotten, '
      'and the master password asked', (tester) async {
    await start(tester);
    await typePassword(tester, remember: true);
    service.stores.first.password = 'another-demo-password';
    await lockService(tester);
    expect(service.locked, isTrue);
    expect(gated.handles, isEmpty);
    expect(
      find.textContaining(
        'master password of ${service.stores.first.name} '
        'changed',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
  });

  testWidgets('a changed enrolment forgets the item; a cancelled prompt '
      'leaves it and the password field', (tester) async {
    await start(tester);
    await typePassword(tester, remember: true);
    gated.nextFailure = TomGatedSecretErrorKind.cancelled;
    await lockService(tester);
    expect(service.locked, isTrue);
    expect(gated.handles, [handle()]);
    expect(find.byKey(const Key('tsm-unlock-os-message')), findsNothing);
    expect(find.byKey(const Key('tsm-unlock-os')), findsOneWidget);

    gated.nextFailure = TomGatedSecretErrorKind.invalidated;
    await tester.tap(find.byKey(const Key('tsm-unlock-os')));
    await wait(tester, 6);
    expect(service.locked, isTrue);
    expect(gated.handles, isEmpty);
    expect(find.textContaining('Touch ID changed'), findsOneWidget);
  });

  testWidgets('Settings: (c) offered with Touch ID, the gate-only form named '
      'the weaker one; without an OS unlock neither (c) nor "remember"', (
    tester,
  ) async {
    gated.available = TomGatedAvailability.gateOnly;
    await start(tester);
    expect(find.byKey(const Key('tsm-unlock-remember')), findsOneWidget);
    await typePassword(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester, 4);
    expect(find.textContaining('(c) idle or screen lock, Touch ID'), findsOne);
    expect(
      find.byKey(const Key('tsm-settings-os-unlock-gate-only')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tsm-settings-os-unlock-saved')), findsOne);
  });

  testWidgets('no OS unlock (Linux): the master password only', (tester) async {
    await start(tester, osUnlock: false);
    expect(find.byKey(const Key('tsm-unlock-remember')), findsNothing);
    await typePassword(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester, 4);
    expect(
      find.byKey(const Key('tsm-settings-os-unlock-none')),
      findsOneWidget,
    );
    expect(find.textContaining('(c) idle or screen lock'), findsNothing);
  });

  testWidgets('stopping the service forgets the session item', (tester) async {
    service.lockMode = 'c';
    await start(tester);
    await typePassword(tester);
    expect(gated.handles, [handle()]);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester, 4);
    await tester.scrollUntilVisible(
      find.byKey(const Key('tsm-settings-stop')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const Key('tsm-settings-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-settings-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-settings-stop-confirm')));
    await wait(tester, 6);
    expect(gated.handles, isEmpty);
    expect(service.requests.map((r) => r['op']), contains('shutdown'));
  });
}
