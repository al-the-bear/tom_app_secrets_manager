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

import 'ci_workspace.dart'
    show secretsPyprojectStrings, secretsPythonRequirements;

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
/// the relay carries only ciphertext, the browser host is a client of the
/// service (part-browser), and the CI is tooling.
const Set<String> secretsKdbxFreePackages = {
  'tom_secrets_relay',
  'tom_secrets_browser',
  'tom_secrets_build',
};

/// The licences a product package may link.
const Set<TomLicence> secretsAdmittedLicences = TomLicence.permissive;

/// Linked packages the licence audit refuses that a package carries all the
/// same, by package, each with why. Every one is a decision on record: the
/// boundary test prints each on every run and turns red when one is no
/// longer needed, so the list cannot outlive its reasons.
const Map<String, Map<String, String>> secretsLicenceExceptions = {
  'tom_secrets_ui': {'dbus': _dbusReason},
  'tom_secrets_desktop': {'dbus': _dbusReason},
  'tom_secrets_app': {'dbus': _dbusReason},
  'tom_secrets_mobile': {'dbus': _dbusMobileReason},
};

const String _dbusReason =
    'MPL-2.0 (file-level copyleft), linked only on Linux, by '
    'flutter_local_notifications_linux for desktop notifications and by '
    'bonsoir_linux for mDNS over Avahi (tom_secrets_ui\'s pairing discovery); '
    'unmodified, stated in THIRD_PARTY.md '
    'with its source, so a BSD-3 binary may carry it (tsm_a23).';

const String _dbusMobileReason =
    'MPL-2.0 (file-level copyleft), in the closure through tom_secrets_ui\'s '
    'bonsoir (bonsoir_linux, mDNS over Avahi) but never built into the iOS '
    'or Android app; stated in THIRD_PARTY.md (tsm_b_mobile1).';

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

/// Every problem of the Python project whose `pyproject.toml` is in
/// [packageDir]: its declared licence (`license`, BSD-3-Clause), its licence
/// file, and any requirement ([secretsPythonRequirements]) — a project that
/// requires nothing has the Python standard library (PSF-2.0) as its whole
/// closure; no check reads the closure of one that requires something.
/// Empty when it passes.
List<String> secretsPythonProblems(String packageDir) {
  final manifest = File(p.join(packageDir, 'pyproject.toml'));
  final text = manifest.readAsStringSync();
  final project = secretsPyprojectStrings(text)['project'] ?? const {};
  final name = project['name']?.firstOrNull ?? manifest.path;
  final problems = <String>[];
  final licence = project['license'];
  if (licence == null ||
      licence.length != 1 ||
      licence.single != secretsNpmLicence) {
    problems.add(
      '$name declares licence ${licence?.join(' ')}, not $secretsNpmLicence.',
    );
  }
  final own = tomLicenceFileOf(Directory(packageDir));
  if (own == null ||
      tomClassifyLicence(own.readAsStringSync()) != TomLicence.bsd3) {
    problems.add('$name has no BSD-3 licence file.');
  }
  final requirements = secretsPythonRequirements(text);
  if (requirements.isNotEmpty) {
    problems.add(
      '$name requires ${requirements.join(', ')}: no check reads a Python '
      'closure yet.',
    );
  }
  return problems;
}

/// The SPDX licence ids a Cargo package may declare, by the family each
/// names ([secretsSpdxAdmitted]); the permissive families of
/// [secretsAdmittedLicences].
const Map<String, TomLicence> secretsSpdxLicences = {
  'MIT': TomLicence.mit,
  'Apache-2.0': TomLicence.apache2,
  'BSD-2-Clause': TomLicence.bsd2,
  'BSD-3-Clause': TomLicence.bsd3,
  'ISC': TomLicence.isc,
  'Zlib': TomLicence.zlib,
};

/// Whether the SPDX licence [expression] (a Cargo package's `license`) can
/// be met with admitted licences: an `OR` needs one side, an `AND` both, a
/// `WITH` exception keeps its licence's verdict; Cargo's old `/` is `OR`.
/// No expression, or one this reader cannot read, is not admitted.
bool secretsSpdxAdmitted(String? expression) {
  if (expression == null || expression.trim().isEmpty) return false;
  final tokens = RegExp(r'\(|\)|[^\s()]+')
      .allMatches(expression.replaceAll('/', ' OR '))
      .map((m) => m.group(0)!)
      .toList();
  var at = 0;
  // A parenthesised expression nests the whole grammar again.
  late final bool? Function() orExpression;
  bool? factor() {
    if (at >= tokens.length) return null;
    final token = tokens[at++];
    if (token == '(') {
      final value = orExpression();
      if (at >= tokens.length || tokens[at++] != ')') return null;
      return value;
    }
    if (token == ')' || token == 'AND' || token == 'OR') return null;
    if (at < tokens.length && tokens[at] == 'WITH') at += 2;
    final family = secretsSpdxLicences[token];
    return family != null && secretsAdmittedLicences.contains(family);
  }

  bool? andExpression() {
    var value = factor();
    while (value != null && at < tokens.length && tokens[at] == 'AND') {
      at++;
      final next = factor();
      value = next == null ? null : value && next;
    }
    return value;
  }

  orExpression = () {
    var value = andExpression();
    while (value != null && at < tokens.length && tokens[at] == 'OR') {
      at++;
      final next = andExpression();
      value = next == null ? null : value || next;
    }
    return value;
  };

  final value = orExpression();
  return value == true && at == tokens.length;
}

