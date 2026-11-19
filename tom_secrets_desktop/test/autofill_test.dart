// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The macOS AutoFill port over its channel (part-os-integration, DP-50):
/// what each call sends, the state read back, a build without the plugin
/// unavailable, no AutoFill off macOS. Demo data only.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(tomSecretsAutofillChannel, null),
  );

  test('every call goes to the channel with its arguments; the state is '
      'read back', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(tomSecretsAutofillChannel, (call) async {
      calls.add(call);
      return call.method == 'state'
          ? {'available': true, 'providerEnabled': true}
          : true;
    });
    final port = TomSecretsMacAutofill();
    final state = await port.state();
    expect(state.available, isTrue);
    expect(state.providerEnabled, isTrue);
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    await port.storeKey(key, 'demo-key-1');
    await port.writeSnapshot(Uint8List.fromList([1, 2, 3]));
    await port.setIdentities(const [
      TomSecretsAutofillIdentity(
        domain: 'mail.example.com',
        userName: 'demo-user',
        recordIdentifier: 'team/~01',
      ),
    ]);
    await port.remove();
    await port.openSettings();
    expect(calls.map((c) => c.method), [
      'state',
      'storeKey',
      'writeSnapshot',
      'setIdentities',
      'remove',
      'openSettings',
    ]);
    expect(calls[1].arguments, {'key': key, 'keyId': 'demo-key-1'});
    expect(calls[3].arguments, {
      'identities': [
        {
          'domain': 'mail.example.com',
          'userName': 'demo-user',
          'recordIdentifier': 'team/~01',
        },
      ],
    });
  });

  test('the build says why it has none; a build without the plugin is '
      'unavailable; no AutoFill off macOS', () async {
    messenger.setMockMethodCallHandler(
      tomSecretsAutofillChannel,
      (call) async => {
        'available': false,
        'reason': 'This build has no AutoFill provider.',
        'providerEnabled': false,
      },
    );
    final state = await TomSecretsMacAutofill().state();
    expect(state.available, isFalse);
    expect(state.unavailableReason, 'This build has no AutoFill provider.');
    messenger.setMockMethodCallHandler(tomSecretsAutofillChannel, null);
    expect((await TomSecretsMacAutofill().state()).available, isFalse);
    expect(tomSecretsDesktopAutofill(operatingSystem: 'linux'), isNull);
    expect(tomSecretsDesktopAutofill(operatingSystem: 'windows'), isNull);
    expect(
      tomSecretsDesktopAutofill(operatingSystem: 'macos'),
      isA<TomSecretsMacAutofill>(),
    );
  });
}
