/// Where things are: the product's three repositories, their packages, the
/// manifests no closure check reads yet, the lock.
///
/// Everything here is *found*, never listed: a package added later is a
/// package every stage runs over without anybody editing this file.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_build_base/ci.dart';
import 'package:tom_build_base/seams.dart'
    show resolveRepositoryRoot, resolveWorkspaceRoot;
import 'package:yaml/yaml.dart';

/// The two repositories beside this one, by their role: the core and the
/// service (`secrets_manager`), the clients and the protocol
/// (`secrets_clients`). This repository (`app_secrets_manager`, role
/// [secretsCiAppsRole]) is found by its landmark.
const String secretsCiManagerRole = 'secrets_manager';

/// The role of the clients' repository.
const String secretsCiClientsRole = 'secrets_clients';

/// The role of this repository, the apps'.
const String secretsCiAppsRole = 'apps';

/// Where the two other repositories are in this workspace (`tom_ai/…`), by
/// role: the default when [secretsCiRepositoriesFile] names none.
const Map<String, String> secretsCiWorkspaceLayout = {
  secretsCiManagerRole: 'tom_ai/secrets_manager',
  secretsCiClientsRole: 'tom_ai/secrets_clients',
};

/// Where they are when the three repositories are cloned side by side under
/// their GitHub names (a checkout outside this workspace), by role.
const Map<String, String> secretsCiSideBySideLayout = {
  secretsCiManagerRole: 'tom_secrets_manager',
  secretsCiClientsRole: 'tom_secrets_clients',
};

/// The optional file in `tom_secrets_build/` naming where the two other
/// repositories are, absolute or relative to this repository's root:
///
/// ```yaml
/// secrets_manager: ../tom_secrets_manager
/// secrets_clients: ../tom_secrets_clients
/// ```
const String secretsCiRepositoriesFile = 'repositories.yaml';

/// Directory names the package and manifest search never enters: hidden
/// directories (checked apart), build output and scratch, dependencies
/// installed by npm, example and test trees (their pubspecs are fixtures or
/// demos, not packages of the product), and the Flutter platform folders,
/// whose Gradle and CMake files are build files, not dependency manifests.
const Set<String> secretsCiSkippedDirectories = {
  'build',
  'ztmp',
  'testlog',
  'node_modules',
  'example',
  'test',
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
  'web',
};

/// Dependency manifests of the languages other than Dart. Each one found is a
/// closure the licence-boundary check must read, so `:licences` reports it red
/// rather than passing it unread, except five the check reads: a Go module
/// that requires nothing ([secretsGoModuleRequirements]), whose closure is the
/// Go standard library alone (BSD-3), a Python project that requires nothing
/// ([secretsPythonRequirements]), whose closure is the Python standard
/// library alone (PSF-2.0, permissive), a Maven project whose dependencies
/// are all test-scoped ([secretsMavenRequirements]), whose closure is the
/// JDK alone (GPL-2.0 with the Classpath Exception, which binds nothing
/// linked to it), an npm package with its
/// `package-lock.json` ([secretsNpmProblems]) and a Cargo package with its
/// `Cargo.lock` ([secretsCargoProblems]).
const Map<String, String> secretsCiForeignManifests = {
  'package.json': 'npm',
  'Cargo.toml': 'Cargo',
  'go.mod': 'Go modules',
  'pom.xml': 'Maven',
  'pyproject.toml': 'Python',
  'setup.py': 'Python',
};

/// The modules a `go.mod` requires (`require x v` lines and `require ( ... )`
/// blocks, indirect ones included), as `module version`.
List<String> secretsGoModuleRequirements(String goMod) {
  final found = <String>[];
  var inBlock = false;
  for (final raw in goMod.split('\n')) {
    final line = raw.split('//').first.trim();
    if (inBlock) {
      if (line == ')') {
        inBlock = false;
      } else if (line.isNotEmpty) {
        found.add(line);
      }
    } else if (line == 'require (' || line == 'require(') {
      inBlock = true;
    } else if (line.startsWith('require ')) {
      found.add(line.substring('require '.length).trim());
    }
  }
  return found;
}

