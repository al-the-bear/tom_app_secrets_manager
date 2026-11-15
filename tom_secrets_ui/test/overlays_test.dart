// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Overlays and system secrets in the session (part-app, Overlay editor,
/// Environments, Conflicts; BP-25): the resolution model over the open
/// vaults, the matrix, "which value does … get?", creating, editing and
/// removing an overlay, the readers of an entry, the vault-aware and uniform
/// views, the conflicts settled field by field, and a file opened for
/// editing only. Demo data only.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_client/tom_secrets_client.dart'
    show TomSecretBinding;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeService service;
  late TomSecretsServiceConnection connection;
  late TomSecretsSession session;
  late TomSecretsMemoryPreferences prefs;
  late Uint8List staging;

  setUp(() async {
    final demo = await systemStores();
    staging = demo.staging;
    service = FakeService(demo.stores);
    connection = TomSecretsServiceConnection(FakeHost(service));
    prefs = TomSecretsMemoryPreferences();
    session = TomSecretsSession(connection, prefs);
    await connection.connect();
    await connection.unlock(demoPassword);
    await settle();
    while (session.loading) {
      await settle();
    }
  });

  tearDown(() {
    session.dispose();
    connection.dispose();
  });

  TomSecretsEntryView view(String title, {String store = 'primary'}) =>
      session.index.firstWhere((v) => v.title == title && v.ref.store == store);

  TomSecretsIndexedEntry indexed(String title) =>
      session.indexedOf(view(title).ref)!;

  TomSecretsMatrixRow row(String title, String dimension, String value) =>
      session.resolution
          .matrix(indexed(title))
          .firstWhere((r) => r.dimension == dimension && r.value == value);

  String password(TomSecretsIndexedEntry? e) =>
      e!.entry.getString(KdbxKeyCommon.PASSWORD)!.getText()!;

  group('the resolution model', () {
    test('reads the primary\'s configuration and serves every open vault', () {
      final model = session.resolution;
      expect(model.config.dimensions.map((d) => d.name), [
        'host',
        'platform',
        'env',
      ]);
      expect(model.stores.map((s) => s.name), ['primary', 'prod']);
      expect(session.kindOf('primary'), TomSecretsVaultKind.system);
    });

    test('the dimension values: hosts from the grants and the overlays, '
        'every platform, the configured environments and the files\' '
        'bindings', () {
      final model = session.resolution;
      expect(model.valuesOf('host'), ['bomber', 'ci']);
      expect(model.valuesOf('platform'), containsAll(['linux', 'macos']));
      expect(model.valuesOf('env'), ['dev', 'prod', 'staging']);
    });

    test('a key reference when the entry has a key, else a path reference', () {
      final model = session.resolution;
      expect(model.referenceOf(indexed('Stripe')), 'stripe.key');
      expect(model.referenceOf(indexed('Twin')), 'primary/Api/Twin');
      expect(
        model.referenceOf(indexed('Stripe'), const [
          TomSecretBinding('env', 'prod'),
        ]),
        '[env:prod]stripe.key',
      );
    });
  });

  group('the overlay matrix', () {
    test('each row says what it gets and where from', () {
      final bomber = row('Stripe', 'host', 'bomber');
      expect(bomber.resolved.source, TomSecretsValueSource.overlay);
      expect(bomber.ownOverlay, isNotNull);
      expect(password(bomber.resolved.winner), 'demo-stripe-bomber');

      final ci = row('Stripe', 'host', 'ci');
      expect(ci.resolved.source, TomSecretsValueSource.shared);
      expect(ci.ownOverlay, isNull);
      expect(password(ci.resolved.winner), 'demo-stripe-dev');

      final prod = row('Stripe', 'env', 'prod');
      expect(prod.resolved.source, TomSecretsValueSource.otherFile);
      expect(prod.resolved.winner!.store, 'prod');
      expect(password(prod.resolved.winner), 'demo-stripe-prod');

      final staging = row('Stripe', 'env', 'staging');
      expect(staging.resolved.source, TomSecretsValueSource.shared);
    });

    test('two overlays ranking equal are ambiguous', () {
      final twin = row('Twin', 'host', 'bomber');
      expect(twin.resolved.source, TomSecretsValueSource.ambiguous);
      expect(twin.resolved.tied, hasLength(2));
      expect(twin.resolved.winner, isNull);
    });
  });

  group('which value does … get?', () {
    test('step by step: the request, the candidates kept and dropped, the '
        'answer', () {
      final model = session.resolution;
      final answer = model.resolve(
        indexed('Stripe'),
        TomSecretsResolutionModel.parseQualifiers('[env:prod,host:bomber]'),
      );
      expect(answer.request, {
        'host': 'bomber',
        'platform': 'default',
        'env': 'prod',
      });
      expect(answer.source, TomSecretsValueSource.overlay);
      expect(password(answer.winner), 'demo-stripe-bomber');
      final kept = answer.steps.where((s) => s.kept).toList();
      expect(kept.map((s) => s.vector), [
        [2, 0, 0],
        [0, 0, 2],
        [0, 0, 0],
      ]);
      expect(kept.first.entry.isOverlay, isTrue);

      final mbp = model.resolve(
        indexed('Stripe'),
        TomSecretsResolutionModel.parseQualifiers('host:mbp'),
      );
      expect(mbp.source, TomSecretsValueSource.shared);
      final dropped = mbp.steps.where((s) => !s.kept).toList();
      expect(dropped.map((s) => s.dropReason), [
        'bound host:bomber, the request has mbp',
        'bound env:prod, the request has dev',
      ]);
    });

    test('an undeclared dimension is refused; bad qualifiers do not parse', () {
      final answer = session.resolution.resolve(
        indexed('Stripe'),
        TomSecretsResolutionModel.parseQualifiers('[region:eu]'),
      );
      expect(answer.source, TomSecretsValueSource.malformed);
      expect(answer.error, contains('region'));
      expect(
        () => TomSecretsResolutionModel.parseQualifiers('[env]'),
        throwsFormatException,
      );
    });
  });

  group('editing overlays', () {
    test('a new overlay is a copy of the shared entry at the root '
        'placement, saved; edited; removed to the recycle bin', () async {
      final base = view('Stripe').ref;
      final created = await session.createOverlay(base, 'host', 'ci');
      expect(service.saves, hasLength(1));
      final ci = row('Stripe', 'host', 'ci');
      expect(ci.ownOverlay, isNotNull);
      expect(ci.ownOverlay!.entry.uuid, created.uuid);
      expect(password(ci.ownOverlay), 'demo-stripe-dev');
      expect(ci.ownOverlay!.key, 'stripe.key');
      expect(ci.resolved.source, TomSecretsValueSource.overlay);
      // Not a folder of its own in the index: an overlay of the entry.
      expect(view('Stripe').overlays, 2);
      expect(session.index.where((v) => v.title == 'Stripe'), hasLength(2));

      await session.setField(created, 'Password', 'demo-stripe-ci');
      expect(
        password(row('Stripe', 'host', 'ci').resolved.winner),
        'demo-stripe-ci',
      );
      expect(
        session.entryOf(created)!.getString(KdbxKeyCommon.PASSWORD),
        isA<ProtectedValue>(),
      );

      await session.deleteEntries([created]);
      final after = row('Stripe', 'host', 'ci');
      expect(after.ownOverlay, isNull);
      expect(after.resolved.source, TomSecretsValueSource.shared);
    });
  });

  group('readers and the two views', () {
    test('the clients granted an entry: by reference on their host, not a '
        'never, not a revoked grant', () {
      final model = session.resolution;
      final readers = model.readersOf(indexed('Stripe'));
      expect(readers.map((r) => (r.host, r.subject, r.lastUsed)), [
        ('bomber', 'exe /usr/bin/demo-app', demoLastUsed),
      ]);
      expect(model.readersOf(indexed('Twin')), isEmpty);
    });

    test('vault-aware: a system entry shows key, bindings and readers; '
        'uniform adds the login', () {
      expect(session.vaultAware, isTrue);
      final stripe = tomSecretsEntryDetails(session, view('Stripe'));
      expect(stripe.first, 'stripe.key');
      expect(stripe.last, startsWith('1 client, last '));
      expect(tomSecretsEntryDetails(session, view('Twin')), ['(no key)']);
      expect(tomSecretsEntryDetails(session, view('Stripe', store: 'prod')), [
        'stripe.key',
        'bound env:prod',
      ]);
      session.vaultAware = false;
      expect(prefs.read(TomSecretsPreferenceKeys.vaults), 'uniform');
      expect(tomSecretsEntryDetails(session, view('Twin')), isEmpty);
      final again = TomSecretsSession(connection, prefs);
      addTearDown(again.dispose);
      expect(again.vaultAware, isFalse);
    });
  });

  group('conflicts', () {
    test('one row per field, the kept and the replaced value, masked as '
        'stored', () {
      expect(view('Box').hasConflict, isTrue);
      final rows = session.conflictRows;
      expect(rows.map((r) => r.attribute), ['field:Notes', 'field:Password']);
      final pw = rows.last;
      expect(pw.kept!.text, 'pw-newer');
      expect(pw.kept!.isProtected, isTrue);
      expect(pw.replaced!.text, 'pw-older');
      expect(pw.headline, 'Box · Password');
      expect(pw.resultEditable, isTrue);
    });

    test('confirming writes the value and takes the field off the record; '
        'the last one clears it', () async {
      var rows = session.conflictRows;
      final pw = rows.firstWhere((r) => r.attribute == 'field:Password');
      await session.settleConflict(pw, pw.replaced!.copy());
      final box = session.entryOf(pw.ref)!;
      expect(box.getString(KdbxKeyCommon.PASSWORD)!.getText(), 'pw-older');
      expect(box.getString(KdbxKeyCommon.PASSWORD), isA<ProtectedValue>());
      expect(tomSecretsConflictsOf(box).single.fields, ['field:Notes']);

      rows = session.conflictRows;
      expect(rows.single.attribute, 'field:Notes');
      final edited = rows.single.kept!.copy()..text = 'n-merged';
      await session.settleConflict(rows.single, edited);
      expect(session.conflictRows, isEmpty);
      expect(view('Box').hasConflict, isFalse);
      expect(
        session.entryOf(pw.ref)!.getString(KdbxKeyCommon.NOTES)!.getText(),
        'n-merged',
      );
    });
  });

  group('a file opened for editing only', () {
    test('wrong keys are refused; opened, changed and encoded with its own '
        'keys; the lock drops it', () async {
      await expectLater(
        session.openExtraFile(
          'staging.kdbx',
          staging,
          tomSecretsVaultCredentials(password: 'wrong'),
        ),
        throwsA(isA<KdbxInvalidKeyException>()),
      );
      final extra = await session.openExtraFile(
        'staging.kdbx',
        staging,
        tomSecretsVaultCredentials(password: 'staging-demo-pw'),
      );
      expect(session.extraFiles.map((x) => x.name), ['staging.kdbx']);
      // Not served: resolution does not see it.
      expect(session.resolution.stores.map((s) => s.name), ['primary', 'prod']);
      final stripe = extra.file.body.rootGroup.getAllEntries().firstWhere(
        (e) => e.label == 'Stripe',
      );
      stripe.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('demo-stripe-staging-2'),
      );
      final bytes = await session.encodeExtraFile('staging.kdbx');
      final back = await KdbxFormat().read(
        bytes,
        tomSecretsVaultCredentials(password: 'staging-demo-pw'),
      );
      expect(
        back.body.rootGroup
            .getAllEntries()
            .firstWhere((e) => e.label == 'Stripe')
            .getString(KdbxKeyCommon.PASSWORD)!
            .getText(),
        'demo-stripe-staging-2',
      );
      await connection.lock();
      await settle();
      expect(session.extraFiles, isEmpty);
    });
  });
}
