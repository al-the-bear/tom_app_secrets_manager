// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// `tsm-browser-host` as the browser runs it: a process started with the
/// extension's origin, native messaging on its standard input and output,
/// ending when the browser closes the port; with no service running it
/// answers `not_running`; started by another extension it refuses and
/// exits.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_secrets_browser/tom_secrets_browser.dart';
import 'package:tom_secrets_client/admin.dart'
    show tomSecretsChromiumDevelopmentId;

void main() {
  late Directory runtime;

  setUp(() => runtime = Directory.systemTemp.createTempSync('tsmbh'));
  tearDown(() => runtime.deleteSync(recursive: true));

  Future<(int, List<Map<String, Object?>>)> host(
    List<String> arguments,
    List<Map<String, Object?>> requests,
  ) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/tsm_browser_host.dart', ...arguments],
      // No service in this runtime directory.
      environment: {'TSM_RUNTIME_DIR': runtime.path},
    );
    unawaited(process.stderr.drain<void>());
    final answers = tomSecretsBrowserMessages(
      process.stdout,
      maxLength: tomSecretsBrowserMaxAnswer,
    ).toList();
    for (final r in requests) {
      process.stdin.add(tomSecretsBrowserFrame(r));
    }
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(minutes: 1));
    return (code, await answers);
  }

  test('status over standard input and output: no service is running; the '
      'host ends when the port closes', () async {
    final (code, answers) = await host(
      ['chrome-extension://$tomSecretsChromiumDevelopmentId/'],
      [
        {'id': 1, 'op': 'status'},
        {'id': 2, 'op': 'match', 'url': 'https://mail.example.com/'},
      ],
    );
    expect(code, 0);
    expect(answers[0], {'id': 1, 'op': 'status', 'state': 'not_running'});
    expect(answers[1]['error'], containsPair('kind', 'not_running'));
  });

  test('started for another extension: one refusal, exit 1', () async {
    final (code, answers) = await host(
      ['chrome-extension://abcdefghijklmnopabcdefghijklmnop/'],
      [
        {'id': 1, 'op': 'status'},
      ],
    );
    expect(code, 1);
    expect(answers.single['error'], containsPair('reason', 'origin'));
  });
}
