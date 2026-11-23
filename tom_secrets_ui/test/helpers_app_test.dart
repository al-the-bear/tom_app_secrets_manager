// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The developer-tool helpers in the app (part-os-integration): the pick
/// prompt of git's credential helper and the browser extension's prompt
/// (protocol.md 5.5), and Settings ›
/// Integrations writing the ssh and git blocks into a demo home, with the
/// check at every start that repairs a block naming another agent. Demo
/// data and a temporary home only.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_client/admin.dart';
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

void main() {
  late FakeService service;
  late Directory home;
  late String tsm;
  late String browserHost;

  setUp(() async {
    service = FakeService(await demoStores())
      ..agent = {'socket': '/run/demo/tsm/agent.sock'};
    home = Directory.systemTemp.createTempSync('tsm_app_home');
    addTearDown(() => home.deleteSync(recursive: true));
    Directory('${home.path}/bin').createSync();
    tsm = '${home.path}/bin/tsm';
    File(tsm).writeAsStringSync('demo');
    browserHost = '${home.path}/bin/tsm-browser-host';
    File(browserHost).writeAsStringSync('demo');
  });

  TomSecretsBrowserHosts browsers({String? hostExecutable}) =>
      TomSecretsBrowserHosts(
        home: home.path,
        hostExecutable: hostExecutable ?? browserHost,
      );

  TomSecretsHost host() => TomSecretsHost(
    service: FakeHost(service),
    preferences: TomSecretsMemoryPreferences(),
    clipboard: _Clipboard(),
    window: _Window(),
    integrationPaths: (
      home: home.path,
      tsmExecutable: tsm,
      browserHostExecutable: browserHost,
    ),
  );

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
    await tester.pumpWidget(TomSecretsApp(host: host()));
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
  }

  testWidgets("git's pick prompt: the host's logins, one picked and "
      'remembered with "Always this login"', (tester) async {
    await unlocked(tester);
    service.ask({
      'approvalId': 'a-1',
      'host': 'demo-host',
      'identity': {
        'kind': 'exe',
        'exe': '/opt/tsm/bin/tsm',
        'args': ['get'],
        'cwd': '/home/demo/work',
        'parent': {'exe': '/usr/bin/git'},
      },
      'refs': ['team/~01', 'team/~02'],
      'resolved': [
        {'store': 'team', 'path': 'Code/Git personal', 'kind': 'login'},
        {'store': 'team', 'path': 'Code/Git work', 'kind': 'login'},
      ],
      'pick': [
        {
          'entryId': 'team/~01',
          'title': 'Git personal',
          'userName': 'demo',
          'matchedUrl': 'https://git.example.com',
        },
        {
          'entryId': 'team/~02',
          'title': 'Git work',
          'userName': 'demo-work',
          'matchedUrl': 'https://git.example.com/work',
        },
      ],
      'url': 'https://git.example.com/',
    });
    await wait(tester);
    expect(find.text('A tool asks for a login'), findsOneWidget);
    expect(
      find.text('Which login for https://git.example.com/'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tsm-approval-secret')), findsNothing);
    expect(find.byKey(const Key('tsm-approval-decision-folder')), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-approval-pick-team/~02')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-approval-decision-always')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-approval-pick-always')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-answer')));
    await wait(tester);
    expect(service.approvals.single, {
      'approvalId': 'a-1',
      'decision': 'always',
      'secret': 'ref',
      'pick': 'team/~02',
    });
  });

  testWidgets('the browser prompt: the page\'s logins, "Always in this '
      'browser" for all logins, unpinned, named by the browser', (
    tester,
  ) async {
    await unlocked(tester);
    const chrome =
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    service.ask({
      'approvalId': 'a-2',
      'host': 'demo-host',
      'identity': {
        'kind': 'exe',
        'exe': '/opt/tsm/bin/tsm-browser-host',
        'args': ['chrome-extension://lcejninmlbnhfnpedlgjjfeelhbgmach/'],
        'cwd': '/',
        'parent': {'exe': chrome},
      },
      'refs': ['team/~01'],
      'resolved': [
        {'store': 'team', 'path': 'Web/Mail', 'kind': 'login'},
      ],
      'url': 'https://mail.example.com/login',
      'browser': true,
    });
    await wait(tester);
    expect(find.text('The browser extension asks for logins'), findsOneWidget);
    expect(find.text('The logins of mail.example.com'), findsOneWidget);
    expect(find.text('team/Web/Mail'), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-decision-folder')), findsNothing);
    expect(find.byKey(const Key('tsm-approval-browser-once')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-decision-always')));
    await tester.pump();
    expect(find.text('All logins'), findsOneWidget);
    expect(find.byKey(const Key('tsm-approval-with-parent')), findsNothing);
    expect(
      find.byKey(const Key('tsm-approval-browser-lasting')),
      findsOneWidget,
    );
    expect(find.textContaining('This holds for $chrome only'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-approval-answer')));
    await wait(tester);
    expect(service.approvals.single, {
      'approvalId': 'a-2',
      'decision': 'always',
      'secret': 'all',
      'pin': 'off',
    });
  });

  testWidgets('Settings › Integrations: ssh and git switched on and off, the '
      'blocks written and removed', (tester) async {
    await unlocked(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester);
    await tester.ensureVisible(find.byKey(const Key('tsm-integration-ssh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-integration-ssh')));
    await wait(tester);
    final config = File('${home.path}/.ssh/config');
    expect(config.readAsStringSync(), contains('Host *'));
    expect(
      config.readAsStringSync(),
      contains('IdentityAgent /run/demo/tsm/agent.sock'),
    );
    await tester.enterText(
      find.byKey(const Key('tsm-integration-ssh-hosts')),
      '*.example.com',
    );
    await tester.tap(find.byKey(const Key('tsm-integration-ssh-apply')));
    await wait(tester);
    expect(config.readAsStringSync(), contains('Host *.example.com'));

    await tester.ensureVisible(find.byKey(const Key('tsm-integration-git')));
    await tester.tap(find.byKey(const Key('tsm-integration-git')));
    await wait(tester);
    expect(
      File('${home.path}/.gitconfig').readAsStringSync(),
      contains('helper = tsm'),
    );
    expect(Link('${home.path}/bin/git-credential-tsm').targetSync(), tsm);
    // The demo PATH does not hold the demo bin folder: said.
    expect(
      find.byKey(const Key('tsm-integration-git-problem')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('tsm-integration-ssh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-integration-ssh')));
    await wait(tester);
    expect(config.readAsStringSync(), isEmpty);
  });

  testWidgets('Settings › Integrations: an AWS profile and Docker registries '
      'added and removed, every registry switched, the files written', (
    tester,
  ) async {
    await unlocked(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester);
    // On without a profile: said, nothing written.
    await tester.ensureVisible(find.byKey(const Key('tsm-integration-aws')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-integration-aws')));
    await wait(tester);
    expect(find.byKey(const Key('tsm-integration-error')), findsOneWidget);
    final aws = File('${home.path}/.aws/config');
    expect(aws.existsSync(), isFalse);
    await tester.enterText(
      find.byKey(const Key('tsm-integration-aws-name')),
      'ci',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-integration-aws-ref')),
      'team/Cloud/AWS ci',
    );
    await tester.tap(find.byKey(const Key('tsm-integration-aws-add')));
    await wait(tester);
    expect(
      aws.readAsStringSync(),
      contains("credential_process = $tsm aws-credentials 'team/Cloud/AWS ci'"),
    );
    expect(
      find.byKey(const Key('tsm-integration-aws-profile-ci')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tsm-integration-aws-remove-ci')));
    await wait(tester);
    expect(aws.readAsStringSync(), isEmpty);

    await tester.ensureVisible(
      find.byKey(const Key('tsm-integration-docker-name')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('tsm-integration-docker-name')),
      'ghcr.io',
    );
    await tester.tap(find.byKey(const Key('tsm-integration-docker-add')));
    await wait(tester);
    final docker = File('${home.path}/.docker/config.json');
    expect(jsonDecode(docker.readAsStringSync()), {
      'credHelpers': {'ghcr.io': 'tsm'},
    });
    expect(Link('${home.path}/bin/docker-credential-tsm').targetSync(), tsm);
    await tester.ensureVisible(
      find.byKey(const Key('tsm-integration-docker-every')),
    );
    await tester.tap(find.byKey(const Key('tsm-integration-docker-every')));
    await wait(tester);
    expect((jsonDecode(docker.readAsStringSync()) as Map)['credsStore'], 'tsm');
    await tester.tap(find.byKey(const Key('tsm-integration-docker-every')));
    await wait(tester);
    expect(jsonDecode(docker.readAsStringSync()), {
      'credHelpers': {'ghcr.io': 'tsm'},
    });
    await tester.ensureVisible(
      find.byKey(const Key('tsm-integration-docker-remove-ghcr.io')),
    );
    await tester.tap(
      find.byKey(const Key('tsm-integration-docker-remove-ghcr.io')),
    );
    await wait(tester);
    expect(jsonDecode(docker.readAsStringSync()), isEmpty);
    expect(
      FileSystemEntity.typeSync(
        '${home.path}/bin/docker-credential-tsm',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
    expect(find.byKey(const Key('tsm-integration-kubectl')), findsOneWidget);
  });

  testWidgets('at every start an ssh block naming another agent is written '
      'again, and the user is told', (tester) async {
    Directory('${home.path}/.ssh').createSync();
    File('${home.path}/.ssh/config').writeAsStringSync(
      tomSecretsWithBlock('Host build\n  User demo\n', [
        'Host *',
        '  IdentityAgent /run/old/agent.sock',
      ], atTop: true),
    );
    await unlocked(tester);
    await wait(tester, 5);
    final text = File('${home.path}/.ssh/config').readAsStringSync();
    expect(text, contains('IdentityAgent /run/demo/tsm/agent.sock'));
    expect(text, contains('Host build\n  User demo'));
    expect(find.textContaining('Updated the ssh integration'), findsOneWidget);
  });

  testWidgets('Settings › Integrations: a browser found on this machine is '
      'switched on and off, its manifest naming the browser host', (
    tester,
  ) async {
    final hosts = browsers();
    Directory(
      hosts.profileFolder(TomSecretsBrowser.firefox),
    ).createSync(recursive: true);
    await unlocked(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await wait(tester);
    // Only the browser found is offered.
    expect(find.byKey(const Key('tsm-browser-chrome')), findsNothing);
    final firefox = find.byKey(const Key('tsm-browser-firefox'));
    await tester.ensureVisible(firefox);
    await tester.pumpAndSettle();
    await tester.tap(firefox);
    await wait(tester);
    final manifest = File(hosts.manifestPath(TomSecretsBrowser.firefox));
    final written = jsonDecode(manifest.readAsStringSync()) as Map;
    expect(written['path'], browserHost);
    expect(written['allowed_extensions'], [tomSecretsFirefoxExtensionId]);
    await tester.tap(firefox);
    await wait(tester);
    expect(manifest.existsSync(), isFalse);
  });

  testWidgets('at every start a manifest naming another host is written '
      'again, and the user is told', (tester) async {
    final chrome = browsers().profileFolder(TomSecretsBrowser.chrome);
    Directory(chrome).createSync(recursive: true);
    await browsers(
      hostExecutable: '/old/app/tsm/bin/tsm-browser-host',
    ).install(TomSecretsBrowser.chrome);
    await unlocked(tester);
    await wait(tester, 5);
    expect((await browsers().state(TomSecretsBrowser.chrome)).current, isTrue);
    expect(
      find.textContaining('Updated the browser integration of Chrome'),
      findsOneWidget,
    );
  });
}
