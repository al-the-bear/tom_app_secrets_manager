// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Renewing a GitHub token from the Keys screen (part-key-rotation §3)
/// against the fake service: GitHub's new-token page opened filled in
/// (the template parameters within GitHub's limits), the pasted token sent
/// as `token.set`, a refused token explained, the result, and the page
/// where the old token is deleted. Demo data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

void main() {
  group('the new-token page', () {
    test('filled in: name, description, owner, expiry, permissions', () {
      final url = tomSecretsNewTokenUrl(
        repositories: ['al-the-bear/demo-vaults'],
        device: 'mbp',
        expiresInDays: 90,
      );
      expect(
        '${url.scheme}://${url.host}${url.path}',
        'https://github.com/settings/personal-access-tokens/new',
      );
      final q = url.queryParameters;
      expect(q['name'], 'Tom Secrets Manager mbp');
      expect(q['description'], contains('al-the-bear/demo-vaults'));
      expect(q['description'], contains('Only select repositories'));
      expect(q['target_name'], 'al-the-bear');
      expect(q['expires_in'], '90');
      expect(q['contents'], 'write');
      expect(q['metadata'], 'read');
      expect(q.keys.toSet(), {
        'name',
        'description',
        'target_name',
        'expires_in',
        'contents',
        'metadata',
      });
    });

    test('within GitHub\'s limits: the name cut at 40, the description at '
        '1024; refused: several owners, a bad owner, an expiry outside '
        '1..366', () {
      final long = tomSecretsNewTokenUrl(
        repositories: [
          for (var i = 0; i < 40; i++) 'al-the-bear/vault-repository-$i',
        ],
        device: 'a-machine-with-a-very-long-host-name.example.com',
        expiresInDays: 366,
      ).queryParameters;
      expect(long['name']!.length, TomSecretsTokenTemplateLimits.name);
      expect(
        long['description']!.length,
        TomSecretsTokenTemplateLimits.description,
      );
      Matcher refused = throwsArgumentError;
      expect(
        () => tomSecretsNewTokenUrl(
          repositories: ['a/x', 'b/y'],
          device: 'mbp',
          expiresInDays: 30,
        ),
        refused,
      );
      expect(
        () => tomSecretsNewTokenUrl(
          repositories: ['not an owner/x'],
          device: 'mbp',
          expiresInDays: 30,
        ),
        refused,
      );
      for (final days in [0, 367]) {
        expect(
          () => tomSecretsNewTokenUrl(
            repositories: ['al-the-bear/demo-vaults'],
            device: 'mbp',
            expiresInDays: days,
          ),
          refused,
        );
      }
    });
  });

  group('the Keys screen', () {
    late FakeService service;
    late List<Uri> opened;
    late TomSecretsHost host;

    setUp(() async {
      service = FakeService(await demoStores());
      final at = DateTime.now().toUtc().add(const Duration(days: 5, hours: 2));
      service.keys = [
        {
          'kind': 'github_token',
          'key': 'github-token:al-the-bear/demo-vaults',
          'expiresAt': at.toIso8601String(),
          'daysLeft': 5,
          'reminding': true,
        },
      ];
      opened = [];
      host = TomSecretsHost(
        service: FakeHost(service),
        preferences: TomSecretsMemoryPreferences(),
        clipboard: _Clipboard(),
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      );
    });

    Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    Future<void> renewDialog(WidgetTester tester) async {
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
      await tester.tap(find.text('Keys'));
      await wait(tester, 5);
      await tester.tap(
        find.byKey(
          const Key('tsm-key-renew-github-token:al-the-bear/demo-vaults'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-renew')), findsOneWidget);
    }

    testWidgets('Renew…: the page opened filled in, the token checked and '
        'kept, the result said, the old token\'s page linked', (tester) async {
      await renewDialog(tester);
      await tester.tap(find.byKey(const Key('tsm-renew-days')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('180 days').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-renew-open')));
      await wait(tester);
      final page = opened.single;
      expect(page.path, '/settings/personal-access-tokens/new');
      expect(page.queryParameters['target_name'], 'al-the-bear');
      expect(page.queryParameters['expires_in'], '180');
      expect(page.queryParameters['contents'], 'write');
      expect(find.textContaining('select demo-vaults'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('tsm-renew-token')),
        '  github_pat_demo_new  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-renew-send')));
      await wait(tester, 5);
      expect(service.tokenRequests.single, {
        'repository': 'al-the-bear/demo-vaults',
        'token': 'github_pat_demo_new',
      });
      expect(find.byKey(const Key('tsm-renew-result')), findsOneWidget);
      expect(find.textContaining("this machine's keychain"), findsOneWidget);
      expect(find.textContaining('expires on 2027-02-1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tsm-renew-delete-old')));
      await wait(tester);
      expect(
        '${opened.last}',
        'https://github.com/settings/personal-access-tokens',
      );
      await tester.tap(find.byKey(const Key('tsm-renew-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-renew')), findsNothing);
    });

    testWidgets('a token the service refuses: the reason in words, nothing '
        'kept, another can be pasted', (tester) async {
      service.refusedTokens['github_pat_read_only'] = 'token_read_only';
      await renewDialog(tester);
      await tester.enterText(
        find.byKey(const Key('tsm-renew-token')),
        'github_pat_read_only',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-renew-send')));
      await wait(tester, 5);
      expect(find.textContaining('Contents: Read and write'), findsWidgets);
      expect(find.byKey(const Key('tsm-renew-error')), findsOneWidget);
      expect(find.byKey(const Key('tsm-renew-result')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('tsm-renew-token')),
        'github_pat_good',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-renew-send')));
      await wait(tester, 5);
      expect(find.byKey(const Key('tsm-renew-result')), findsOneWidget);
    });
  });
}
