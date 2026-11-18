// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The OS unlock's gated store is `tom_biometric_storage`, the fork of
/// `biometric_storage` published on pub.dev (its repository:
/// github.com/al-the-bear/tom_biometric_storage), taken by version — and
/// nothing redirects it, and upstream `biometric_storage` is not in the
/// graph beside it (two plugins of the same native classes).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The oldest release of the fork this package works with: Windows Hello,
/// the macOS gate-only form and the `TomGatedSecretStore` adapter.
final minimumRelease = Version.parse('6.0.0-dev.10+tom.1');

void main() {
  test('tom_biometric_storage is a version constraint admitting the minimum '
      'release; upstream biometric_storage is no dependency', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final dependencies = pubspec['dependencies'] as YamlMap;
    final spec = dependencies['tom_biometric_storage'];
    expect(spec, isA<String>(), reason: 'a version, not a git or path source');
    expect(
      VersionConstraint.parse(spec as String).allows(minimumRelease),
      isTrue,
    );
    expect(dependencies.containsKey('biometric_storage'), isFalse);
    expect(File('pubspec_overrides.yaml').existsSync(), isFalse);
  });

  test('the resolved fork comes from pub.dev at the minimum release or '
      'later, and upstream biometric_storage is not resolved', () {
    final lock = File('pubspec.lock');
    expect(lock.existsSync(), isTrue, reason: 'run `flutter pub get` first');
    final packages =
        (loadYaml(lock.readAsStringSync()) as YamlMap)['packages'] as YamlMap;
    final fork = packages['tom_biometric_storage'] as YamlMap;
    expect(fork['source'], 'hosted');
    expect((fork['description'] as YamlMap)['url'], 'https://pub.dev');
    expect(Version.parse(fork['version'] as String) >= minimumRelease, isTrue);
    expect(packages.containsKey('biometric_storage'), isFalse);
  });
}
