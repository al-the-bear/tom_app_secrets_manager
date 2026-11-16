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

/// The role of the repository whose packages reach no KDBX at all (the
/// clients', `SecretsCiWorkspace.roleOf`).
const String secretsKdbxFreeRepository = 'secrets_clients';

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
  'tom_secrets_desktop': {'dbus': _dbusReason},
  'tom_secrets_app': {'dbus': _dbusReason},
};

const String _dbusReason =
    'MPL-2.0 (file-level copyleft), linked only by flutter_local_notifications_linux '
    'for Linux desktop notifications and bonsoir_linux for mDNS over Avahi; '
    'unmodified, stated in THIRD_PARTY.md '
    'with its source, so a BSD-3 binary may carry it (tsm_a23).';

/// The KDBX rule for the package [package] of the repository of role
/// [repository] (`SecretsCiWorkspace.roleOf`), which declares
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

/// Every problem of the package in [packageDir], of the repository of role
/// [repository]:
/// the licences of its closure and the KDBX rule. Empty when it passes.
/// [exceptions] are the named exceptions, by package (default
/// [secretsLicenceExceptions]).
List<String> secretsBoundaryProblems(
  String packageDir,
  String repository, {
  Map<String, Map<String, String>> exceptions = secretsLicenceExceptions,
}) {
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
  final excepted = exceptions[name] ?? const {};
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

/// The npm package's own licence ([secretsNpmProblems]): BSD-3 (DP-203).
const String secretsNpmLicence = 'BSD-3-Clause';

/// Every problem of the npm package whose `package.json` is in [packageDir]:
/// its own licence, and the licences of its closure as `package-lock.json`
/// records it. The closure is every entry of the lock's `packages` but the
/// root and those marked `dev` (dev dependencies are not linked, as for the
/// Dart packages). Each is classified by its licence file as installed under
/// `node_modules` (`npm ci`), not by the lock's SPDX tag, which a package may
/// carry without carrying the terms. Empty when it passes.
List<String> secretsNpmProblems(String packageDir) {
  final problems = <String>[];
  final manifest = File(p.join(packageDir, 'package.json'));
  final Object? package;
  try {
    package = jsonDecode(manifest.readAsStringSync());
  } on FormatException catch (e) {
    return ['${manifest.path} is not JSON: ${e.message}'];
  }
  if (package is! Map || package['name'] is! String) {
    return ['${manifest.path} declares no name.'];
  }
  final name = package['name'] as String;
  if (package['license'] != secretsNpmLicence) {
    problems.add(
      '$name declares licence ${package['license']}, not $secretsNpmLicence.',
    );
  }
  final own = tomLicenceFileOf(Directory(packageDir));
  if (own == null ||
      tomClassifyLicence(own.readAsStringSync()) != TomLicence.bsd3) {
    problems.add('$name has no BSD-3 licence file.');
  }
  final lockFile = File(p.join(packageDir, 'package-lock.json'));
  if (!lockFile.existsSync()) {
    return [...problems, '$name has no package-lock.json: run npm install.'];
  }
  final lock = jsonDecode(lockFile.readAsStringSync());
  final packages = lock is Map ? lock['packages'] : null;
  if (packages is! Map) {
    return [
      ...problems,
      '$name: package-lock.json has no packages (lockfileVersion 2 or '
          'later): run npm install.',
    ];
  }
  for (final MapEntry(key: linked, value: entry) in secretsNpmLinked(
    packages,
  ).entries) {
    final installed = Directory(p.join(packageDir, linked));
    if (!installed.existsSync()) {
      problems.add(
        '$name links $linked, which is not installed: run npm ci in '
        '$packageDir before the check.',
      );
      continue;
    }
    final file = tomLicenceFileOf(installed);
    final licence = file == null
        ? null
        : tomClassifyLicence(file.readAsStringSync());
    if (licence == null || !secretsAdmittedLicences.contains(licence)) {
      problems.add(
        '$name links $linked under '
        '${licence?.name ?? 'no recognised licence'} '
        '(lock: ${entry['license'] ?? 'none'}).',
      );
    }
  }
  return problems;
}

/// The entries of a lock's `packages` an npm package links: all but the root
/// (`""`) and those marked `dev`, by their location (`node_modules/<name>`).
Map<String, Map<Object?, Object?>> secretsNpmLinked(
  Map<Object?, Object?> packages,
) => {
  for (final MapEntry(:key, :value) in packages.entries)
    if (key is String && key != '' && value is Map && value['dev'] != true)
      key: value,
};

/// Whether the npm package in [packageDir] links anything by its
/// `package-lock.json` (so `:licences` installs it before the check).
bool secretsNpmLinksAnything(String packageDir) {
  final lock = File(p.join(packageDir, 'package-lock.json'));
  if (!lock.existsSync()) return false;
  final decoded = jsonDecode(lock.readAsStringSync());
  final packages = decoded is Map ? decoded['packages'] : null;
  return packages is Map && secretsNpmLinked(packages).isNotEmpty;
}
