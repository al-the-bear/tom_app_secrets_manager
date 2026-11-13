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

/// The two repositories beside this one, by their path in the workspace.
/// This repository (`app_secrets_manager`) is found by its landmark.
const List<String> secretsCiSiblingRepositories = [
  'tom_ai/secrets_manager',
  'tom_ai/secrets_clients',
];

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
/// closure the licence-boundary check does not read yet, so `:licences`
/// reports it red rather than passing it unread; the one exception is a Go
/// module that requires nothing ([secretsGoModuleRequirements]), whose
/// closure is the Go standard library alone (BSD-3).
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

/// How deep below a repository root a package may sit
/// (`tom_ai/secrets_clients/clients/dart/tsm` is three levels).
const int secretsCiSearchDepth = 4;

/// The product's repositories and the workspace around them.
class SecretsCiWorkspace {
  SecretsCiWorkspace({required this.repoRoot, required this.workspaceRoot});

  /// Finds this repository from [from] (default: the current directory) by
  /// its `tom_repository.yaml`, and the workspace by `buildkit_master.yaml`; a
  /// repository checked out on its own takes its parent as the workspace.
  /// [workspaceRoot] names the workspace instead (a fixture inside a real
  /// workspace).
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
    if (workspaceRoot != null) {
      return SecretsCiWorkspace(
        repoRoot: repo,
        workspaceRoot: p.normalize(p.absolute(workspaceRoot)),
      );
    }
    String workspace;
    try {
      workspace = resolveWorkspaceRoot(repo);
    } on StateError {
      workspace = p.dirname(repo);
    }
    return SecretsCiWorkspace(repoRoot: repo, workspaceRoot: workspace);
  }

  /// Absolute path of the app_secrets_manager repository.
  final String repoRoot;

  /// Absolute path of the directory the repositories are named relative to.
  final String workspaceRoot;

  /// This package's own directory.
  String get buildPackageDir => p.join(repoRoot, 'tom_secrets_build');

  /// The three repositories by their workspace-relative path, this one first.
  List<String> get repositories => [
    p.relative(repoRoot, from: workspaceRoot).replaceAll(r'\', '/'),
    ...secretsCiSiblingRepositories,
  ];

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
  /// modules that require nothing beyond the standard library.
  List<String> uncheckedForeignManifests() => [
    for (final manifest in foreignManifests())
      if (!isStandardLibraryGoModule(manifest)) manifest,
  ];

  /// Whether the workspace-relative [manifest] is a `go.mod` that requires
  /// nothing ([secretsGoModuleRequirements]).
  bool isStandardLibraryGoModule(String manifest) =>
      p.basename(manifest) == 'go.mod' &&
      secretsGoModuleRequirements(
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
