// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop app's screenshots for its user guide
/// (`tom_secrets_app/doc/images/`): each screen pumped over the fake service
/// and the demo vaults, at 1440×900, in the light and the dark theme, with
/// the real fonts. Runs only with
/// `flutter test --tags screenshots --update-goldens`, which writes the
/// files; a normal run skips it. Demo data only.
@Tags(['screenshots'])
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_ui/screenshots.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import '../support/fake_service.dart';

/// Where the desktop app's guide keeps its images, from this file.
const _images = '../../../tom_secrets_app/doc/images';

void main() {
  setUpAll(tomSecretsLoadScreenshotFonts);

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// The app over the demo vaults, unlocked, at the desktop size in [theme].
  Future<void> unlocked(WidgetTester tester, Brightness theme) async {
    tester.view.physicalSize = TomSecretsScreenshotSizes.desktop;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = theme;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final service = FakeService(await tester.runAsync(demoStores) ?? []);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('tsm-screenshot'),
        child: TomSecretsApp(
          host: TomSecretsHost(
            service: FakeHost(service),
            preferences: TomSecretsMemoryPreferences(),
          ),
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
    await tester.pumpAndSettle();
  }

  for (final theme in Brightness.values) {
    testWidgets('the vault browser, unlocked (${theme.name})', (tester) async {
      await unlocked(tester, theme);
      expect(find.byType(TomSecretsMainShell), findsOneWidget);
      await expectLater(
        find.byKey(const Key('tsm-screenshot')),
        matchesGoldenFile(
          '$_images/${tomSecretsScreenshotName('vaults', 'unlocked', theme)}',
        ),
      );
    }, skip: tomSecretsScreenshotsSkip(autoUpdateGoldenFiles) != null);
  }
}
