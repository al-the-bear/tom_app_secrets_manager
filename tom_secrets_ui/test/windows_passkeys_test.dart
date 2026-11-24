// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Windows passkeys (part-os-integration, DP-120): the names
/// Windows lists (personal and shared vaults only, never a key, the line
/// the plugin reads), and the app registering the plugin, removing it and
/// writing the list after the unlock and a change. Demo data only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

/// A plugin port that records what the app does.
final class _Port implements TomSecretsWindowsPasskeysPort {
  TomSecretsWindowsPasskeysStatus current =
      TomSecretsWindowsPasskeysStatus.notRegistered;
  final List<List<TomSecretsWindowsPasskeyName>> synced = [];
  int registered = 0;
  int unregistered = 0;
  String? refuse;

  @override
  Future<TomSecretsWindowsPasskeysStatus> status() async => current;

  @override
  Future<void> register() async {
    if (refuse != null) throw TomSecretsWindowsPasskeysException(refuse!);
    registered++;
    current = TomSecretsWindowsPasskeysStatus.disabled;
  }

  @override
  Future<void> unregister() async {
    unregistered++;
    current = TomSecretsWindowsPasskeysStatus.notRegistered;
  }

  @override
  Future<void> syncCredentials(
    List<TomSecretsWindowsPasskeyName> names,
  ) async => synced.add(names);
}

Future<KdbxFile> _vault(void Function(KdbxFile) fill) async {
  final file = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: 'demo-key'),
    'demo',
    argon2: testArgon2,
  );
  fill(file);
  return file;
}

String _text(String field) =>
    utf8.decode(base64Url.decode(base64Url.normalize(field)));

void main() {
  test('Windows lists the passkeys of personal and shared vaults with a '
      'user handle, by name; the line carries no key', () async {
    final withHandle = await tomSecretsCreatePasskey(
      rpId: 'site.example',
      userHandle: Uint8List.fromList([1, 2, 3]),
      userName: 'alice',
    );
    // A passkey kept without its user handle (an import), which Windows
    // cannot list.
    final withoutHandle = TomSecretsPasskey(
      relyingParty: 'other.example',
      credentialId: 'AQID',
      privateKeyPem: withHandle.passkey.privateKeyPem,
      userName: 'bob',
    );
    final personal = await _vault((f) {
      tomSecretsKeepPasskey(f, withHandle.passkey);
      tomSecretsKeepPasskey(f, withoutHandle);
    });
    final system = await _vault((f) {
      TomSecretsMetadata(kind: TomSecretsVaultKind.system).writeTo(f);
      tomSecretsKeepPasskey(f, withHandle.passkey);
    });
    final names = tomSecretsWindowsPasskeyNames([
      TomSecretsStore.fromFile(personal, name: 'personal'),
      TomSecretsStore.fromFile(system, name: 'fleet'),
    ], isSystem: (s) => s == 'fleet');
    expect(names, hasLength(1));
    final name = names.single;
    expect(name.rpId, 'site.example');
    expect(name.credentialId, withHandle.passkey.credentialId);
    expect(name.userHandle, withHandle.passkey.userHandle);
    expect(name.userName, 'alice');

    final fields = name.toLine().split('\t');
    expect(fields, hasLength(6));
    expect(fields[0], withHandle.passkey.credentialId);
    expect(_text(fields[1]), 'site.example');
    expect(fields[3], withHandle.passkey.userHandle);
    expect(_text(fields[4]), 'alice');
    expect(name.toLine(), isNot(contains('PRIVATE')));
    expect(
      name.toLine(),
      isNot(contains(base64Url.encode(utf8.encode('BEGIN')))),
    );
  });

  group('the app', () {
    late FakeService service;
    late _Port port;

    setUp(() async {
      service = FakeService(await demoStores());
      port = _Port();
    });

    Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    Future<void> unlocked(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TomSecretsApp(
          host: TomSecretsHost(
            service: FakeHost(service),
            preferences: TomSecretsMemoryPreferences(),
            windowsPasskeys: port,
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
    }

    Future<void> settings(WidgetTester tester) async {
      await tester.tap(find.text('Settings'));
      await wait(tester);
      await tester.ensureVisible(
        find.byKey(const Key('tsm-settings-windows-passkeys')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('not registered: nothing is listed; Add to Windows registers '
        'it, says where Windows turns it on and lists the passkeys; Remove '
        'takes it out', (tester) async {
      await unlocked(tester);
      expect(port.synced, isEmpty);
      await settings(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tsm-windows-passkeys-state')))
            .data,
        'Tom Secrets Manager is not added to Windows.',
      );
      await tester.tap(find.byKey(const Key('tsm-windows-passkeys-register')));
      await wait(tester);
      expect(port.registered, 1);
      expect(port.synced, hasLength(1));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tsm-windows-passkeys-state')))
            .data,
        contains('Settings › Accounts › Passkeys › Advanced options'),
      );
      await tester.tap(
        find.byKey(const Key('tsm-windows-passkeys-unregister')),
      );
      await wait(tester);
      expect(port.unregistered, 1);
      expect(
        find.byKey(const Key('tsm-windows-passkeys-register')),
        findsOneWidget,
      );
    });

    testWidgets('registered: the unlock writes the list, a new passkey writes '
        'it again; a refusal is shown', (tester) async {
      port.current = TomSecretsWindowsPasskeysStatus.enabled;
      await unlocked(tester);
      expect(port.synced, hasLength(1));
      expect(port.synced.single, isEmpty);

      final reg = await tester.runAsync(
        () => tomSecretsCreatePasskey(
          rpId: 'db.example',
          userHandle: Uint8List.fromList([7, 7, 7]),
          userName: 'demo-user',
        ),
      );
      final session = Provider.of<TomSecretsSession>(
        tester.element(find.byType(TomSecretsMainShell)),
        listen: false,
      );
      await tester.runAsync(() => session.keepPasskey(reg!.passkey));
      await wait(tester, 5);
      expect(port.synced.last.single.credentialId, reg!.passkey.credentialId);
      expect(port.synced.last.single.rpId, 'db.example');

      await settings(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tsm-windows-passkeys-state')))
            .data,
        'Added to Windows and turned on; 1 passkey listed.',
      );
      await tester.tap(
        find.byKey(const Key('tsm-windows-passkeys-unregister')),
      );
      await wait(tester);
      port.refuse = 'Windows registers only a packaged plugin';
      await tester.tap(find.byKey(const Key('tsm-windows-passkeys-register')));
      await wait(tester);
      expect(
        find.text('Windows registers only a packaged plugin'),
        findsOneWidget,
      );
    });
  });
}
