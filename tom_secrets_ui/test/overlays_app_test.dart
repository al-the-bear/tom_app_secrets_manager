// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The screens of overlays and system secrets against the fake service: the
/// vault-aware and uniform switch, the Overlay editor (the matrix, a cell
/// creating its overlay, "which value does … get?"), the Environments table
/// with a file opened for editing only, and the Conflicts screen with the
/// merge view. Demo data only.
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
  final List<String> placed = [];
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async {
    placed.add(text);
    return TomClipboardReceipt(text);
  }

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

final class _Files implements TomSecretsFiles {
  _Files(this.picked);

  final ({String name, Uint8List bytes}) picked;
  final Map<String, Uint8List> saved = {};

  @override
  Future<({String name, Uint8List bytes})?> pick() async => picked;

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    saved[name] = Uint8List.fromList(bytes);
    return true;
  }

  @override
  Future<String?> choosePath({required bool save, String? suggestedName}) =>
      throw UnimplementedError();
}

void main() {
  late FakeService service;
  late _Files files;
  late TomSecretsHost host;

  setUp(() async {
    final demo = await systemStores();
    service = FakeService(demo.stores);
    files = _Files((name: 'staging.kdbx', bytes: demo.staging));
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

  Future<void> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1100);
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
  }

  String details(WidgetTester tester, String title, String store) {
    final session = tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
    final ref = session.index
        .firstWhere((v) => v.title == title && v.ref.store == store)
        .ref;
    return tester.widget<Text>(find.byKey(Key('tsm-entry-details-$ref'))).data!;
  }

  testWidgets('the vault-aware and uniform switch changes the entry lines', (
    tester,
  ) async {
    await unlocked(tester);
    await tester.tap(find.text('List'));
    await tester.pump();
    expect(details(tester, 'Stripe', 'primary'), contains('stripe.key'));
    expect(details(tester, 'Stripe', 'primary'), contains('1 client'));
    expect(details(tester, 'Twin', 'primary'), contains('(no key)'));
    await tester.tap(find.text('Uniform'));
    await tester.pump();
    expect(details(tester, 'Twin', 'primary'), isNot(contains('(no key)')));
    expect(details(tester, 'Stripe', 'prod'), contains('bound env:prod'));
  });

  testWidgets('the overlay editor: the matrix, a click creating an overlay, '
      'which value', (tester) async {
    await unlocked(tester);
    await tester.tap(find.text('List'));
    await tester.pump();
    final session = tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
    final stripe = session.index.firstWhere(
      (v) => v.title == 'Stripe' && v.ref.store == 'primary',
    );
    await tester.tap(find.byKey(Key('tsm-entry-${stripe.ref}')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('tsm-open-overlays')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-open-overlays')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-overlay-matrix')), findsOneWidget);
    expect(find.text('stripe.key'), findsWidgets);
    // Masked until revealed.
    expect(find.textContaining('demo-stripe-bomber'), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-matrix-reveal-host:bomber')));
    await tester.pump();
    expect(find.textContaining('demo-stripe-bomber'), findsOneWidget);
    expect(find.text('ambiguous: 2 rank equal'), findsNothing);

    // A click on a cell without an overlay creates one and edits it.
    await tester.tap(find.byKey(const Key('tsm-matrix-cell-host:ci')));
    await wait(tester);
    expect(service.saves, hasLength(1));
    await tester.enterText(
      find.byKey(const Key('tsm-matrix-edit-host:ci')),
      'demo-stripe-ci',
    );
    await tester.tap(find.byKey(const Key('tsm-matrix-save-host:ci')));
    await wait(tester);
    expect(service.saves, hasLength(2));
    expect(find.byKey(const Key('tsm-matrix-menu-host:ci')), findsOneWidget);

    final matrix = find
        .descendant(
          of: find.byKey(const Key('tsm-overlay-matrix')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('tsm-matrix-env:prod')),
      300,
      scrollable: matrix,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('tsm-matrix-env:prod')),
        matching: find.text('prod\'s file'),
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('tsm-which-input')),
      300,
      scrollable: matrix,
    );
    await tester.enterText(
      find.byKey(const Key('tsm-which-input')),
      '[env:prod]',
    );
    await tester.tap(find.byKey(const Key('tsm-which-resolve')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('tsm-which-answer'))).data,
      'Password from prod\'s file (Stripe).',
    );
  });

  testWidgets('environments: the key across the files, a file opened for '
      'editing only, changed and saved', (tester) async {
    await unlocked(tester);
    await tester.tap(find.text('Environments'));
    await tester.pump();
    expect(find.byKey(const Key('tsm-env-column-primary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-env-column-prod')), findsOneWidget);
    expect(find.text('staging (env:staging)'), findsOneWidget);
    expect(find.text('stripe.key'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tsm-env-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('tsm-extra-passphrase')),
      'staging-demo-pw',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-extra-open')));
    await wait(tester);
    expect(
      find.byKey(const Key('tsm-env-column-staging.kdbx')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('tsm-env-cell-staging.kdbx|stripe.key')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-env-edit-staging.kdbx|stripe.key')),
      'demo-stripe-staging-2',
    );
    await tester.tap(
      find.byKey(const Key('tsm-env-commit-staging.kdbx|stripe.key')),
    );
    await wait(tester, 2);
    await tester.tap(find.byKey(const Key('tsm-env-save-staging.kdbx')));
    await wait(tester);
    final back = await tester.runAsync(
      () => KdbxFormat().read(
        files.saved['staging.kdbx']!,
        tomSecretsVaultCredentials(password: 'staging-demo-pw'),
      ),
    );
    expect(
      back!.body.rootGroup
          .getAllEntries()
          .firstWhere((e) => e.label == 'Stripe')
          .getString(KdbxKeyCommon.PASSWORD)!
          .getText(),
      'demo-stripe-staging-2',
    );
    // The served files were not written.
    expect(service.saves, isEmpty);
  });

  testWidgets('conflicts: listed, resolved in the merge view, the record '
      'cleared', (tester) async {
    await unlocked(tester);
    await tester.tap(find.text('Conflicts'));
    await tester.pump();
    expect(find.byKey(const Key('tsm-conflict-list')), findsOneWidget);
    expect(find.text('Box'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-resolve-conflicts')));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflicts (2)'), findsOneWidget);
    // Confirm both rows as kept.
    await tester.tap(find.byKey(const Key('tom-merge-confirm')));
    await wait(tester);
    await tester.tap(find.byKey(const Key('tom-merge-confirm')));
    await wait(tester);
    expect(find.byKey(const Key('tom-merge-empty')), findsOneWidget);
    expect(service.saves, hasLength(2));
    await tester.tap(find.byKey(const Key('tom-merge-close')));
    await tester.pumpAndSettle();
    expect(find.text('No conflicts.'), findsOneWidget);
  });
}
