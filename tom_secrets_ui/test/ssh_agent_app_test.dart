// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The ssh-agent in the app (protocol.md 7.6) against the fake service: the
/// approval prompt of a signature (the key, the host, the purpose; a lasting
/// answer for this host only and with its parent), a confirmation answered
/// for one signature, the agent grants and audit records in words, and a
/// pre-approved agent grant with its hosts and forwarding. Demo data only.
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

final class _Window implements TomSecretsWindowHost {
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<bool> isVisible() async => true;
  @override
  Future<void> quit() async {}
}

const _fingerprint = 'SHA256:demoKeyFingerprintDemoKeyFingerprint0000000';
const _hostKey = 'SHA256:demoHostKeyFingerprintDemoHostKeyFinger000';

Map<String, Object?> _sshPrompt(
  String id, {
  bool confirmOnly = false,
  bool forwarded = false,
  String purpose = 'userauth',
}) => {
  'approvalId': id,
  'host': 'demo-host',
  'identity': {
    'kind': 'exe',
    'exe': '/usr/bin/ssh',
    'args': ['git@github.com', 'git-upload-pack'],
    'cwd': '/home/demo/work',
    'parent': {'exe': '/usr/bin/git'},
  },
  'refs': ['team/~00112233445566778899aabbccddeeff'],
  'resolved': [
    {'store': 'team', 'path': 'Ssh/Deploy key', 'kind': 'ssh-key'},
  ],
  'ssh': {
    'key': _fingerprint,
    'keyType': 'ssh-ed25519',
    'title': 'Deploy key',
    'host': _hostKey,
    'hostNames': ['github.com'],
    'forwarded': forwarded,
    'purpose': purpose,
    if (purpose == 'sshsig') 'namespace': 'git',
  },
  if (confirmOnly) 'confirmOnly': true,
};

void main() {
  late FakeService service;
  late TomSecretsHost host;

  setUp(() async {
    service = FakeService(await demoStores());
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      window: _Window(),
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

  testWidgets('a signature prompt: the key, the host by name, what it is '
      'for; always, for this host only and only from git', (tester) async {
    await unlocked(tester);
    service.ask(_sshPrompt('a-1'));
    await wait(tester);
    expect(find.text('A program wants to use an SSH key'), findsOneWidget);
    final ssh = find.byKey(const Key('tsm-approval-ssh'));
    expect(
      find.descendant(of: ssh, matching: find.text('Deploy key')),
      findsOneWidget,
    );
    expect(find.text('ssh-ed25519 $_fingerprint'), findsOneWidget);
    expect(find.text('github.com'), findsOneWidget);
    expect(find.text(_hostKey), findsOneWidget);
    expect(find.text('to log in'), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-ssh-forwarded')), findsNothing);

    await tester.tap(find.byKey(const Key('tsm-approval-decision-always')));
    await tester.pump();
    expect(find.text('This key'), findsOneWidget);
    expect(find.text("Its vault's keys"), findsOneWidget);
    expect(find.text('Only for this host (github.com)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-with-parent')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-approval-pin')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-approval-answer')));
    await wait(tester);
    expect(service.approvals.single, {
      'approvalId': 'a-1',
      'decision': 'always',
      'secret': 'ref',
      'pin': 'off',
      'sshHost': true,
      'withParent': true,
    });
  });

  testWidgets('a confirmation over a forwarded agent: allowed or refused '
      'for this signature only, no lasting choice', (tester) async {
    await unlocked(tester);
    service.ask(_sshPrompt('a-2', confirmOnly: true, forwarded: true));
    await wait(tester);
    expect(find.text('Confirm an SSH signature'), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-ssh-forwarded')), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-confirm-only')), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-decision-always')), findsNothing);
    expect(find.byKey(const Key('tsm-approval-decision-folder')), findsNothing);
    expect(find.byKey(const Key('tsm-approval-secret')), findsNothing);
    expect(find.text('Allow this signature'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-answer')));
    await wait(tester);
    expect(service.approvals.single, {
      'approvalId': 'a-2',
      'decision': 'once',
      'secret': 'ref',
    });

    service.ask(_sshPrompt('a-3', purpose: 'sshsig', confirmOnly: true));
    await wait(tester);
    expect(find.text('to sign a git commit or tag'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-decision-never')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-approval-answer')));
    await wait(tester);
    expect(service.approvals.last['decision'], 'never');
  });

  group('the Clients screen', () {
    Future<void> openTab(WidgetTester tester, String tab) async {
      await tester.tap(find.text('Clients'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      await wait(tester);
    }

    testWidgets('agent grants and records in words; a parent-qualified '
        'subject grouped under its executable', (tester) async {
      service.grants.add({
        'id': 'g-9',
        'host': 'demo-host',
        'subject': 'exe-from /usr/bin/git => /usr/bin/ssh',
        'secret': 'ssh-key host $_hostKey forward team/~0011',
        'decision': 'allow',
        'created': '2026-11-15T00:00:00Z',
        'accepted': true,
      });
      service.audit.add({
        'time': '2026-11-15T08:00:00Z',
        'host': 'demo-host',
        'identity': {'kind': 'exe', 'exe': '/usr/bin/ssh'},
        'refs': ['team/~0011'],
        'outcome': 'allowed',
        'ssh': {
          'key': _fingerprint,
          'keyType': 'ssh-ed25519',
          'title': 'Deploy key',
          'hostNames': ['github.com'],
          'forwarded': true,
          'purpose': 'userauth',
        },
      });
      await unlocked(tester);
      await openTab(tester, 'Allow list');
      expect(
        find.text('Executable /usr/bin/ssh started by /usr/bin/git'),
        findsOneWidget,
      );
      expect(
        find.text(
          'the SSH key team/~0011 · for host $_hostKey · also over a '
          'forwarded agent',
        ),
        findsOneWidget,
      );
      await openTab(tester, 'Audit log');
      expect(
        find.text('SSH key Deploy key · for github.com · forwarded · allowed'),
        findsOneWidget,
      );
    });

    testWidgets('pre-approve an agent grant: forwarding needs one key and '
        'hosts; the secret written with them', (tester) async {
      await unlocked(tester);
      await openTab(tester, 'Pre-approve');
      await tester.enterText(find.byKey(const Key('tsm-grant-host')), 'bomber');
      await tester.tap(find.byKey(const Key('tsm-grant-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Executable started by a parent').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-grant-path')),
        '/usr/bin/ssh',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-grant-parent')),
        '/usr/bin/git',
      );
      await tester.tap(find.byKey(const Key('tsm-grant-ssh')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('tsm-grant-secret')),
        'store team',
      );
      await tester.tap(find.byKey(const Key('tsm-grant-ssh-forward')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-grant-add')));
      await wait(tester);
      expect(
        find.text('Forwarding is only for one key and named hosts (DP-49).'),
        findsOneWidget,
      );
      expect(service.requests.where((r) => r['op'] == 'grants.add'), isEmpty);

      await tester.enterText(
        find.byKey(const Key('tsm-grant-secret')),
        'team/~0011',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-grant-ssh-hosts')),
        '$_hostKey, SHA256:other',
      );
      await tester.tap(find.byKey(const Key('tsm-grant-add')));
      await wait(tester);
      final added = service.requests.lastWhere((r) => r['op'] == 'grants.add');
      expect(added['grant'], {
        'host': 'bomber',
        'subject': 'exe-from /usr/bin/git => /usr/bin/ssh',
        'secret': 'ssh-key host $_hostKey,SHA256:other forward team/~0011',
        'decision': 'allow',
        'pin': 'hash',
      });
    });
  });
}