/// The string values of a `pyproject.toml`, per `[section]` and key: a
/// string, an array of strings (over several lines) or an inline table gives
/// the strings it holds, in order. Only the subset of TOML the Python
/// manifests use: enough for [secretsPythonRequirements] and the declared
/// licence ([secretsPythonProblems]).
Map<String, Map<String, List<String>>> secretsPyprojectStrings(String text) {
  final out = <String, Map<String, List<String>>>{};
  var section = '';
  String? key;
  var depth = 0;
  for (final raw in text.split('\n')) {
    // The line outside its strings and comment, and each string with the
    // length of that outside text where it began.
    final bare = StringBuffer();
    final strings = <(int, String)>[];
    String? quote;
    var current = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (quote != null) {
        if (c == r'\' && quote == '"' && i + 1 < raw.length) {
          current.write(raw[++i]);
        } else if (c == quote) {
          strings.add((bare.length, current.toString()));
          current = StringBuffer();
          quote = null;
        } else {
          current.write(c);
        }
        continue;
      }
      if (c == '#') break;
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      bare.write(c);
    }
    final line = bare.toString();
    var values = strings;
    var valuePart = line;
    if (depth == 0) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        section = trimmed.replaceAll(RegExp(r'[\[\]\s]'), '');
        key = null;
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      key = line.substring(0, eq).trim();
      values = [
        for (final s in strings)
          if (s.$1 > eq) s,
      ];
      valuePart = line.substring(eq + 1);
    }
    if (key == null) continue;
    (out[section] ??= {})[key] = [
      ...?out[section]?[key],
      for (final s in values) s.$2,
    ];
    for (final c in valuePart.split('')) {
      if (c == '[' || c == '{') depth++;
      if (c == ']' || c == '}') depth--;
    }
    if (depth < 0) depth = 0;
  }
  return out;
}

/// The requirements a `pyproject.toml` declares: `[project]`'s
/// `dependencies` and every list of `[project.optional-dependencies]`. The
/// build system's `requires` are build tools, never linked, as an npm
/// package's dev dependencies are not.
List<String> secretsPythonRequirements(String pyproject) {
  final strings = secretsPyprojectStrings(pyproject);
  return [
    ...?strings['project']?['dependencies'],
    for (final extra in (strings['project.optional-dependencies'] ?? {}).values)
      ...extra,
  ];
}

/// The dependencies a Maven `pom.xml` links: every `<dependency>` outside
/// `<dependencyManagement>` and `<build>` (plugins' dependencies are build
/// tools) whose `<scope>` is not `test`, as `groupId:artifactId`.
List<String> secretsMavenRequirements(String pom) {
  final linked = pom
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(
        RegExp(
          r'<dependencyManagement>.*?</dependencyManagement>',
          dotAll: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'<build>.*?</build>', dotAll: true), '');
  String? element(String block, String name) => RegExp(
    '<$name>\\s*(.*?)\\s*</$name>',
    dotAll: true,
  ).firstMatch(block)?.group(1);
  return [
    for (final m in RegExp(
      r'<dependency>(.*?)</dependency>',
      dotAll: true,
    ).allMatches(linked))
      if (element(m.group(1)!, 'scope') != 'test')
        '${element(m.group(1)!, 'groupId')}:${element(m.group(1)!, 'artifactId')}',
  ];
}

/// How deep below a repository root a package may sit
/// (`clients/dart/tsm` in the clients' repository is three levels).
const int secretsCiSearchDepth = 4;

/// The product's repositories and the directory around them.
class SecretsCiWorkspace {
  /// The repositories at [repoRoot] (this one), [managerRoot] and
  /// [clientsRoot]; names are relative to [workspaceRoot], which holds all
  /// three.
  SecretsCiWorkspace({
    required this.repoRoot,
    required this.workspaceRoot,
    String? managerRoot,
    String? clientsRoot,
  }) : managerRoot =
           managerRoot ??
           p.join(
             workspaceRoot,
             secretsCiWorkspaceLayout[secretsCiManagerRole]!,
           ),
       clientsRoot =
           clientsRoot ??
           p.join(
             workspaceRoot,
             secretsCiWorkspaceLayout[secretsCiClientsRole]!,
           );

