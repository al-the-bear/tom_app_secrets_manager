// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The typed certificate and PGP key entries in the app against the fake
/// service (part-app, BP-33, DP-179): the entry editor's sections generate
/// one (ECDSA P-384), take a file, refuse a file without one, show what the
/// key says, and the form keeps the passphrase and Expires the key wrote.
/// Demo keys only.
library;

import 'dart:convert';
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
  late FakeService service;
  late _Files files;
  late TomSecretsHost host;

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Servers/Web', password: 'old');
      addEntry(f, 'Mail/Signing', fields: {'UserName': 'demo@example.com'});
      addEntry(f, 'Mail/Partner');
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
    tester.view.physicalSize = const Size(1700, 1400);
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

  Future<void> open(
    WidgetTester tester,
    TomSecretsSession session,
    String title,
    String type,
  ) async {
    await tester.tap(find.text('List'));
    await tester.pump();
    await tester.tap(find.byKey(Key('tsm-entry-${view(session, title).ref}')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-entry-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(type).last);
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await wait(tester, 1);
    }
    expect(done(), isTrue);
  }

  testWidgets('a certificate generated into an entry: what it says, its '
      'request for a CA, Expires; a file without one refused; a PEM file '
      'taken', (tester) async {
    final session = await unlocked(tester);
    await open(tester, session, 'Web', 'Certificate');
    expect(find.byKey(const Key('tsm-cert-none')), findsOneWidget);
    expect(find.byKey(const Key('tsm-field-user')), findsNothing);
    expect(find.text('Passphrase'), findsOneWidget);
    final before = service.saves.length;

    await tester.ensureVisible(find.byKey(const Key('tsm-cert-generate')));
    await tester.tap(find.byKey(const Key('tsm-cert-generate')));
    await tester.pumpAndSettle();
    // The common name defaults to the title.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-cert-name')))
          .controller!
          .text,
      'Web',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-cert-name')),
      'web.example',
    );
    await tester.enterText(find.byKey(const Key('tsm-cert-days')), '20');
    await tester.tap(find.byKey(const Key('tsm-cert-generate-go')));
    await tester.pump();
    await until(tester, () => service.saves.length > before);
    await wait(tester, 2);

    final entry = view(session, 'Web');
    expect(entry.type, TomSecretsEntryType.certificate);
    final info = tomSecretsCertificateOf(entry.entry)!;
    expect(info.subject, 'web.example');
    expect(info.keyDescription, 'ECDSA P-384');
    expect(entry.entry.times.expiryTime.get(), info.notAfter);
    expect(
      tomSecretsTypedFileField(entry.entry),
      'attachment:$tomSecretsCertificateKeyAttachment',
    );
    expect(find.byKey(const Key('tsm-cert-summary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-cert-copy')), findsOneWidget);
    expect(find.byKey(const Key('tsm-cert-copy-csr')), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-cert-fingerprint')))
          .data,
      info.sha256Fingerprint,
    );

    // A file without a certificate: refused after the replace question,
    // nothing written.
    final saved = service.saves.length;
    files.next = (name: 'notes.txt', bytes: Uint8List.fromList([65, 66]));
    await tester.ensureVisible(find.byKey(const Key('tsm-cert-file')));
    await tester.tap(find.byKey(const Key('tsm-cert-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-typed-replace-ok')));
    await wait(tester);
    expect(find.byKey(const Key('tsm-cert-error')), findsOneWidget);
    expect(service.saves, hasLength(saved));

    // A PEM with its key replaces it; the old one is in the history.
    final other = tomSecretsGenerateCertificate(commonName: 'new.example');
    files.next = (
      name: 'new.pem',
      bytes: Uint8List.fromList(
        utf8.encode('${other.certificatePem}\n${other.privateKeyPem}'),
      ),
    );
    await tester.tap(find.byKey(const Key('tsm-cert-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-typed-replace-ok')));
    await until(tester, () => service.saves.length > saved);
    final replaced = view(session, 'Web').entry;
    expect(tomSecretsCertificateOf(replaced)!.subject, 'new.example');
    expect(
      utf8.decode(
        replaced
            .getBinary(const KdbxKey(tomSecretsCertificateKeyAttachment))!
            .value,
      ),
      other.privateKeyPem,
    );
    expect(replaced.history, isNotEmpty);
  });

  testWidgets('a PGP key generated into an entry: the passphrase in the form '
      'survives a later save; someone\'s public key taken alone', (
    tester,
  ) async {
    final session = await unlocked(tester);
    await open(tester, session, 'Signing', 'PGP key');
    expect(find.byKey(const Key('tsm-pgp-none')), findsOneWidget);
    final before = service.saves.length;
    await tester.ensureVisible(find.byKey(const Key('tsm-pgp-generate')));
    await tester.tap(find.byKey(const Key('tsm-pgp-generate')));
    await tester.pumpAndSettle();
    // The user id from the title and the mail address in the user name.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-pgp-user-id')))
          .controller!
          .text,
      'Signing <demo@example.com>',
    );
    await tester.tap(find.byKey(const Key('tsm-pgp-generate-go')));
    await tester.pump();
    await until(tester, () => service.saves.length > before);
    await wait(tester, 2);

    final entry = view(session, 'Signing').entry;
    final info = tomSecretsPgpKeyOf(entry)!;
    expect(info.isPrivate, isTrue);
    expect(info.keyDescription, 'ECDSA 384');
    expect(info.userIds, ['Signing <demo@example.com>']);
    expect(info.expires, isNotNull);
    expect(entry.times.expiryTime.get(), info.expires);
    final passphrase = entry.getString(KdbxKeyCommon.PASSWORD)!.getText();
    expect(passphrase, hasLength(32));
    expect(find.byKey(const Key('tsm-pgp-summary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-pgp-copy')), findsOneWidget);

    // An edit of the form saved afterwards keeps the passphrase and Expires.
    final notes = find.byKey(const Key('tsm-field-notes'));
    await tester.ensureVisible(notes);
    await tester.enterText(notes, 'Release signing');
    await tester.pump();
    final saved = service.saves.length;
    await tester.ensureVisible(find.byKey(const Key('tsm-save-entry')));
    await tester.tap(find.byKey(const Key('tsm-save-entry')));
    await until(tester, () => service.saves.length > saved);
    final after = view(session, 'Signing').entry;
    expect(after.getString(KdbxKeyCommon.PASSWORD)!.getText(), passphrase);
    expect(after.times.expires.get(), isTrue);
    expect(after.times.expiryTime.get(), info.expires);
    expect(after.getString(TomSecretsEntryFields.type)!.getText(), 'pgp-key');

    // Someone's public key alone.
    final partner = tomSecretsGeneratePgpKey(userId: 'Partner <p@example.com>');
    await open(tester, session, 'Partner', 'PGP key');
    files.next = (
      name: 'partner.asc',
      bytes: Uint8List.fromList(utf8.encode(partner.publicArmored)),
    );
    final s2 = service.saves.length;
    await tester.ensureVisible(find.byKey(const Key('tsm-pgp-file')));
    await tester.tap(find.byKey(const Key('tsm-pgp-file')));
    await until(tester, () => service.saves.length > s2);
    final theirs = tomSecretsPgpKeyOf(view(session, 'Partner').entry)!;
    expect(theirs.isPrivate, isFalse);
    expect(theirs.fingerprint, partner.info.fingerprint);
  });
}
