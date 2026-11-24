// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The Windows passkey plugin port (part-os-integration, DP-120):
/// the commands run, the state read back, the names on standard input, a
/// refusal said as the plugin says it, no plugin off Windows. Demo data
/// only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  test('each call runs the plugin with its command; the state is read; '
      'the names go on standard input', () async {
    final runs = <(List<String>, String)>[];
    var state = 'not-registered';
    final port = TomSecretsPluginPasskeys(
      r'C:\tsm\bin\tsm-passkey-plugin.exe',
      run: (exe, args, input) async {
        expect(exe, r'C:\tsm\bin\tsm-passkey-plugin.exe');
        runs.add((args, input));
        if (args.single == '--register') state = 'disabled';
        return (
          exitCode: 0,
          stdout: args.single == '--state' ? '$state\r\n' : 'ok\r\n',
          stderr: '',
        );
      },
    );
    expect(await port.status(), TomSecretsWindowsPasskeysStatus.notRegistered);
    await port.register();
    expect(await port.status(), TomSecretsWindowsPasskeysStatus.disabled);
    const name = TomSecretsWindowsPasskeyName(
      credentialId: 'AQID',
      rpId: 'webauthn.io',
      rpName: 'webauthn.io',
      userHandle: 'BAUG',
      userName: 'demo',
      displayName: 'demo',
    );
    await port.syncCredentials(const [name, name]);
    await port.unregister();
    expect(runs.map((r) => r.$1.single), [
      '--state',
      '--register',
      '--state',
      '--sync-credentials',
      '--unregister',
    ]);
    expect(runs[3].$2, '${name.toLine()}\n${name.toLine()}\n');
    state = 'enabled';
    expect(await port.status(), TomSecretsWindowsPasskeysStatus.enabled);
  });

  test('a refusal is said as the plugin says it', () async {
    final port = TomSecretsPluginPasskeys(
      'tsm-passkey-plugin.exe',
      run: (exe, args, input) async => (
        exitCode: 1,
        stdout: '',
        stderr:
            'tsm-passkey-plugin: Windows registers only a packaged plugin: '
            'install the app\'s MSIX (0x80073D54)\r\n',
      ),
    );
    await expectLater(
      port.register(),
      throwsA(
        isA<TomSecretsWindowsPasskeysException>().having(
          (e) => e.message,
          'message',
          startsWith('Windows registers only a packaged plugin'),
        ),
      ),
    );
  });

  test('the plugin is beside the service, and only on Windows', () {
    expect(
      tomSecretsPasskeyPluginBeside('/opt/tsm/bin/tom_secrets_service'),
      '/opt/tsm/bin/tsm-passkey-plugin.exe',
    );
    expect(
      tomSecretsDesktopWindowsPasskeys(
        serviceExecutable: '/opt/tsm/bin/tom_secrets_service',
        operatingSystem: 'macos',
      ),
      isNull,
    );
    expect(
      tomSecretsDesktopWindowsPasskeys(
        serviceExecutable: '/nowhere/tom_secrets_service.exe',
        operatingSystem: 'windows',
      ),
      isNull,
      reason: 'a build without the plugin',
    );
  });
}