  /// Finds this repository from [from] (default: the current directory) by
  /// its `tom_repository.yaml`, then the two others: where
  /// [secretsCiRepositoriesFile] says, else in this workspace's layout
  /// ([secretsCiWorkspaceLayout], the workspace found by
  /// `buildkit_master.yaml`), else cloned side by side
  /// ([secretsCiSideBySideLayout]); the workspace layout when none is there
  /// (they are reported missing). [workspaceRoot] names the workspace
  /// instead (a fixture inside a real workspace).
  factory SecretsCiWorkspace.find({String? from, String? workspaceRoot}) {
    final start = Directory(from ?? Directory.current.path).absolute.path;
    final String repo;
    try {
      repo = resolveRepositoryRoot(start);
    } on StateError {
      throw StateError(
        'No tom_repository.yaml above $start: this is not inside the '
        'app_secrets_manager repository, so there is nothing to verify.',
      );
    }
    String workspace;
    if (workspaceRoot != null) {
      workspace = p.normalize(p.absolute(workspaceRoot));
    } else {
      try {
        workspace = resolveWorkspaceRoot(repo);
      } on StateError {
        workspace = p.dirname(repo);
      }
    }
    bool isRepository(String dir) =>
        File(p.join(dir, 'tom_repository.yaml')).existsSync();
    final configured = secretsCiReadRepositoriesFile(repo);
    String locate(String role) {
      final named = configured[role];
      if (named != null) return named;
      final inWorkspace = p.join(workspace, secretsCiWorkspaceLayout[role]!);
      if (isRepository(inWorkspace)) return inWorkspace;
      final beside = p.join(p.dirname(repo), secretsCiSideBySideLayout[role]!);
      if (isRepository(beside)) return beside;
      return inWorkspace;
    }

    final manager = locate(secretsCiManagerRole);
    final clients = locate(secretsCiClientsRole);
    return SecretsCiWorkspace(
      repoRoot: repo,
      workspaceRoot: _commonAncestor([workspace, repo, manager, clients]),
      managerRoot: manager,
      clientsRoot: clients,
    );
  }

  /// Absolute path of the app_secrets_manager repository.
  final String repoRoot;

  /// Absolute path of the core and service repository.
  final String managerRoot;

  /// Absolute path of the clients and protocol repository.
  final String clientsRoot;

  /// Absolute path of the directory the repositories are named relative to.
  final String workspaceRoot;

  /// This package's own directory.
  String get buildPackageDir => p.join(repoRoot, 'tom_secrets_build');

  /// The three repositories by their path relative to [workspaceRoot], this
  /// one first.
  List<String> get repositories => [
    relative(repoRoot),
    relative(managerRoot),
    relative(clientsRoot),
  ];

  /// The role of [repository] (a member of [repositories]):
  /// [secretsCiAppsRole], [secretsCiManagerRole] or [secretsCiClientsRole].
  String roleOf(String repository) {
    final dir = repositoryDir(repository);
    if (p.equals(dir, managerRoot)) return secretsCiManagerRole;
    if (p.equals(dir, clientsRoot)) return secretsCiClientsRole;
    return secretsCiAppsRole;
  }