/// The licence files of a Cargo package's [root]: `LICENSE`, `LICENCE` or
/// `COPYING`, alone or with a suffix (`LICENSE-MIT`, `LICENSE-APACHE`,
/// `LICENSE.txt`), as crates ship one per licence of a choice.
List<File> secretsCargoLicenceFiles(Directory root) {
  final pattern = RegExp(
    r'^(LICEN[CS]E|COPYING)([-._].*)?$',
    caseSensitive: false,
  );
  if (!root.existsSync()) return const [];
  return [
    for (final entry in root.listSync())
      if (entry is File && pattern.hasMatch(p.basename(entry.path))) entry,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// Every problem of the Cargo package in [packageDir]: what
/// [secretsCargoProblemsOf] finds in its `cargo metadata` (all features,
/// from its `Cargo.lock`; Cargo downloads the closure's sources to read
/// their manifests).
List<String> secretsCargoProblems(String packageDir) {
  final result = Process.runSync(
    'cargo',
    ['metadata', '--format-version', '1', '--all-features', '--locked'],
    workingDirectory: packageDir,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    return ['$packageDir: cargo metadata failed: ${result.stderr}'];
  }
  final metadata = jsonDecode(result.stdout as String);
  if (metadata is! Map) return ['$packageDir: cargo metadata is no object.'];
  return secretsCargoProblemsOf(metadata);
}

/// Every problem in a Cargo package's [metadata] (`cargo metadata
/// --format-version 1`): its own licence (`license` BSD-3-Clause, and a
/// BSD-3 licence file unless `publish = false`), and every package it links
/// — reached from the root through normal and build dependencies, never
/// dev ones — declaring an admitted SPDX expression
/// ([secretsSpdxAdmitted]) and shipping a permissive licence file
/// ([secretsCargoLicenceFiles]), as for npm by the file's terms, not the
/// tag alone. Empty when it passes.
List<String> secretsCargoProblemsOf(Map<Object?, Object?> metadata) {
  final packages = <String, Map<Object?, Object?>>{
    for (final p
        in (metadata['packages'] as List? ?? const [])
            .cast<Map<Object?, Object?>>())
      p['id'] as String: p,
  };
  final resolve = metadata['resolve'];
  if (resolve is! Map || resolve['root'] is! String) {
    return ['cargo metadata has no resolve root (run it in the package).'];
  }
  final rootId = resolve['root'] as String;
  final root = packages[rootId];
  if (root == null) return ['cargo metadata names no package $rootId.'];
  final name = root['name'];
  final problems = <String>[];
  if (root['license'] != secretsNpmLicence) {
    problems.add(
      '$name declares licence ${root['license']}, not $secretsNpmLicence.',
    );
  }
  // publish = false is written as an empty list.
  final publishable =
      root['publish'] is! List || (root['publish'] as List).isNotEmpty;
  if (publishable) {
    final own = secretsCargoLicenceFiles(
      Directory(p.dirname(root['manifest_path'] as String)),
    );
    if (!own.any(
      (f) => tomClassifyLicence(f.readAsStringSync()) == TomLicence.bsd3,
    )) {
      problems.add('$name has no BSD-3 licence file.');
    }
  }
  final nodes = <String, List<Map<Object?, Object?>>>{
    for (final n
        in (resolve['nodes'] as List? ?? const [])
            .cast<Map<Object?, Object?>>())
      n['id'] as String: (n['deps'] as List? ?? const [])
          .cast<Map<Object?, Object?>>(),
  };
  final linked = <String>{};
  final queue = [rootId];
  while (queue.isNotEmpty) {
    for (final dep
        in nodes[queue.removeLast()] ?? const <Map<Object?, Object?>>[]) {
      final kinds = (dep['dep_kinds'] as List? ?? const [])
          .cast<Map<Object?, Object?>>();
      if (!kinds.any((k) => k['kind'] != 'dev')) continue;
      final id = dep['pkg'] as String;
      if (linked.add(id)) queue.add(id);
    }
  }
  for (final id in linked.toList()..sort()) {
    final package = packages[id];
    if (package == null) {
      problems.add('$name links $id, which cargo metadata does not describe.');
      continue;
    }
    final linkedName = '${package['name']} ${package['version']}';
    final licence = package['license'] as String?;
    if (!secretsSpdxAdmitted(licence)) {
      problems.add(
        '$name links $linkedName under ${licence ?? 'no declared licence'}.',
      );
    }
    final files = secretsCargoLicenceFiles(
      Directory(p.dirname(package['manifest_path'] as String)),
    );
    final permissive = files.any((f) {
      final family = tomClassifyLicence(f.readAsStringSync());
      return family != null && secretsAdmittedLicences.contains(family);
    });
    if (!permissive) {
      problems.add(
        '$name links $linkedName, which ships no permissive licence file.',
      );
    }
  }
  return problems;
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
