// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's screenshots for its user guide (`doc/images/`): the app
/// set up by a pairing over a fake GitHub and the demo vaults, unlocked, on
/// a phone (390×844) and a tablet (1024×1366), in the light and the dark
/// theme, with the real fonts. Runs only with
/// `flutter test --tags screenshots --update-goldens`, which writes the
/// files; a normal run skips it. Demo data only.
@Tags(['screenshots'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/screenshots.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import '../support/demo_vaults.dart';

/// Where the mobile guide keeps its images, from this file.
const _images = '../../doc/images';

void main() {
  late TomSecretsPairingPeerKeys giverKeys;

  setUpAll(() async {
    await tomSecretsLoadScreenshotFonts();
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
    );
  });

  Future<void> wait(WidgetTester tester, [int rounds = 4]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// The app paired with the demo vaults and unlocked, at [size] in [theme].
  Future<void> unlocked(
    WidgetTester tester,
    Size size,
    Brightness theme,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = theme;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final server = FakeGitHubServer();
    final demo = DemoVaults(server);
    await tester.runAsync(demo.seed);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('tsm-screenshot'),
        child: TomSecretsMobileApp(
          profileExpiry: () async => null,
          preferences: TomSecretsMemoryPreferences(),
          keychain: TomInMemorySecretStore(),
          platform: 'android',
          gated: TomInMemoryGatedSecretStore(),
          biometricLabel: 'Fingerprint',
          httpClient: server.client,
          githubBaseUrl: FakeGitHubServer.baseUrl,
          ownAddresses: () async => [InternetAddress('10.8.0.6')],
          receive:
              ({
                address,
                port,
                relay,
                relayToken,
                required code,
                required device,
              }) async => (
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
                    TomSecretsPairingToken(
                      repository: demoRepo,
                      token: demoToken,
                    ),
                  ],
                ),
                ownTokens: const <String, String>{},
              ),
        ),
      ),
    );
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-device')),
      'demo-phone',
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
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 14);
  }

  for (final (device, size) in [
    ('phone', TomSecretsScreenshotSizes.phone),
    ('tablet', TomSecretsScreenshotSizes.tablet),
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('the vaults on a $device (${theme.name})', (tester) async {
        await unlocked(tester, size, theme);
        // The phone lists the vaults; the tablet, wider than 900, shows the
        // desktop's three panes.
        expect(
          device == 'phone'
              ? find.byKey(const Key('tsm-mobile-vault-team'))
              : find.byType(TomSecretsVaultBrowser),
          findsOneWidget,
        );
        await expectLater(
          find.byKey(const Key('tsm-screenshot')),
          matchesGoldenFile(
            '$_images/${tomSecretsScreenshotName('vaults-$device', 'unlocked', theme)}',
          ),
        );
      }, skip: tomSecretsScreenshotsSkip(autoUpdateGoldenFiles) != null);
    }
  }
}