  /// The path relative to [workspaceRoot] of the absolute [dir], with `/`.
  String relative(String dir) =>
      p.relative(dir, from: workspaceRoot).replaceAll(r'\', '/');

  /// The absolute directory of [repository] (a member of [repositories]).
  String repositoryDir(String repository) =>
      p.normalize(p.join(workspaceRoot, repository));

  /// The repositories that are not checked out (no `tom_repository.yaml`).
  List<String> missingRepositories() => [
    for (final r in repositories)
      if (!File(p.join(repositoryDir(r), 'tom_repository.yaml')).existsSync())
        r,
  ];

  /// Every Dart package of the checked-out repositories, sorted by name
  /// (its workspace-relative path).
  List<CiPackage> discoverPackages() {
    final found = <CiPackage>[];
    for (final repository in repositories) {
      final root = repositoryDir(repository);
      if (!Directory(root).existsSync()) continue;
      _walk(root, 0, (dir) {
        if (File(p.join(dir, 'pubspec.yaml')).existsSync()) {
          found.add(CiPackage.at(workspaceRoot, dir));
        }
      });
    }
    found.sort((a, b) => a.name.compareTo(b.name));
    return found;
  }

  /// The repository (a member of [repositories]) that holds [pkg].
  String repositoryOf(CiPackage pkg) => repositories.firstWhere(
    (r) => pkg.name == r || pkg.name.startsWith('$r/'),
    orElse: () => throw StateError('${pkg.name} is in none of $repositories'),
  );

  /// Every foreign dependency manifest ([secretsCiForeignManifests]) in the
  /// checked-out repositories, as workspace-relative paths, sorted.
  List<String> foreignManifests() {
    final found = <String>[];
    for (final repository in repositories) {
      final root = repositoryDir(repository);
      if (!Directory(root).existsSync()) continue;
      _walk(root, 0, (dir) {
        for (final name in secretsCiForeignManifests.keys) {
          final file = p.join(dir, name);
          if (File(file).existsSync()) {
            found.add(
              p.relative(file, from: workspaceRoot).replaceAll(r'\', '/'),
            );
          }
        }
      });
    }
    return found..sort();
  }

  /// The [foreignManifests] whose closure no check reads: all but the Go
  /// modules and Python projects that require nothing beyond the standard
  /// library and the npm and Cargo packages with a lock
  /// ([isLockedNpmManifest], [isLockedCargoManifest]).
  List<String> uncheckedForeignManifests() => [
    for (final manifest in foreignManifests())
      if (!isStandardLibraryGoModule(manifest) &&
          !isStandardLibraryPythonProject(manifest) &&
          !isJdkOnlyMavenProject(manifest) &&
          !isLockedNpmManifest(manifest) &&
          !isLockedCargoManifest(manifest))
        manifest,
  ];

  /// The absolute directories of the Go modules that require nothing
  /// ([isStandardLibraryGoModule]), sorted: the stages vet and test them.
  List<String> goModuleDirs() => [
    for (final manifest in foreignManifests())
      if (isStandardLibraryGoModule(manifest))
        p.normalize(p.join(workspaceRoot, p.dirname(manifest))),
  ];

  /// The absolute directories of the Maven projects that link only the JDK
  /// ([isJdkOnlyMavenProject]), sorted: the stages compile and test them.
  List<String> javaPackageDirs() => [
    for (final manifest in foreignManifests())
      if (isJdkOnlyMavenProject(manifest))
        p.normalize(p.join(workspaceRoot, p.dirname(manifest))),
  ];

  /// The absolute directories of the Python projects that require nothing
  /// ([isStandardLibraryPythonProject]), sorted: the stages check and test
  /// them.
  List<String> pythonPackageDirs() => [
    for (final manifest in foreignManifests())
      if (isStandardLibraryPythonProject(manifest))
        p.normalize(p.join(workspaceRoot, p.dirname(manifest))),
  ];

  /// The absolute directories of the npm packages with a lock
  /// ([isLockedNpmManifest]), sorted: the stages build, test and check them.
  List<String> npmPackageDirs() => [
    for (final manifest in foreignManifests())
      if (isLockedNpmManifest(manifest))
        p.normalize(p.join(workspaceRoot, p.dirname(manifest))),
  ];

  /// The absolute directories of the Cargo packages with a lock
  /// ([isLockedCargoManifest]), sorted: the stages lint, test and check
  /// them.
  List<String> cargoPackageDirs() => [
    for (final manifest in foreignManifests())
      if (isLockedCargoManifest(manifest))
        p.normalize(p.join(workspaceRoot, p.dirname(manifest))),
  ];

  /// Whether the workspace-relative [manifest] is a `Cargo.toml` with a
  /// `Cargo.lock` beside it, whose closure [secretsCargoProblems] reads.
  bool isLockedCargoManifest(String manifest) =>
      p.basename(manifest) == 'Cargo.toml' &&
      File(
        p.join(workspaceRoot, p.dirname(manifest), 'Cargo.lock'),
      ).existsSync();

  /// Whether the workspace-relative [manifest] is a `package.json` with a
  /// `package-lock.json` beside it, whose closure [secretsNpmProblems] reads.
  bool isLockedNpmManifest(String manifest) =>
      p.basename(manifest) == 'package.json' &&
      File(
        p.join(workspaceRoot, p.dirname(manifest), 'package-lock.json'),
      ).existsSync();

  /// Whether the workspace-relative [manifest] is a `go.mod` that requires
  /// nothing ([secretsGoModuleRequirements]).
  bool isStandardLibraryGoModule(String manifest) =>
      p.basename(manifest) == 'go.mod' &&
      secretsGoModuleRequirements(
        File(p.join(workspaceRoot, manifest)).readAsStringSync(),
      ).isEmpty;

  /// Whether the workspace-relative [manifest] is a `pom.xml` whose
  /// dependencies are all test-scoped ([secretsMavenRequirements]).
  bool isJdkOnlyMavenProject(String manifest) =>
      p.basename(manifest) == 'pom.xml' &&
      secretsMavenRequirements(
        File(p.join(workspaceRoot, manifest)).readAsStringSync(),
      ).isEmpty;

  /// Whether the workspace-relative [manifest] is a `pyproject.toml` that
  /// requires nothing ([secretsPythonRequirements]).
  bool isStandardLibraryPythonProject(String manifest) =>
      p.basename(manifest) == 'pyproject.toml' &&
      secretsPythonRequirements(
        File(p.join(workspaceRoot, manifest)).readAsStringSync(),
      ).isEmpty;

  /// The workspace lock every flutter-invoking session takes.
  String flutterLockPath({Map<String, String>? environment}) =>
      ciFlutterLockPath(
        repositoryRoot: repoRoot,
        workspaceRoot: workspaceRoot,
        environment: environment,
      );

  void _walk(String dir, int depth, void Function(String dir) visit) {
    visit(dir);
    if (depth >= secretsCiSearchDepth) return;
    final children = Directory(dir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      if (child is! Directory) continue;
      final base = p.basename(child.path);
      if (base.startsWith('.') || secretsCiSkippedDirectories.contains(base)) {
        continue;
      }
      _walk(child.path, depth + 1, visit);
    }
  }
}

/// The locations [secretsCiRepositoriesFile] in [repoRoot]'s
/// `tom_secrets_build/` names, by role, as absolute paths; empty without the
/// file. Throws [FormatException] for a file that is not a mapping of the two
/// roles to paths.
Map<String, String> secretsCiReadRepositoriesFile(String repoRoot) {
  final file = File(
    p.join(repoRoot, 'tom_secrets_build', secretsCiRepositoriesFile),
  );
  if (!file.existsSync()) return const {};
  final doc = loadYaml(file.readAsStringSync());
  if (doc is! YamlMap) {
    throw FormatException('${file.path} is not a mapping');
  }
  final out = <String, String>{};
  for (final MapEntry(:key, :value) in doc.entries) {
    if (!secretsCiWorkspaceLayout.containsKey(key) || value is! String) {
      throw FormatException(
        '${file.path}: $key is not one of '
        '${secretsCiWorkspaceLayout.keys.join(', ')} with a path',
      );
    }
    out[key as String] = p.normalize(
      p.isAbsolute(value) ? value : p.join(repoRoot, value),
    );
  }
  return out;
}

String _commonAncestor(List<String> dirs) {
  var common = p.split(p.normalize(p.absolute(dirs.first)));
  for (final dir in dirs.skip(1)) {
    final parts = p.split(p.normalize(p.absolute(dir)));
    var i = 0;
    while (i < common.length && i < parts.length && common[i] == parts[i]) {
      i++;
    }
    common = common.sublist(0, i);
  }
  return p.joinAll(common);
}
