/// The licence-boundary check: what every package of the product may link.
///
/// Two rules, read from what each package actually resolves:
///
/// - **No copyleft in a closure.** Every package a product package links
///   (its `dependencies:`, transitively; dev dependencies are not linked)
///   carries a permissive licence. A GPL family, an unrecognised licence or
///   no licence at all is a problem, so a binary built from the package can go
///   into the public `tom_binaries` (DP-203, DP-204).
/// - **KDBX through one gate.** Only [secretsKdbxGateway] declares
///   [secretsKdbxStore]; no package declares a KDBX library itself
///   ([secretsKdbxLibraries]); and the clients, the relay and this build
///   package reach neither the store nor the gateway (DP-29).
///
/// The closure walk and the licence classification are
/// `package:tom_test_support/licence_audit.dart`'s.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_test_support/licence_audit.dart';
import 'package:yaml/yaml.dart';

/// The one package that may depend on [secretsKdbxStore].
const String secretsKdbxGateway = 'tom_secrets_core';

/// The KDBX layer, reached only through [secretsKdbxGateway].
const String secretsKdbxStore = 'tom_kdbx_store';

/// The KDBX libraries no package of the product declares: the store's fork,
/// its upstream, and the retired GPL-3 fork with its upstream.
const Set<String> secretsKdbxLibraries = {
  'tom_kpasslib',
  'kpasslib',
  'tom_kdbx',
  'kdbx',
};

/// The repository whose packages reach no KDBX at all.
const String secretsKdbxFreeRepository = 'tom_ai/secrets_clients';

/// Packages outside [secretsKdbxFreeRepository] that reach no KDBX either:
/// the relay carries only ciphertext, and the CI is tooling.
const Set<String> secretsKdbxFreePackages = {
  'tom_secrets_relay',
  'tom_secrets_build',
};

/// The licences a product package may link.
const Set<TomLicence> secretsAdmittedLicences = TomLicence.permissive;

/// Linked packages the licence audit refuses that a package carries all the
/// same, by package, each with why. Every one is a decision on record: the
/// boundary test prints each on every run and turns red when one is no
/// longer needed, so the list cannot outlive its reasons.
const Map<String, Map<String, String>> secretsLicenceExceptions = {
  'tom_secrets_build': {
    'ini':
        'LGPL-3.0, linked through tom_build_base -> dcli; tolerated in the CI '
        'only, which is run from the clone and never distributed, until '
        'tom_build_base takes the dcli fork without ini (webwork kpass4); '
        'tom_secrets_manager todo tsm_a_lic2 removes this exception',
  },
};

/// The KDBX rule for the package [package] of [repository], which declares
/// the dependencies [declared] and links [linked] (itself included).
List<String> secretsKdbxProblems({
  required String package,
  required String repository,
  required Set<String> declared,
  required Set<String> linked,
}) {
  final problems = <String>[
    for (final library in declared.intersection(secretsKdbxLibraries))
      '$package declares $library: KDBX is reached only through '
          '$secretsKdbxStore, and only by $secretsKdbxGateway (DP-29).',
    if (declared.contains(secretsKdbxStore) && package != secretsKdbxGateway)
      '$package declares $secretsKdbxStore: only $secretsKdbxGateway may '
          '(DP-29).',
  ];
  final kdbxFree =
      repository == secretsKdbxFreeRepository ||
      secretsKdbxFreePackages.contains(package);
  if (kdbxFree) {
    for (final reached in [
      secretsKdbxGateway,
      secretsKdbxStore,
      ...secretsKdbxLibraries,
    ]) {
      if (linked.contains(reached)) {
        problems.add(
          '$package links $reached: it must reach no KDBX '
          '(${repository == secretsKdbxFreeRepository ? 'a client' : 'a KDBX-free package'}, DP-29).',
        );
      }
    }
  }
  return problems;
}

/// The names of the packages the package in [packageDir] links (itself
/// included).
Set<String> secretsLinkedNames(String packageDir) {
  final pubspec =
      loadYaml(File(p.join(packageDir, 'pubspec.yaml')).readAsStringSync())
          as YamlMap;
  final name = pubspec['name'] as String;
  return {
    for (final l in tomLinkedPackages(
      name,
      secretsResolvedPackages(packageDir),
    ))
      l.name,
  };
}

/// The packages the resolution of the package in [packageDir] resolves, by
/// name, from its `.dart_tool/package_config.json`.
Map<String, Directory> secretsResolvedPackages(String packageDir) {
  final config = File(p.join(packageDir, '.dart_tool', 'package_config.json'));
  if (!config.existsSync()) {
    throw StateError(
      '${config.path} is missing: run `pub get` in $packageDir, so the '
      'packages it resolves can be read',
    );
  }
  final decoded = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in (decoded['packages'] as List).cast<Map>())
      entry['name'] as String: Directory.fromUri(
        config.uri.resolve(entry['rootUri'] as String),
      ),
  };
}

/// Every problem of the package in [packageDir], a package of [repository]:
/// the licences of its closure and the KDBX rule. Empty when it passes.
List<String> secretsBoundaryProblems(String packageDir, String repository) {
  final pubspec = loadYaml(
    File(p.join(packageDir, 'pubspec.yaml')).readAsStringSync(),
  );
  if (pubspec is! YamlMap || pubspec['name'] is! String) {
    return ['${p.join(packageDir, 'pubspec.yaml')} declares no name.'];
  }
  final name = pubspec['name'] as String;
  final dependencies = pubspec['dependencies'];
  final declared = {
    if (dependencies is YamlMap) ...dependencies.keys.cast<String>(),
  };
  final linked = tomLinkedPackages(name, secretsResolvedPackages(packageDir));
  final excepted = secretsLicenceExceptions[name] ?? const {};
  return [
    ...tomAuditLicences([
      for (final l in linked)
        if (!excepted.containsKey(l.name)) l,
    ], admitted: secretsAdmittedLicences).problems,
    ...secretsKdbxProblems(
      package: name,
      repository: repository,
      declared: declared,
      linked: {for (final l in linked) l.name},
    ),
  ];
}
