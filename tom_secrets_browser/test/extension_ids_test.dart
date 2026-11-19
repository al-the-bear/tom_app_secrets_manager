// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The extension's source names the same host and ids the host serves
// (part-browser): the host name, the Chromium development key (whose id
// the host admits) and the Firefox id.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_secrets_client/admin.dart';

String _source(String name) => File('extension/src/$name').readAsStringSync();

/// The string a `export const <name> = '...' [+ '...']*;` declaration holds.
String _constant(String source, String name) {
  final start = source.indexOf('export const $name =');
  expect(start, isNot(-1), reason: '$name is declared');
  final end = source.indexOf(';', start);
  final parts = RegExp(
    "'([^']*)'",
  ).allMatches(source.substring(start, end)).map((m) => m[1]!);
  return parts.join();
}

void main() {
  test('the host name', () {
    expect(_constant(_source('api.ts'), 'hostName'), tomSecretsBrowserHostId);
  });

  test('the Chromium development key and the Firefox id', () {
    final manifest = _source('manifest.ts');
    expect(
      _constant(manifest, 'chromiumDevelopmentKey'),
      tomSecretsChromiumDevelopmentKey,
    );
    expect(
      tomSecretsChromiumExtensionIds,
      contains(tomSecretsChromiumDevelopmentId),
    );
    expect(
      _constant(manifest, 'firefoxExtensionId'),
      tomSecretsFirefoxExtensionId,
    );
  });
}
