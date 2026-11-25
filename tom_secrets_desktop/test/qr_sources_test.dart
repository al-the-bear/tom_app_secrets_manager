// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's QR sources: the platform code's answers turned into
/// images (pixels in either order, an image file's bytes, nothing), its
/// refusals into the user's message, the screen capture offered by OS
/// version, and Linux's clipboard through wl-paste or xclip.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(tomSecretsQrChannel, null));

  void answer(Object? Function(MethodCall call) handler) =>
      messenger.setMockMethodCallHandler(
        tomSecretsQrChannel,
        (call) async => handler(call),
      );

  test('the platform code\'s answers: pixels (BGRA on Windows), a file\'s '
      'bytes, nothing', () async {
    final sources = TomSecretsDesktopQrSources(platform: 'windows');
    final calls = <String>[];
    answer((call) {
      calls.add(call.method);
      return {'width': 2, 'height': 1, 'order': 'bgra', 'pixels': Uint8List(8)};
    });
    expect(await sources.clipboardImage(), isA<TomSecretsQrImage>());
    answer(
      (call) => {
        'encoded': Uint8List.fromList([1, 2, 3]),
      },
    );
    expect(await sources.captureScreen(), isA<TomSecretsQrImage>());
    answer((call) => null);
    expect(await sources.captureScreen(), isNull, reason: 'cancelled');
    expect(calls, ['clipboardImage']);
  });

  test('a refusal reaches the user as its message', () async {
    answer(
      (call) => throw PlatformException(
        code: 'unsupported',
        message: 'reading the screen needs macOS 14 or later',
      ),
    );
    await expectLater(
      TomSecretsDesktopQrSources(platform: 'macos').captureScreen(),
      throwsA(
        isA<TomSecretsQrException>().having(
          (e) => e.message,
          'message',
          'reading the screen needs macOS 14 or later',
        ),
      ),
    );
  });

  test('the screen capture is offered from macOS 14 and Windows 10 1903', () {
    bool can(String platform, String version) => TomSecretsDesktopQrSources(
      platform: platform,
      osVersion: version,
    ).canCaptureScreen;
    expect(can('macos', 'Version 15.6 (Build 24G84)'), isTrue);
    expect(can('macos', 'Version 14.0 (Build 23A344)'), isTrue);
    expect(can('macos', 'Version 13.6 (Build 22G120)'), isFalse);
    expect(can('windows', '"Windows 11 Pro" 10.0 (Build 26100)'), isTrue);
    expect(can('windows', '"Windows 10 Pro" 10.0 (Build 17763)'), isFalse);
    expect(can('linux', 'Linux 6.8.0'), isTrue);
  });

  test('Linux: the clipboard through xclip, or what to install', () async {
    final runs = <String>[];
    final sources = TomSecretsDesktopQrSources(
      platform: 'linux',
      run: (tool, args) async {
        runs.add(tool);
        if (tool == 'wl-paste') throw const ProcessException('wl-paste', []);
        return ProcessResult(1, 0, [0x89, 0x50, 0x4e, 0x47], <int>[]);
      },
    );
    expect(await sources.clipboardImage(), isA<TomSecretsQrImage>());
    expect(runs.last, 'xclip');

    final none = TomSecretsDesktopQrSources(
      platform: 'linux',
      run: (tool, args) async => throw ProcessException(tool, args),
    );
    await expectLater(
      none.clipboardImage(),
      throwsA(
        isA<TomSecretsQrException>().having(
          (e) => e.message,
          'message',
          contains('installed'),
        ),
      ),
    );
  });

  test('Linux: the screen through the portal; cancelled is null', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
    expect(
      await TomSecretsDesktopQrSources(
        platform: 'linux',
        portal: () async => png,
      ).captureScreen(),
      isA<TomSecretsQrImage>(),
    );
    expect(
      await TomSecretsDesktopQrSources(
        platform: 'linux',
        portal: () async => null,
      ).captureScreen(),
      isNull,
    );
  });
}
