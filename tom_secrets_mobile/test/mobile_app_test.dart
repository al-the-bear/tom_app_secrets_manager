// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app against a fake GitHub (part-mobile): set up by a pairing,
/// unlocked with the master password (the key file from the pairing), the
/// phone layout (bottom bar, vaults, entries, the entry), the system vault
/// read-only, the tablet layouts (rail, two and three panes), the
/// biometric unlock after the first password, the background lock and the
/// lock button. Demo data only.
library;

import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart'
    show TomClipboardPort, TomClipboardReceipt;
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/demo_vaults.dart';

final class _Clipboard implements TomClipboardPort {
  String? held;

  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async {
    held = text;
    return TomClipboardReceipt(text);
  }

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async {
    if (held != receipt.text) return false;
    held = null;
    return true;
  }
}

void main() {
  late FakeGitHubServer server;
  late DemoVaults demo;
  late TomInMemorySecretStore keychain;
  late TomInMemoryGatedSecretStore gated;
  late TomSecretsMemoryPreferences preferences;
  late _Clipboard clipboard;
  final paired = <String>[];
  final codes = <String>[];
  DateTime? expiry;
  late _Scanner scanner;
  late _Discovery lan;
  late TomSecretsPairingPeerKeys giverKeys;

  setUpAll(() async {
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
    );
  });

  setUp(() async {
    server = FakeGitHubServer();
    demo = DemoVaults(server);
    await demo.seed();
    keychain = TomInMemorySecretStore();
    gated = TomInMemoryGatedSecretStore();
    preferences = TomSecretsMemoryPreferences();
    clipboard = _Clipboard();
    paired.clear();
    codes.clear();
    expiry = null;
    scanner = _Scanner();
    lan = _Discovery();
  });

  Future<({String giver, TomSecretsPairingBundle bundle})> receive({
    required String address,
    required int port,
    required TomSecretsPairingCode code,
    required String device,
  }) async {
    paired.add('$device@$address:$port');
    codes.add(code.text);
    return (
      giver: 'mbp',
      bundle: TomSecretsPairingBundle(
        vaults: [
          TomSecretsPairingVault(
            name: 'primary',
            locator: demoPrimary,
            primary: true,
            keyFile: demo.keyFile.toBytes(),
          ),
        ],
        giverKeys: giverKeys,
        tokens: const [
          TomSecretsPairingToken(repository: demoRepo, token: demoToken),
        ],
      ),
    );
  }

  Widget app() => TomSecretsMobileApp(
    profileExpiry: () async => expiry,
    preferences: preferences,
    keychain: keychain,
    platform: 'ios',
    gated: gated,
    biometricLabel: 'Face ID',
    clipboard: clipboard,
    httpClient: server.client,
    githubBaseUrl: FakeGitHubServer.baseUrl,
    receive: receive,
    scanner: scanner,
    discovery: lan,
    ownAddresses: () async => [InternetAddress('10.8.0.6')],
  );

  Future<void> wait(WidgetTester tester, [int rounds = 4]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> setUpByPairing(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-device')),
      'iphone',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-address')),
      '10.8.0.2:47900',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-code')),
      TomSecretsPairingCode.generate().toString(),
    );
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-pair')));
    await wait(tester, 6);
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 14);
  }

  testWidgets('set up by a pairing, unlocked with the password: the phone '
      'layout lists the vaults; an entry opens; the system vault is '
      'read-only', (tester) async {
    size(tester, const Size(400, 860));
    await setUpByPairing(tester);
    expect(paired, ['iphone@10.8.0.2:47900']);
    expect(preferences.read(TomSecretsMobileKeys.primary), demoPrimary);
    expect(
      await keychain.read(
        tomSecretsGitHubTokenHandle('al-the-bear', 'demo-vaults'),
      ),
      demoToken,
    );
    expect(
      await keychain.read(
        TomSecretsVaultLocator.parse(demoPrimary).keyFileHandle,
      ),
      base64.encode(demo.keyFile.toBytes()),
    );
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);

    await unlock(tester);
    expect(find.byKey(const Key('tsm-mobile-tabs')), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const Key('tsm-mobile-vault-team')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('tsm-mobile-vault-fleet')),
        matching: find.textContaining('read-only on this device'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('tsm-mobile-vault-team')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-mobile-entry-Api')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-mobile-entry-Api')));
    await tester.pumpAndSettle();
    expect(find.byType(TomSecretsEntryEditor), findsOneWidget);
  });

  testWidgets('tablet widths: a rail with the list and the entry side by '
      'side; above 900 the three panes', (tester) async {
    size(tester, const Size(800, 1100));
    await setUpByPairing(tester);
    await unlock(tester);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const Key('tsm-mobile-tabs')), findsNothing);
    expect(find.text('Pick an entry'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-mobile-entry-Api')));
    await tester.pumpAndSettle();
    expect(find.byType(TomSecretsEntryEditor), findsOneWidget);

    tester.view.physicalSize = const Size(1300, 900);
    await tester.pumpAndSettle();
    expect(find.byType(TomSecretsVaultBrowser), findsOneWidget);
  });

  testWidgets('the first password keeps a saved item; the next unlock is '
      'by Face ID; the switch turns it off for good', (tester) async {
    size(tester, const Size(400, 860));
    await setUpByPairing(tester);
    await unlock(tester);
    final handle = TomSecretsOsUnlock.handleOf('primary');
    expect(gated.lifetimeOf(handle), TomGatedLifetime.saved);

    // Locked, the unlock screen asks Face ID at once and the vaults open
    // again without the password.
    final prompts = gated.prompts.length;
    await tester.tap(find.byKey(const Key('tsm-mobile-lock')));
    await wait(tester, 16);
    expect(gated.prompts.length, prompts + 1);
    expect(find.byKey(const Key('tsm-mobile-vault-team')), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-mobile-setting-biometric')));
    await wait(tester, 4);
    expect(gated.lifetimeOf(handle), isNull);
    expect(preferences.read(TomSecretsMobileKeys.biometric), 'off');

    await tester.tap(find.byKey(const Key('tsm-mobile-lock')));
    await wait(tester, 6);
    expect(find.byKey(const Key('tsm-unlock-os')), findsNothing);
    await unlock(tester);
    expect(gated.lifetimeOf(handle), isNull);
  });

  testWidgets('in the background past the lock timeout the app locks', (
    tester,
  ) async {
    size(tester, const Size(400, 860));
    await preferences.write(TomSecretsMobileKeys.lockSeconds, '0');
    // Without the biometric unlock, so the lock shows the password screen
    // (with it, the screen asks Face ID at once).
    await preferences.write(TomSecretsMobileKeys.biometric, 'off');
    await setUpByPairing(tester);
    await unlock(tester);
    expect(find.byKey(const Key('tsm-mobile-vault-team')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await wait(tester, 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await wait(tester, 6);
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
  });

  testWidgets('a copied password goes through the mobile clipboard and is '
      'cleared after the clipboard timeout', (tester) async {
    size(tester, const Size(400, 860));
    await preferences.write(TomSecretsMobileKeys.clipboardSeconds, '1');
    await setUpByPairing(tester);
    await unlock(tester);
    await tester.tap(find.text('Generator'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-mobile-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-use-generated')));
    await tester.pumpAndSettle();
    final made = tester
        .widget<SelectableText>(find.byKey(const Key('tsm-mobile-generated')))
        .data!;
    await tester.tap(find.text('Copy'));
    await wait(tester, 1);
    expect(clipboard.held, made);
    await tester.pump(const Duration(seconds: 2));
    await wait(tester, 1);
    expect(clipboard.held, isNull);
  });

  testWidgets('"Set this device up again" goes back to the setup screen', (
    tester,
  ) async {
    size(tester, const Size(400, 860));
    await setUpByPairing(tester);
    await unlock(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tsm-mobile-forget')),
      100,
    );
    await tester.tap(find.byKey(const Key('tsm-mobile-forget')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set up again'));
    await wait(tester, 4);
    expect(find.byKey(const Key('tsm-mobile-setup-pair')), findsOneWidget);
    expect(preferences.read(TomSecretsMobileKeys.primary), isNull);
  });

  testWidgets('two days before the iOS build stops starting, the shell asks '
      'for a reinstall', (tester) async {
    size(tester, const Size(400, 860));
    expiry = DateTime.now().add(const Duration(days: 5));
    await setUpByPairing(tester);
    await unlock(tester);
    expect(find.byKey(const Key('tsm-mobile-reinstall')), findsNothing);

    expiry = DateTime.now().add(const Duration(hours: 30));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    // The next start unlocks with the item kept behind Face ID.
    await wait(tester, 16);
    expect(find.byKey(const Key('tsm-mobile-reinstall')), findsOneWidget);
    expect(find.textContaining('install it again from Xcode'), findsOneWidget);
  });

  Future<void> nameDevice(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-device')),
      'iphone',
    );
  }

  testWidgets('the desktop\'s QR code fills the address nearest the phone '
      'and the code; Pair receives from there', (tester) async {
    size(tester, const Size(400, 860));
    await nameDevice(tester);
    final code = TomSecretsPairingCode.generate();
    scanner.next = TomSecretsPairingInvitation(
      addresses: ['192.168.1.20', '10.8.0.2'],
      port: 47900,
      code: code,
    ).text;
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-scan')));
    await wait(tester, 2);
    expect(scanner.titles, ['Scan the desktop\'s code']);
    expect(find.byKey(const Key('tsm-mobile-setup-scanned')), findsOneWidget);
    String field(String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
    expect(field('tsm-mobile-setup-address'), '10.8.0.2:47900');
    expect(field('tsm-mobile-setup-code'), code.text);
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-pair')));
    await wait(tester, 6);
    expect(paired, ['iphone@10.8.0.2:47900']);
    expect(codes, [code.text]);
    expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
  });

  testWidgets('another QR code is refused; closing the camera changes '
      'nothing', (tester) async {
    size(tester, const Size(400, 860));
    await nameDevice(tester);
    scanner.next = 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP';
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-scan')));
    await wait(tester, 2);
    expect(
      find.textContaining('That is not a desktop\'s pairing code'),
      findsOneWidget,
    );
    scanner.next = null;
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-scan')));
    await wait(tester, 2);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-mobile-setup-address')))
          .controller!
          .text,
      isEmpty,
    );
    expect(paired, isEmpty);
  });

  testWidgets('on the same network the code alone finds the desktop by its '
      'announcement', (tester) async {
    size(tester, const Size(400, 860));
    final code = TomSecretsPairingCode.generate();
    lan.adverts.add(
      TomSecretsPairingAdvert(
        device: 'mbp',
        number: code.number,
        port: 47911,
        addresses: const ['192.168.1.20', '10.8.0.2'],
      ),
    );
    await nameDevice(tester);
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-code')),
      code.text,
    );
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-pair')));
    await wait(tester, 6);
    expect(paired, ['iphone@10.8.0.2:47911']);
  });

  testWidgets('no window with that number on the network: the address is '
      'asked for', (tester) async {
    size(tester, const Size(400, 860));
    await nameDevice(tester);
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-code')),
      TomSecretsPairingCode.generate().text,
    );
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-pair')));
    await wait(tester, 4);
    expect(lan.browsed, 1);
    expect(find.textContaining('No machine on this network'), findsOneWidget);
    expect(paired, isEmpty);
  });

  testWidgets('the entry editor on the phone scans a TOTP code', (
    tester,
  ) async {
    size(tester, const Size(400, 860));
    await setUpByPairing(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-mobile-vault-team')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-mobile-entry-Api')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tsm-otp-scan')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    scanner.next = 'otpauth://totp/Demo?secret=JBSWY3DPEHPK3PXP';
    await tester.tap(find.byKey(const Key('tsm-otp-scan')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-field-otp')))
          .controller!
          .text,
      'otpauth://totp/Demo?secret=JBSWY3DPEHPK3PXP',
    );
  });
}

final class _Scanner implements TomSecretsCodeScanner {
  String? next;
  final List<String> titles = [];

  @override
  Future<String?> scan(BuildContext context, {required String title}) async {
    titles.add(title);
    return next;
  }
}

final class _Discovery implements TomSecretsPairingDiscovery {
  final List<TomSecretsPairingAdvert> adverts = [];
  int browsed = 0;

  @override
  Future<TomSecretsPairingAdvertising> advertise(
    TomSecretsPairingAdvert advert,
  ) => throw UnsupportedError('a phone does not give');

  @override
  Future<List<TomSecretsPairingAdvert>> browse({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    browsed++;
    return List.of(adverts);
  }
}
