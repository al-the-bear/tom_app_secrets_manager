// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The app's life in the background (part-mobile, DP-131, DP-151)
/// against a fake GitHub: while hidden and not yet locked, the vaults held
/// in memory keep being refreshed, read-only (another device's change comes
/// in, a save that waits is not written). Demo data only.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsMemoryPreferences;

import 'support/demo_vaults.dart';
import 'support/net_switch.dart';

void main() {
  testWidgets('hidden: the copies in memory follow another device, a save '
      'that waits stays unwritten', (tester) async {
    late DemoVaults demo;
    late TomSecretsMobileEngine engine;
    late NetSwitch net;
    final changed = <String>[];
    // The refresh interval keeps a vault from being fetched again within
    // minutes: the test moves this clock past it.
    var ahead = Duration.zero;

    Future<List<String?>> titlesOnGitHub() async => [
      for (final e in (await demo.fetch(
        demoTeam,
        demo.teamCredentials,
      )).body.rootGroup.entries)
        e.getString(KdbxKeyCommon.TITLE)?.getText(),
    ];

    Future<void> mbpAdds(String title) async {
      final mbp = await demo.fetch(demoTeam, demo.teamCredentials);
      mbp.body.rootGroup.addEntry(
        KdbxEntry.create(mbp, mbp.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue(title)),
      );
      await demo.put(demoTeam, mbp);
    }

    await tester.runAsync(() async {
      final server = FakeGitHubServer();
      demo = DemoVaults(server);
      await demo.seed();
      final keychain = TomInMemorySecretStore();
      await demo.fillKeychain(keychain);
      net = NetSwitch(server.client);
      final preferences = TomSecretsMemoryPreferences();
      // The lock comes long after the test; every refresh is due.
      await preferences.write(TomSecretsMobileKeys.lockSeconds, '3600');
      engine = TomSecretsMobileEngine(
        primaryLocator: demoPrimary,
        device: 'demo-phone',
        platform: 'android',
        keychain: keychain,
        preferences: preferences,
        httpClient: net,
        githubBaseUrl: FakeGitHubServer.baseUrl,
        clock: () => DateTime.now().add(ahead),
      );
      engine.events.listen((e) {
        if (e['op'] == 'store_changed') changed.add(e['store']! as String);
      });
      await engine.request('unlock', {'password': demoPassword});
    });
    addTearDown(engine.close);

    await tester.pumpWidget(
      TomSecretsMobileLifecycle(
        engine: engine,
        tick: const Duration(milliseconds: 100),
        child: const SizedBox(),
      ),
    );
    // The lifecycle's timer runs in the test's fake time: each tick is
    // pumped, then the engine's work (real I/O against the fake GitHub) is
    // given real time to finish.
    Future<void> ticks([int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    // A save made without a network waits in memory (before any tick, so
    // no refresh runs meanwhile).
    await tester.runAsync(() async {
      net.down = true;
      final file = await engine.request('vaultFile', {'store': 'team'});
      final opened = await KdbxFormat().read(
        base64.decode(file['bytes']! as String),
        demo.teamCredentials,
      );
      opened.body.rootGroup.addEntry(
        KdbxEntry.create(opened, opened.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Offline')),
      );
      await engine.request('save', {
        'store': 'team',
        'bytes': base64.encode(await opened.save()),
        'baseRevision': file['revision'],
      });
      net.down = false;
      await mbpAdds('From mbp');
    });

    // To the background: the refresh fetches mbp's change into memory and
    // writes nothing.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    changed.clear();
    ahead += const Duration(minutes: 16);
    await ticks();
    expect(engine.isLocked, isFalse);
    expect(changed, contains('team'));
    expect(await tester.runAsync(titlesOnGitHub), isNot(contains('Offline')));

    // The return writes the save in the foreground refresh: the engine's
    // test of the background refresh shows it (`mobile_engine_test.dart`).
  });
}
