// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop pieces that need no window: one instance per user, the
/// device's preferences file, the capture guard per platform, the tray icon
/// assets.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tsmd'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a second launch brings the first one to the front and ends', () async {
    final port = File('${dir.path}/app.port');
    var activated = 0;
    final first = await TomSecretsSingleInstance.claim(
      port,
      onActivate: () => activated++,
    );
    expect(first, isNotNull);
    final second = await TomSecretsSingleInstance.claim(
      port,
      onActivate: () => fail('the second instance is not the one'),
    );
    expect(second, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(activated, 1);
    await first!.close();
    expect(port.existsSync(), isFalse);
    final after = await TomSecretsSingleInstance.claim(port, onActivate: () {});
    expect(after, isNotNull, reason: 'the first one is gone');
    await after!.close();
  });

  test('a stale port file does not stop the start', () async {
    final port = File('${dir.path}/app.port')..writeAsStringSync('1\n');
    final instance = await TomSecretsSingleInstance.claim(
      port,
      onActivate: () {},
    );
    expect(instance, isNotNull);
    await instance!.close();
  });

  test('the preferences are kept in a file of their own', () async {
    final file = File('${dir.path}/app-preferences.json');
    final prefs = await TomSecretsFilePreferences.open(file);
    expect(prefs.read('view.layout'), isNull);
    await prefs.write('view.layout', 'list');
    final again = await TomSecretsFilePreferences.open(file);
    expect(again.read('view.layout'), 'list');
    await again.write('view.layout', null);
    expect((await TomSecretsFilePreferences.open(file)).read('view.layout'), isNull);
    file.writeAsStringSync('not json');
    expect((await TomSecretsFilePreferences.open(file)).read('x'), isNull);
  });

  test('the capture guard: macOS and Windows through the channel, Linux '
      'cannot', () async {
    final calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tomSecretsCaptureChannel, (call) async {
          calls.add(call.arguments);
          return true;
        });
    final mac = TomSecretsPlatformCaptureGuard(operatingSystem: 'macos');
    expect(mac.supported, isTrue);
    expect(await mac.setExcluded(true), isTrue);
    expect(await mac.setExcluded(false), isTrue);
    expect(calls, [true, false]);
    final linux = TomSecretsPlatformCaptureGuard(operatingSystem: 'linux');
    expect(linux.supported, isFalse);
    expect(await linux.setExcluded(true), isFalse);
    expect(calls, hasLength(2));
  });

  test('a capture call the platform does not answer is not done', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          tomSecretsCaptureChannel,
          (call) async => throw PlatformException(code: 'x'),
        );
    final windows = TomSecretsPlatformCaptureGuard(operatingSystem: 'windows');
    expect(await windows.setExcluded(true), isFalse);
  });

  test('every tray icon is an asset of the package', () {
    for (final state in TomSecretsTrayState.values) {
      final path = tomSecretsTrayIcon(state);
      expect(path, startsWith('packages/tom_secrets_desktop/assets/tray/'));
      final file = File(path.replaceFirst('packages/tom_secrets_desktop/', ''));
      expect(file.existsSync(), isTrue, reason: path);
    }
  });
}
