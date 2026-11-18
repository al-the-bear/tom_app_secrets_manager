// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The typed SSH key in the app against the fake service: phase A's notes
/// holding a key retyped at the load (part-structure, DP-5), a key
/// generated into an entry (DP-179) or taken from a file, and the entry
/// editor's SSH key section. Demo keys only.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

final class _Files implements TomSecretsFiles {
  ({String name, Uint8List bytes})? next;

  @override
  Future<({String name, Uint8List bytes})?> pick() async => next;

  @override
  Future<bool> save(String name, Uint8List bytes) async => false;

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => null;

  @override
  Future<Uint8List> read(String path) async => Uint8List(0);

  @override
  Future<bool> delete(String path) async => false;
}

void main() {
  late Uint8List demoKey;
  late FakeService service;
  late _Files files;
  late TomSecretsHost host;

  setUpAll(() async {
    demoKey = (await tomSecretsGenerateSshKey(comment: 'demo')).privateKey;
  });

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Recovery codes', fields: {'tsm.type': 'note'});
      addEntry(
        f,
        'Ssh/Old deploy key',
        fields: {'tsm.type': 'note'},
      ).createBinary(isProtected: true, name: 'id_ed25519', bytes: demoKey);
      addEntry(f, 'Servers/Box', password: 'demo-box-pw');
    });
    service = FakeService([FakeStore('primary', demoPassword, primary)]);
    files = _Files();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      files: files,
    );
  });

  Future<void> wait(WidgetTester tester, [int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<TomSecretsSession> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
    return tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
  }

  TomSecretsEntryView view(TomSecretsSession session, String title) =>
      session.index.firstWhere((v) => v.title == title);

  testWidgets('the load retypes a note holding a key and saves the vault; '
      'a plain note stays a note', (tester) async {
    final session = await unlocked(tester);
    expect(session.migratedSshKeys, {'primary': 1});
    expect(service.saves, hasLength(1));
    final key = view(session, 'Old deploy key');
    expect(key.type, TomSecretsEntryType.sshKey);
    expect(
      key.entry.getBinary(KdbxKey(tomSecretsKeeAgentSettingsName)),
      isNotNull,
    );
    expect(view(session, 'Recovery codes').type, TomSecretsEntryType.note);

    // A second load finds nothing to migrate.
    await tester.runAsync(session.load);
    await tester.pump();
    expect(service.saves, hasLength(1));
  });

  testWidgets('the editor: a key generated into an entry, its public key '
      'and fingerprint; replacing asks first; a file without a key is '
      'refused', (tester) async {
    final session = await unlocked(tester);
    final box = view(session, 'Box');
    await tester.tap(find.text('List'));
    await tester.pump();
    await tester.tap(find.byKey(Key('tsm-entry-${box.ref}')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('tsm-entry-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSH key').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-ssh-none')), findsOneWidget);
    expect(find.byKey(const Key('tsm-field-user')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('tsm-ssh-generate')));
    await tester.tap(find.byKey(const Key('tsm-ssh-generate')));
    await wait(tester, 10);
    final saved = service.saves.length;
    expect(saved, greaterThanOrEqualTo(2));
    final entry = view(session, 'Box');
    expect(entry.type, TomSecretsEntryType.sshKey);
    final key = tomSecretsSshKeyOf(entry.entry)!;
    expect(key.name, 'id_ed25519');
    expect(key.info.keyType, 'ssh-ed25519');
    expect(key.info.comment, 'Box');
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-ssh-public')))
          .data,
      key.info.publicKey,
    );
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-ssh-fingerprint')))
          .data,
      startsWith('SHA256:'),
    );

    // Replacing asks; Cancel keeps the key.
    await tester.ensureVisible(find.byKey(const Key('tsm-ssh-generate-rsa')));
    await tester.tap(find.byKey(const Key('tsm-ssh-generate-rsa')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-ssh-replace')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.saves, hasLength(saved));

    // A file without a key is refused, nothing written.
    files.next = (name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3]));
    await tester.ensureVisible(find.byKey(const Key('tsm-ssh-file')));
    await tester.tap(find.byKey(const Key('tsm-ssh-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-ssh-replace-ok')));
    await wait(tester);
    expect(find.byKey(const Key('tsm-ssh-error')), findsOneWidget);
    expect(service.saves, hasLength(saved));

    // A key file replaces the key; the old one is in the history.
    files.next = (name: 'id_ed25519_box', bytes: demoKey);
    await tester.tap(find.byKey(const Key('tsm-ssh-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-ssh-replace-ok')));
    await wait(tester);
    expect(service.saves, hasLength(saved + 1));
    final replaced = tomSecretsSshKeyOf(view(session, 'Box').entry)!;
    expect(replaced.name, 'id_ed25519_box');
    expect(replaced.info.comment, 'demo');
  });

  test('the session generates RSA for a tool that needs RSA', () async {
    final connection = TomSecretsServiceConnection(FakeHost(service));
    final session = TomSecretsSession(
      connection,
      TomSecretsMemoryPreferences(),
    );
    addTearDown(() {
      session.dispose();
      connection.dispose();
    });
    await connection.connect();
    await connection.unlock(demoPassword);
    while (session.loading || service.saves.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final ref = view(session, 'Box').ref;
    // 2048 bits keep the test short; the app asks for the default 4096.
    final info = await session.generateSshKey(
      ref,
      algorithm: TomSecretsSshKeyAlgorithm.rsa,
      rsaBits: 2048,
    );
    expect(info.keyType, 'ssh-rsa');
    expect(info.bits, 2048);
    final key = tomSecretsSshKeyOf(session.entryOf(ref)!)!;
    expect(key.name, 'id_rsa');
    expect(key.info.publicKey, info.publicKey);
    await expectLater(
      session.setSshKeyFile(ref, 'x', Uint8List.fromList([1])),
      throwsFormatException,
    );
  });
}
